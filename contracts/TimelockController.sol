// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TimelockController
 * @notice Governance timelock — all admin operations must be scheduled and
 *         subject to a configurable minimum delay before they can be executed.
 *
 * @dev Three roles govern the lifecycle of an operation:
 *      - **Proposer**: may call {schedule} and {cancel}.
 *      - **Executor**: may call {execute} once an operation matures.
 *      - **Admin**:    may act as either proposer or executor.
 *
 *      Role changes and delay updates must themselves be routed through this
 *      timelock via self-referential execution (see {onlySelf}).
 */
contract TimelockController {
    uint256 public minDelay;
    address public admin;
    address public proposer;
    address public executor;

    struct Operation {
        address target;
        uint256 value;
        bytes data;
        uint256 readyTimestamp;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => Operation) public operations;
    uint256 public operationCount;

    event OperationScheduled(bytes32 indexed id, address target, uint256 value, uint256 readyTimestamp);
    event OperationExecuted(bytes32 indexed id);
    event OperationCancelled(bytes32 indexed id);
    event MinDelayChanged(uint256 oldDelay, uint256 newDelay);

    modifier onlyProposer() {
        require(msg.sender == proposer || msg.sender == admin, "Timelock: not proposer");
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor || msg.sender == admin, "Timelock: not executor");
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "Timelock: not self");
        _;
    }

    constructor(uint256 _minDelay, address _proposer, address _executor) {
        minDelay = _minDelay;
        admin = msg.sender;
        proposer = _proposer;
        executor = _executor;
    }

    /**
     * @notice Schedule a call for future execution after the minimum delay.
     * @param target  Destination address for the call.
     * @param value   ETH value to forward with the call.
     * @param data    Calldata to send to `target`.
     * @param salt    Arbitrary value to allow re-scheduling the same call.
     * @return id     Unique identifier for this operation.
     */
    function schedule(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        onlyProposer
        returns (bytes32 id)
    {
        id = keccak256(abi.encode(target, value, data, salt, operationCount));

        require(operations[id].readyTimestamp == 0, "Timelock: operation exists");

        // readyTimestamp is the earliest block.timestamp at which execute() may be called
        uint256 readyAt = block.timestamp + minDelay;

        operations[id] = Operation({
            target: target, value: value, data: data, readyTimestamp: readyAt, executed: false, cancelled: false
        });

        operationCount++;
        emit OperationScheduled(id, target, value, readyAt);
    }

    /**
     * @notice Execute a matured scheduled operation.
     * @dev Reverts if the operation's `readyTimestamp` has not yet been reached.
     * @param id Operation identifier returned by {schedule}.
     */
    function execute(bytes32 id) external onlyExecutor {
        Operation storage op = operations[id];

        require(op.readyTimestamp != 0, "Timelock: operation not found");
        require(!op.executed, "Timelock: already executed");
        require(!op.cancelled, "Timelock: operation cancelled");
        require(block.timestamp >= op.readyTimestamp, "Timelock: not ready");

        op.executed = true;

        // Execute the call
        (bool success, bytes memory returnData) = op.target.call{value: op.value}(op.data);
        require(success, string(abi.encodePacked("Timelock: execution failed: ", returnData)));

        emit OperationExecuted(id);
    }

    function cancel(bytes32 id) external onlyProposer {
        Operation storage op = operations[id];
        require(op.readyTimestamp != 0, "Timelock: operation not found");
        require(!op.executed, "Timelock: already executed");

        op.cancelled = true;
        emit OperationCancelled(id);
    }

    /**
     * @notice Update the minimum scheduling delay.
     * @dev Must be invoked via a matured timelock operation targeting this
     *      contract itself ({onlySelf}). Cannot be called directly by any EOA.
     * @param newDelay New minimum delay in seconds.
     */
    function setMinDelay(uint256 newDelay) external onlySelf {
        uint256 old = minDelay;
        minDelay = newDelay;
        emit MinDelayChanged(old, newDelay);
    }

    /**
     * @notice Change admin — also requires timelock self-execution.
     */
    function setAdmin(address newAdmin) external onlySelf {
        admin = newAdmin;
    }

    function setProposer(address newProposer) external onlySelf {
        proposer = newProposer;
    }

    function setExecutor(address newExecutor) external onlySelf {
        executor = newExecutor;
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function isOperationReady(bytes32 id) external view returns (bool) {
        Operation storage op = operations[id];
        return op.readyTimestamp != 0 && !op.executed && !op.cancelled && block.timestamp >= op.readyTimestamp;
    }

    function isOperationPending(bytes32 id) external view returns (bool) {
        Operation storage op = operations[id];
        return op.readyTimestamp != 0 && !op.executed && !op.cancelled;
    }

    function getOperationReadyTime(bytes32 id) external view returns (uint256) {
        return operations[id].readyTimestamp;
    }

    // Accept ETH for valued operations
    receive() external payable {}
}
