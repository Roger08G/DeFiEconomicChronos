// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ChronosToken.sol";

/**
 * @title BalanceRegistry
 * @notice Centralized cached balance ledger for cross-contract accounting.
 *         Protocol contracts call {recordDeposit} and {recordWithdraw} to
 *         maintain per-user, per-token balance entries. Consumer contracts
 *         query {getBalance} to avoid repeated external `balanceOf` calls.
 *
 * @dev Only addresses registered via {registerProtocol} may record balance
 *      changes. Use {forceSync} or {forceSyncAll} to reconcile the cache
 *      against the live ERC20 state whenever an out-of-band transfer is
 *      suspected.
 */
contract BalanceRegistry {
    address public owner;

    // Cached balances per user per token
    mapping(address => mapping(address => uint256)) public cachedBalance;

    // Registered protocol contracts that can record changes
    mapping(address => bool) public registeredProtocols;

    // Track which tokens a user has interacted with
    mapping(address => address[]) public userTokens;
    mapping(address => mapping(address => bool)) private hasToken;

    event BalanceRecorded(address indexed user, address indexed token, uint256 newBalance);
    event Synced(address indexed user, address indexed token, uint256 oldCached, uint256 actual);
    event ProtocolRegistered(address indexed protocol);

    modifier onlyOwner() {
        require(msg.sender == owner, "Registry: not owner");
        _;
    }

    modifier onlyProtocol() {
        require(registeredProtocols[msg.sender], "Registry: not registered protocol");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function registerProtocol(address protocol) external onlyOwner {
        registeredProtocols[protocol] = true;
        emit ProtocolRegistered(protocol);
    }

    // ═══════════════════════════════════════════════════════════════
    // RECORDING (called by protocol contracts)
    // ═══════════════════════════════════════════════════════════════

    function recordDeposit(address user, address token, uint256 amount) external onlyProtocol {
        cachedBalance[user][token] += amount;

        if (!hasToken[user][token]) {
            hasToken[user][token] = true;
            userTokens[user].push(token);
        }

        emit BalanceRecorded(user, token, cachedBalance[user][token]);
    }

    function recordWithdraw(address user, address token, uint256 amount) external onlyProtocol {
        require(cachedBalance[user][token] >= amount, "Registry: insufficient cached balance");
        cachedBalance[user][token] -= amount;

        emit BalanceRecorded(user, token, cachedBalance[user][token]);
    }

    // ═══════════════════════════════════════════════════════════════
    // QUERIES (used by other contracts for accounting decisions)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Return the cached balance for a (user, token) pair.
     * @dev Returns the registry's internal ledger value, which is updated only
     *      via {recordDeposit} and {recordWithdraw}. For the live on-chain
     *      balance call the token's {balanceOf} directly, or run {forceSync}
     *      to reconcile the cache first.
     * @param user  Account to query.
     * @param token ERC20 token address.
     * @return      Cached balance in token's native units.
     */
    function getBalance(address user, address token) external view returns (uint256) {
        return cachedBalance[user][token];
    }

    /**
     * @notice Sum cached balances across all recorded tokens for a given user.
     * @param user Account to query.
     * @return total Aggregate cached balance (raw token units, not normalised).
     */
    function getTotalBalance(address user) external view returns (uint256 total) {
        address[] storage tokens = userTokens[user];
        for (uint256 i = 0; i < tokens.length; i++) {
            total += cachedBalance[user][tokens[i]];
        }
    }

    /**
     * @notice Check whether the cached balance diverges from the live ERC20 balance.
     * @param user  Account to check.
     * @param token ERC20 token address.
     * @return      `true` if the cached value differs from {ChronosToken.balanceOf}.
     */
    function isStale(address user, address token) external view returns (bool) {
        uint256 actual = ChronosToken(token).balanceOf(user);
        return cachedBalance[user][token] != actual;
    }

    // ═══════════════════════════════════════════════════════════════
    // SYNC (manual fix — not called automatically)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Overwrite the cached balance with the live ERC20 balance.
     * @dev Callable by anyone. Useful after any direct token transfer that
     *      bypassed the registry's standard recording flow.
     * @param user  Account to sync.
     * @param token ERC20 token address.
     */
    function forceSync(address user, address token) external {
        uint256 oldCached = cachedBalance[user][token];
        uint256 actual = ChronosToken(token).balanceOf(user);
        cachedBalance[user][token] = actual;

        emit Synced(user, token, oldCached, actual);
    }

    /**
     * @notice Sync all known tokens for a user.
     */
    function forceSyncAll(address user) external {
        address[] storage tokens = userTokens[user];
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 oldCached = cachedBalance[user][tokens[i]];
            uint256 actual = ChronosToken(tokens[i]).balanceOf(user);
            cachedBalance[user][tokens[i]] = actual;
            emit Synced(user, tokens[i], oldCached, actual);
        }
    }
}
