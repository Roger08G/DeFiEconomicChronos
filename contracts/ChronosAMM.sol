// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ChronosToken.sol";

/**
 * @title ChronosAMM
 * @notice Constant-product AMM (x·y=k) with per-swap fee accumulation.
 * @dev Implements the standard xy=k invariant. A 0.30% fee is charged on
 *      every swap and retained inside the pool reserves, accruing value for
 *      liquidity providers proportionally to their LP-token holdings.
 *      LP shares are issued as √(amountA × amountB) on the first deposit and
 *      proportionally to the smaller of the two ratios on subsequent deposits.
 */
contract ChronosAMM {
    ChronosToken public tokenA;
    ChronosToken public tokenB;

    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public totalLiquidity;

    mapping(address => uint256) public liquidity;

    // Fee: 30 bps = 0.3%
    uint256 public constant SWAP_FEE = 30;
    uint256 public constant FEE_DENOMINATOR = 10000;

    // Track cumulative fees (for informational purposes)
    uint256 public totalFeesA;
    uint256 public totalFeesB;

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpMinted);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpBurned);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address _tokenA, address _tokenB) {
        tokenA = ChronosToken(_tokenA);
        tokenB = ChronosToken(_tokenB);
    }

    /**
     * @notice Deposit tokenA and tokenB to receive LP shares.
     * @param amountA Amount of tokenA to deposit.
     * @param amountB Amount of tokenB to deposit.
     * @return lpMinted Number of LP tokens minted to the caller.
     */
    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 lpMinted) {
        tokenA.transferFrom(msg.sender, address(this), amountA);
        tokenB.transferFrom(msg.sender, address(this), amountB);

        if (totalLiquidity == 0) {
            // First deposit — LP tokens = sqrt(amountA * amountB)
            lpMinted = sqrt(amountA * amountB);
            require(lpMinted > 0, "AMM: insufficient initial liquidity");
        } else {
            // Proportional deposit based on existing ratio
            uint256 lpFromA = (amountA * totalLiquidity) / reserveA;
            uint256 lpFromB = (amountB * totalLiquidity) / reserveB;
            lpMinted = lpFromA < lpFromB ? lpFromA : lpFromB;
        }

        liquidity[msg.sender] += lpMinted;
        totalLiquidity += lpMinted;

        reserveA += amountA;
        reserveB += amountB;

        emit LiquidityAdded(msg.sender, amountA, amountB, lpMinted);
    }

    /**
     * @notice Redeem LP tokens for a proportional share of pool reserves.
     * @param lpAmount Number of LP tokens to burn.
     * @return amountA Amount of tokenA returned to the caller.
     * @return amountB Amount of tokenB returned to the caller.
     */
    function removeLiquidity(uint256 lpAmount) external returns (uint256 amountA, uint256 amountB) {
        require(liquidity[msg.sender] >= lpAmount, "AMM: insufficient LP balance");

        amountA = (lpAmount * reserveA) / totalLiquidity;
        amountB = (lpAmount * reserveB) / totalLiquidity;

        liquidity[msg.sender] -= lpAmount;
        totalLiquidity -= lpAmount;

        reserveA -= amountA;
        reserveB -= amountB;

        tokenA.transfer(msg.sender, amountA);
        tokenB.transfer(msg.sender, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB, lpAmount);
    }

    /**
     * @notice Swap tokenA for tokenB, or tokenB for tokenA.
     * @dev A 0.30% fee is deducted from the input amount before applying the
     *      constant-product formula. The full gross input (fee included) is
     *      credited to the reserves, allowing fees to accumulate for LPs.
     * @param tokenIn  Address of the token being sold (must be tokenA or tokenB).
     * @param amountIn Gross amount of tokenIn transferred from the caller.
     * @return amountOut Amount of the opposing token delivered to the caller.
     */
    function swap(address tokenIn, uint256 amountIn) external returns (uint256 amountOut) {
        require(tokenIn == address(tokenA) || tokenIn == address(tokenB), "AMM: invalid token");
        require(amountIn > 0, "AMM: zero amount");

        bool isAtoB = (tokenIn == address(tokenA));

        uint256 reserveIn = isAtoB ? reserveA : reserveB;
        uint256 reserveOut = isAtoB ? reserveB : reserveA;

        // Transfer in
        ChronosToken(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Fee calculation
        uint256 fee = (amountIn * SWAP_FEE) / FEE_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - fee;

        // Constant-product formula: (reserveIn + amountInAfterFee) × (reserveOut − amountOut) = k
        amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee);

        require(amountOut > 0, "AMM: insufficient output");
        require(amountOut < reserveOut, "AMM: insufficient reserve");

        // Update reserves: gross input (fee included) retained, output removed
        if (isAtoB) {
            reserveA += amountIn;
            reserveB -= amountOut;
            totalFeesA += fee;
        } else {
            reserveB += amountIn;
            reserveA -= amountOut;
            totalFeesB += fee;
        }

        // Transfer out
        ChronosToken(isAtoB ? address(tokenB) : address(tokenA)).transfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut);
    }

    /**
     * @notice Sync stored reserves to the contract's actual token balances.
     * @dev Useful to reconcile reserves after any direct token transfer into
     *      the pool that bypassed the standard {addLiquidity} flow.
     */
    function sync() external {
        reserveA = tokenA.balanceOf(address(this));
        reserveB = tokenB.balanceOf(address(this));
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW
    // ═══════════════════════════════════════════════════════════════

    function getReserves() external view returns (uint256, uint256) {
        return (reserveA, reserveB);
    }

    function getK() external view returns (uint256) {
        return reserveA * reserveB;
    }

    function getSpotPrice() external view returns (uint256) {
        if (reserveA == 0) return 0;
        return (reserveB * 1e18) / reserveA;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL
    // ═══════════════════════════════════════════════════════════════

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
