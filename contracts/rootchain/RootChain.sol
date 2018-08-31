pragma solidity ^0.4.24;

// external modules
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/ECRecovery.sol";
import "solidity-rlp/contracts/RLPReader.sol";

import "../libraries/Validator.sol";
import "../libraries/PriorityQueue.sol";

contract RootChain is Ownable {
    using PriorityQueue for uint256[];
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;
    using SafeMath for uint256;
    using Validator for bytes32;

    /*
     * Events
     */

    event AddedToBalances(address owner, uint256 amount);
    event BlockSubmitted(bytes32 root, uint256 position);
    event ChallengedExit(uint priority, address owner, uint256 amount, uint256[3] utxoPos);
    event ChallengedDepositExit(uint nonce, address owner, uint256 amount);
    event Deposit(address depositor, uint256 amount, uint256 depositNonce);
    event FinalizedExit(uint priority, address owner, uint256 amount);
    event ExitStarted(uint priority, address owner, uint256 amount);
    event DepositExitStarted(uint nonce, address owner, uint256 amount);

    /*
     *  Storage
     */

    // child chain
    uint256 public currentChildBlock;
    uint256 public lastParentBlock;
    uint256 public depositNonce;
    mapping(uint256 => childBlock) public childChain;
    mapping(uint256 => depositStruct) public deposits;
    struct childBlock {
        bytes32 root;
        uint256 created_at;
    }
    struct depositStruct {
        address owner;
        uint256 amount;
        uint256 created_at;
    }

    // exits
    uint256 minExitBond;
    uint256[] exitsQueue = [0];
    uint256[] depositQueue = [0];
    mapping(uint256 => exit) public exits;
    mapping(uint256 => exit) public depositExits;
    struct exit {
        uint256 amount;
        uint256 created_at;
        uint256[3] utxoPos; // not used for deposit exits
        address owner;
        // Possible states:
        // 0 -> does not exist; 1 -> pending; 2 -> challenged; 3 -> finalized
        uint8 state;
    }

    // funds
    mapping(address => uint256) public balances;
    uint256 public totalWithdrawBalance;

    // constants
    uint256 public constant txIndexFactor = 10;
    uint256 public constant blockIndexFactor = 100000;

    constructor() public
    {
        currentChildBlock = 1;
        depositNonce = 1;
        lastParentBlock = block.number;

        minExitBond = 10000;
    }

    // @param root 32 byte merkleRoot of ChildChain block
    function submitBlock(bytes32 root)
        public
        onlyOwner
    {
        // ensure finality on previous blocks before submitting another
        require(block.number >= lastParentBlock.add(6), "presumed finality required");

        childChain[currentChildBlock] = childBlock(root, block.timestamp);
        emit BlockSubmitted(root, currentChildBlock);

        currentChildBlock = currentChildBlock.add(1);
        lastParentBlock = block.number;
    }

    function deposit(address owner)
        public
        payable
    {
        deposits[depositNonce] = depositStruct(owner, msg.value, block.timestamp);
        emit Deposit(owner, msg.value, depositNonce);

        depositNonce = depositNonce.add(1);
    }

    // @param depositNonce the nonce of the specific deposit
    function startDepositExit(uint256 nonce)
        public
        payable
    {
        require(deposits[nonce].owner == msg.sender, "mismatch in owner");
        require(depositExits[nonce].state == 0, "exit for this deposit already exists");
        require(msg.value >= minExitBond, "insufficient exit bond");
        if (msg.value > minExitBond) {
            uint256 excess = msg.value - minExitBond;
            balances[msg.sender] = balances[msg.sender].add(excess);
            totalWithdrawBalance = totalWithdrawBalance.add(excess);
        }

        uint amount = deposits[nonce].amount;
        depositQueue.insert(nonce);
        exits[nonce] = exit({
            owner: owner,
            utxoPos: [uint256(0), uint256(0), uint256(0)],
            amount: amount,
            created_at: block.timestamp,
            state: 1
        });

        emit DepositExitStarted(nonce, owner, amount);
    }


    // Transaction encoding:
    // [Blknum1, TxIndex1, Oindex1, depositNonce1, Amount1, ConfirmSig1
    //  Blknum2, TxIndex2, Oindex2, depositNonce1, Amount2, ConfirmSig2
    //  NewOwner, Denom1, NewOwner, Denom2, Fee]
    //
    // @param txPos   location of the transaction [blkNum, txIndex, outputIndex]
    // @param txBytes raw transaction bytes
    // @param proof   merkle proof of inclusion in the child chain
    // @param sigs    signatures of transaction including confirm signatures
    function startExit(uint256[3] txPos, bytes txBytes, bytes proof, bytes sigs)
        public
        payable
    {
        RLPReader.RLPItem[] memory txList = txBytes.toRlpItem().toList();
        require(txList.length == 17, "incorrect tx length");
        require(msg.sender == txList[12 + 2 * txPos[2]].toAddress(), "address mismatch");
        require(msg.value >= minExitBond, "insufficient exit bond");
        if (msg.value > minExitBond) {
            uint256 excess = msg.value.sub(minExitBond);
            balances[msg.sender] = balances[msg.sender].add(excess);
            totalWithdrawBalance = totalWithdrawBalance.add(excess);
        }

        // check proof and signatures
        bytes32 txHash = keccak256(txBytes);
        bytes32 merkleHash = keccak256(abi.encodePacked(txHash, sigs));
        require(txHash.checkSigs(childChain[txPos[0]].root, txList[0].toUint(), txList[5].toUint(), sigs), "validation error");
        require(merkleHash.checkMembership(txPos[1], childChain[txPos[0]].root, proof), "invalid merkle proof");

        // check that the UTXO's two direct inputs have not been previously exited
        validateExitInputs(txList);

        uint256 priority = blockIndexFactor*txPos[0] + txIndexFactor*txPos[1] + txPos[2];
        require(exits[priority].state == 0);

        exitsQueue.insert(priority);
        uint amount = txList[9 + 2 * txPos[2]].toUint();
        exits[priority] = exit({
            owner: txList[8 + 2 * txPos[2]].toAddress(),
            amount: amount,
            utxoPos: txPos,
            created_at: block.timestamp,
            state: 1
        });

        emit ExitStarted(priority, msg.sender, amount);
    }

    // For any attempted exit of an UTXO, validate that the UTXO's two inputs have not
    // been previously exited. If UTXO's inputs are in the exit queue, those inputs'
    // exits are deleted from the exit queue and the current UTXO's exit remains valid.
    function validateExitInputs(RLPReader.RLPItem[] memory txList)
        private
        view
    {
        for (uint256 i = 0; i < 2; i++) {
            uint256 txInputBlkNum = txList[7*i + 0].toUint();
            uint256 txInputIndex = txList[7*i + 1].toUint();
            uint256 txInputOutIndex = txList[7*i + 2].toUint();
            uint256 txInputPriority = blockIndexFactor*txInputBlkNum + txInputIndex*txInputIndex + txInputOutIndex;

            // this UTXO's inputs must have been challenged or not exited
            uint state = exits[txInputPriority].state;
            require(state == 0 || state == 2, "inputs are being exited or have been finalized");
        }
    }

    // @param txPos            position of the invalid exiting transaction [blkNum, txIndex, outputIndex]
    // @param newTxPos         position of the challenging transaction [blkNum, txIndex, outputIndex]
    // @param txBytes          raw transaction bytes
    // @param sigs             signatures of the inputs for this transaction
    // @param proof            proof of inclusion for this merkle hash
    // @param confirmSignature signature used to invalidate the invalid exit. Signature is over (merkleHash, block header)
    function challengeExit(uint256[3] txPos, uint256[3] newTxPos, bytes txBytes, bytes sigs, bytes proof, bytes confirmSignature)
        public
    {
        RLPReader.RLPItem[] memory txList = txBytes.toRlpItem().toList();
        require(txList.length == 17, "incorrect tx list");

        // invalid transcation should have a pending exit
        uint256 priority = blockIndexFactor*txPos[0] + txIndexFactor*txPos[1] + txPos[2];
        exit memory exit_ = exits[priority];
        require(exit_.state == 1, "no pending exit to challenge");

        // ensure matching inputs
        uint256[3] memory utxoPos = exits[priority].utxoPos;
        require(utxoPos[0] == txList[0 + 7 * newTxPos[2]].toUint(), "incorrect blocknum");
        require(utxoPos[1] == txList[1 + 7 * newTxPos[2]].toUint(), "incorrect tx index");
        require(utxoPos[2] == txList[2 + 7 * newTxPos[2]].toUint(), "incorrect output index");

        // challenge
        bytes32 root = childChain[newTxPos[0]].root;
        bytes32 txHash = keccak256(txBytes);
        bytes32 merkleHash = keccak256(abi.encodePacked(txHash, sigs));
        bytes32 confirmationHash = keccak256(abi.encodePacked(merkleHash, root));
        require(exit_.owner == confirmationHash.recover(confirmSignature), "mismatch in exit owner and confirm signature");
        require(merkleHash.checkMembership(newTxPos[1], root, proof), "incorrect merkle proof");

        // exit successfully challenged. Award the sender with the bond
        balances[msg.sender] = balances[msg.sender].add(minExitBond);
        totalWithdrawBalance = totalWithdrawBalance.add(minExitBond);
        emit AddedToBalances(msg.sender, minExitBond);

        // reflect challenged state
        exits[priority].state = 2;
        emit ChallengedExit(priority, exit_.owner, exit_.amount, exit_.utxoPos);
    }

    // @param depositNonce     the nonce of the deposit trying to exit
    // @param newTxPos         position of the transaction with this deposit as an input [blkNum, txIndex, outputIndex]
    // @param txBytes          bytes of this transcation
    // @param sigs             signatures of the inputs for this transaction
    // @param proof            merkle proof of inclusion
    // @param confirmSignature signature used to invalidate the invalid exit. Signature is over (merkleHash, block header)
    function challengeDepositExit(uint256 nonce, uint256[3] newTxPos, bytes txBytes, bytes sigs, bytes proof, bytes confirmSignature)
        public
    {
        RLPReader.RLPItem[] memory txList = txBytes.toRlpItem().toList();
        require(txList.length == 17, "incorrect tx list");
        
        // ensure matching inputs
        require(nonce == txList[3].toUint() || nonce == txList[9].toUint(), "deposit is not an input to the new transaction");

        exit memory exit_ = depositExits[nonce];
        require(exit_.state == 1, "no pending exit to challenge");

        bytes32 root = childChain[newTxPos[0]].root;
        bytes32 txHash = keccak256(txBytes);
        bytes32 merkleHash = keccak256(abi.encodePacked(txHash, sigs));
        bytes32 confirmationHash = keccak256(abi.encodePacked(merkleHash, root));
        require(exit_.owner == confirmationHash.recover(confirmSignature), "mismatch in exit owner and confirm signature");
        require(merkleHash.checkMembership(newTxPos[1], root, proof), "incorrect merkle proof");

        // exit successfully challenged
        balances[msg.sender] = balances[msg.sender].add(minExitBond);
        totalWithdrawBalance = totalWithdrawBalance.add(minExitBond);
        
        depositExits[nonce].state = 2;
        emit ChallengedDepositExit(nonce, exit_.owner, exit_.amount);
    }

    function finalizeDepositExits() public { finalize(depositQueue); }
    function finalizeExits() public { finalize(exitsQueue); }

    function finalize(uint256[] storage queue)
        private
    {
        // getMin will fail if nothing is in the queue
        if (queue.currentSize() == 0) {
            return;
        }

        // retrieve the lowest priority and the appropriate exit struct
        uint256 priority = queue.getMin();
        exit memory currentExit = exits[priority];

        /*
        * Conditions:
        *   1. Exits exist
        *   2. Exits must be a week old
        *   3. Funds must exists for the exit to withdraw
        */
        uint256 amountToAdd;
        while (queue.currentSize() > 0 &&
               (block.timestamp - currentExit.created_at) > 1 weeks &&
               currentExit.amount.add(minExitBond) <= address(this).balance - totalWithdrawBalance) {

            // skip currentExit if it is not in 'started/pending' state.
            if (currentExit.state != 1) {
                queue.delMin();
            } else {
                amountToAdd = currentExit.amount.add(minExitBond);
                balances[currentExit.owner] = balances[currentExit.owner].add(amountToAdd);
                totalWithdrawBalance = totalWithdrawBalance.add(amountToAdd);

                exits[priority].state = 3;

                emit AddedToBalances(currentExit.owner, amountToAdd);
                emit FinalizedExit(priority, currentExit.owner, amountToAdd);

                // move onto the next oldest exit
                queue.delMin();
            }

            if (queue.currentSize() == 0) {
                return;
            }

            // move onto the next oldest exit
            priority = queue.getMin();
            currentExit = exits[priority];
        }
    }

    function withdraw()
        public
        returns (uint256)
    {
        if (balances[msg.sender] == 0) {
            return 0;
        }

        uint256 transferAmount = balances[msg.sender];
        delete balances[msg.sender];
        totalWithdrawBalance = totalWithdrawBalance.sub(transferAmount);

        // will revert the above deletion if fails
        msg.sender.transfer(transferAmount);
        return transferAmount;
    }

    /*
    * Getters
    */

    function childChainBalance()
        public
        view
        returns (uint)
    {
        // takes into accounts the failed withdrawals
        return address(this).balance - totalWithdrawBalance;
    }

    function balanceOf(address _address)
        public
        view
        returns (uint256)
    {
        return balances[_address];
    }

    function getChildBlock(uint256 blockNumber)
        public
        view
        returns (bytes32, uint256)
    {
        return (childChain[blockNumber].root, childChain[blockNumber].created_at);
    }

    function getExit(uint256 priority)
        public
        view
        returns (address, uint256, uint256[3], uint256, uint8)
    {
        exit memory exit_ = exits[priority];
        return (exit_.owner, exit_.amount, exit_.utxoPos, exit_.created_at, exit_.state);
    }

    function getDeposit(uint256 nonce)
        public
        view
        returns(address, uint256, uint256)
    {
        depositStruct memory deposit_ = deposits[nonce];
        return (deposit_.owner, deposit_.amount, deposit_.created_at);
    }
}
