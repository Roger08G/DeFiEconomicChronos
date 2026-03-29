// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ChronosToken.sol";

/**
 * @title StakingRewards
 * @notice Synthetix-style streaming reward distribution for staked positions.
 *         Staked positions are fully transferable between addresses.
 *
 * @dev Reward accounting uses the standard per-token accumulator pattern:
 *
 *        pending = stakedAmount × (accRewardPerToken − userRewardDebt)
 *
 *      The global `accRewardPerToken` accumulator is updated lazily on every
 *      state-changing call through the internal {updateRewards} hook.
 */
contract StakingRewards {
    ChronosToken public stakeToken;
    ChronosToken public rewardToken;

    address public owner;

    // ─── Global state ───
    uint256 public totalStaked;
    uint256 public rewardRate; // Rewards per second
    uint256 public lastUpdateTime;
    uint256 public accRewardPerToken; // Accumulated rewards per token (1e18 precision)
    uint256 public rewardEndTime;

    // ─── Per-user state ───
    struct UserInfo {
        uint256 stakedAmount;
        uint256 rewardDebt; // accRewardPerToken snapshot at last action
        uint256 pendingRewards; // Unclaimed accumulated rewards
    }
    mapping(address => UserInfo) public userInfo;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 reward);
    event StakeTransferred(address indexed from, address indexed to, uint256 amount);
    event RewardAdded(uint256 reward, uint256 duration);

    modifier onlyOwner() {
        require(msg.sender == owner, "StakingRewards: not owner");
        _;
    }

    constructor(address _stakeToken, address _rewardToken) {
        stakeToken = ChronosToken(_stakeToken);
        rewardToken = ChronosToken(_rewardToken);
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════

    function addRewards(uint256 amount, uint256 duration) external onlyOwner {
        updateRewards(address(0));

        rewardToken.transferFrom(msg.sender, address(this), amount);
        rewardRate = amount / duration;
        rewardEndTime = block.timestamp + duration;
        lastUpdateTime = block.timestamp;

        emit RewardAdded(amount, duration);
    }

    // ═══════════════════════════════════════════════════════════════
    // STAKING
    // ═══════════════════════════════════════════════════════════════

    function stake(uint256 amount) external {
        require(amount > 0, "StakingRewards: zero amount");
        updateRewards(msg.sender);

        stakeToken.transferFrom(msg.sender, address(this), amount);

        userInfo[msg.sender].stakedAmount += amount;
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "StakingRewards: zero amount");
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount >= amount, "StakingRewards: insufficient stake");

        updateRewards(msg.sender);

        user.stakedAmount -= amount;
        totalStaked -= amount;

        stakeToken.transfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Transfer a staked position (or part of it) to another address.
     * @dev Moves `amount` from the caller's stake to `to`. Pending rewards
     *      should be settled for both parties before the transfer is finalised.
     * @param to     Recipient of the transferred stake.
     * @param amount Amount of staked tokens to transfer.
     */
    function transferStake(address to, uint256 amount) external {
        require(to != address(0), "StakingRewards: zero address");
        require(to != msg.sender, "StakingRewards: self transfer");

        UserInfo storage sender = userInfo[msg.sender];
        require(sender.stakedAmount >= amount, "StakingRewards: insufficient stake");

        // Transfer staked balance from sender to receiver
        sender.stakedAmount -= amount;
        userInfo[to].stakedAmount += amount;

        emit StakeTransferred(msg.sender, to, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // REWARDS
    // ═══════════════════════════════════════════════════════════════

    function claim() external {
        updateRewards(msg.sender);

        UserInfo storage user = userInfo[msg.sender];
        uint256 reward = user.pendingRewards;
        if (reward > 0) {
            user.pendingRewards = 0;
            rewardToken.transfer(msg.sender, reward);
            emit Claimed(msg.sender, reward);
        }
    }

    function pendingReward(address account) external view returns (uint256) {
        UserInfo storage user = userInfo[account];
        uint256 currentAccReward = accRewardPerToken;

        if (totalStaked > 0) {
            uint256 elapsed = _min(block.timestamp, rewardEndTime) - lastUpdateTime;
            currentAccReward += (elapsed * rewardRate * 1e18) / totalStaked;
        }

        return user.pendingRewards + (user.stakedAmount * (currentAccReward - user.rewardDebt)) / 1e18;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════

    function updateRewards(address account) internal {
        uint256 currentTime = _min(block.timestamp, rewardEndTime);

        if (totalStaked > 0 && currentTime > lastUpdateTime) {
            uint256 elapsed = currentTime - lastUpdateTime;
            accRewardPerToken += (elapsed * rewardRate * 1e18) / totalStaked;
        }
        lastUpdateTime = currentTime;

        if (account != address(0)) {
            UserInfo storage user = userInfo[account];
            user.pendingRewards += (user.stakedAmount * (accRewardPerToken - user.rewardDebt)) / 1e18;
            user.rewardDebt = accRewardPerToken;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
