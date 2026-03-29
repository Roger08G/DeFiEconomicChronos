// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ChronosToken.sol";

/**
 * @title UpgradeableVault
 * @notice Share-based token vault using an upgradeable proxy architecture.
 *         Composed of a lightweight forwarding proxy ({ChronosProxy}) and a
 *         separate logic contract ({VaultImplementation}).
 *
 * @dev The proxy routes all calls via `delegatecall`, so {VaultImplementation}
 *      reads and writes the proxy's storage. Storage layout alignment between
 *      the proxy and the implementation is critical for correct operation.
 */

// ═══════════════════════════════════════════════════════════════════════
// PROXY — forwards all calls via delegatecall
// ═══════════════════════════════════════════════════════════════════════

contract ChronosProxy {
    // Slot 0 — address of the current logic contract
    address public implementation;
    // Slot 1 — address authorised to perform upgrades
    address public admin;

    event Upgraded(address indexed oldImpl, address indexed newImpl);

    constructor(address _implementation) {
        implementation = _implementation;
        admin = msg.sender;
    }

    /**
     * @notice Upgrade the proxy to a new implementation address.
     * @dev Only callable by {admin}. Emits {Upgraded}.
     * @param newImplementation Address of the new logic contract.
     */
    function upgradeTo(address newImplementation) external {
        require(msg.sender == admin, "Proxy: not admin");
        address old = implementation;
        implementation = newImplementation;
        emit Upgraded(old, newImplementation);
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

// ═══════════════════════════════════════════════════════════════════════
// VAULT IMPLEMENTATION — logic contract (storage layout conflicts with Proxy)
// ═══════════════════════════════════════════════════════════════════════

contract VaultImplementation {
    // Slot 0
    uint256 public totalDeposits;
    // Slot 1
    address public owner;
    // Slot 2+
    ChronosToken public asset;
    uint256 public totalShares;

    mapping(address => uint256) public shares;
    mapping(address => uint256) public depositTimestamp;

    event Deposited(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 amount, uint256 sharesBurned);

    bool private initialized;

    function initialize(address _asset) external {
        require(!initialized, "Vault: already initialized");
        initialized = true;
        asset = ChronosToken(_asset);
        owner = msg.sender;
    }

    function deposit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);

        uint256 sharesToMint;
        // Proportional share minting; first depositor sets the initial share price
        if (totalShares == 0 || totalDeposits == 0) {
            sharesToMint = amount;
        } else {
            sharesToMint = (amount * totalShares) / totalDeposits;
        }

        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        totalDeposits += amount;
        depositTimestamp[msg.sender] = block.timestamp;

        emit Deposited(msg.sender, amount, sharesToMint);
    }

    function withdraw(uint256 shareAmount) external {
        require(shares[msg.sender] >= shareAmount, "Vault: insufficient shares");

        // Redeem shares for proportional underlying asset amount
        uint256 assetAmount = (shareAmount * totalDeposits) / totalShares;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalDeposits -= assetAmount;

        asset.transfer(msg.sender, assetAmount);

        emit Withdrawn(msg.sender, assetAmount, shareAmount);
    }

    function getPricePerShare() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalDeposits * 1e18) / totalShares;
    }

    function getUserBalance(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * totalDeposits) / totalShares;
    }
}
