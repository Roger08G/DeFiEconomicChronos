# ChronosVault Protocol — Bug Bounty Lab

**Category**: Time-Locked Vault · Constant-Product AMM · Upgradeable Proxy · Governance · Cross-Contract State  
**Difficulty**: Hard  
**Solidity**: ^0.8.20 · **Framework**: Foundry  
**Total Findings to Discover**: 5 (2 Critical · 2 High · 1 Medium)  
**Lab Type**: Intentionally Vulnerable — Educational Use Only

---

> **nSLOC**: ~850  
> **Contracts**: 6  
> **Audited Vulnerabilities**: 5 (2 Critical, 2 High, 1 Medium)  
> **Chain**: Ethereum Mainnet (Anvil / Hardhat fork)

---

## 1. Protocol Overview

**ChronosVault** is a time-locked vault system with an integrated constant-product AMM, staking rewards with position transferability, an upgradeable proxy architecture, governance timelock, and a cross-contract balance registry. Users lock tokens for time-weighted governance, earn streaming rewards, and trade via the protocol's AMM.

The protocol is designed so that:
- Users **trade** tokens through a constant-product AMM (`ChronosAMM`) with fee accumulation
- LPs earn fees that accumulate in the AMM reserves, increasing the value of LP positions
- Users **stake** tokens for streaming reward distribution (`StakingRewards`), with transferable positions
- The vault uses an **upgradeable proxy** pattern (`UpgradeableVault`) for future feature upgrades
- Admin operations are gated through a **timelock** (`TimelockController`) with configurable delay
- A **balance registry** (`BalanceRegistry`) provides cached balance lookups for cross-contract accounting

The protocol's diversity of patterns (AMM invariants, proxy storage, governance timelocks, cross-contract state) makes it an ideal test for detection breadth.

---

## 2. Architecture

```
                    ┌──────────────────────────────────┐
                    │         User / Frontend           │
                    └──┬──────┬──────┬──────┬──────┬───┘
                       │      │      │      │      │
          ┌────────────▼──┐   │  ┌───▼───────┐  ┌──▼────────────┐
          │  ChronosAMM   │   │  │ Staking   │  │  Upgradeable  │
          │  (x·y=k AMM)  │   │  │ Rewards   │  │  Vault        │
          │  swap/LP/fees │   │  │ (stream)  │  │  (proxy +     │
          └───────────────┘   │  └───────────┘  │   impl)       │
                              │                  └───────────────┘
          ┌───────────────┐   │   ┌────────────────────────────┐
          │ Timelock       │   │   │    BalanceRegistry         │
          │ Controller     │◄──┘   │  (cached cross-contract    │
          │ (admin delay)  │       │   balance lookups)         │
          └───────────────┘       └────────────────────────────┘

                    ┌──────────────┐
                    │ ChronosToken │
                    │ (CHRN ERC20) │
                    └──────────────┘
```

---

## 3. Contracts

| Contract | File | nSLOC | Description |
|----------|------|-------|-------------|
| `ChronosToken` | `ChronosToken.sol` | ~70 | ERC20 base token with owner-only mint/burn |
| `ChronosAMM` | `ChronosAMM.sol` | ~200 | Constant-product AMM (x·y=k) with per-swap fee accumulation |
| `StakingRewards` | `StakingRewards.sol` | ~180 | Synthetix-style reward streaming with transferable staked positions |
| `UpgradeableVault` | `UpgradeableVault.sol` | ~160 | Minimal proxy + implementation vault with storage layout |
| `TimelockController` | `TimelockController.sol` | ~140 | Governance timelock with configurable minimum delay |
| `BalanceRegistry` | `BalanceRegistry.sol` | ~100 | Cross-contract cached balance tracker for accounting lookups |

**Total nSLOC**: ~850

---

## 4. Scope & Focus

All 6 contracts are in scope. The audit covers **diverse vulnerability categories** across different DeFi primitives:
- AMM invariant accounting (fee accumulation vs LP share calculation)
- Reward accounting integrity across transferable positions
- Proxy storage layout safety in upgradeable contracts
- Governance timelock bypass via self-referential execution
- Cross-contract stale state dependencies

Out of scope: Gas optimization, code style, informational findings.

---

## 5. Known Vulnerabilities (Post-Audit Disclosure)

The following 5 vulnerabilities were confirmed during the audit. They are disclosed here for educational purposes.

---

### V-01: K-Invariant Break via Fee Accumulation

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | LP Value Extraction — LPs withdraw more than deposited |
| **Likelihood** | High (triggers on normal protocol usage) |
| **File** | `ChronosAMM.sol` |
| **Location** | `swap()` re-adds fee to reserves; `removeLiquidity()` uses stale k snapshot |
| **Difficulty** | Hard |

**Description**: The AMM charges a fee on each swap and adds the fee BACK into the reserves. This causes `k = reserveA * reserveB` to strictly increase over time with swap volume. However, `removeLiquidity()` computes LP share redemption based on the LP's proportional ownership of current reserves — which now include accumulated fees. The k-snapshot recorded at `addLiquidity()` time is never used for fair share computation.

This means an LP who adds liquidity, waits for fee accumulation through trading volume, and then removes liquidity receives back their deposit PLUS a disproportionate share of fees. The accounting mismatch allows early LPs to extract more value than the fees they are entitled to.

**Exploit Path**:
1. Attacker adds liquidity → receives LP shares based on current reserves
2. Heavy trading occurs → fees accumulate → `k` increases by 20%
3. Attacker removes liquidity → receives proportional share of CURRENT reserves
4. The proportional share includes accumulated fees that don't belong to attacker alone
5. If fee distribution doesn't properly track per-LP contribution, attacker extracts excess
6. Later LPs receive less than expected → implicit value transfer

**Recommendation**: Implement fee tracking separate from reserves (like Uniswap v2's `kLast` mechanism), or use accumulated fee-per-LP-share accounting to distribute fees proportionally to time staked.

---

### V-02: Reward Debt Not Updated on Stake Transfer

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Double-Claim of Rewards (reward theft from other stakers) |
| **Likelihood** | High (trivial to exploit) |
| **File** | `StakingRewards.sol` |
| **Location** | `transferStake()` — moves balance but not `rewardDebt` |
| **Difficulty** | Easy |

**Description**: `StakingRewards` allows users to transfer their staked position to another address via `transferStake()`. This function correctly moves the `stakedAmount` from sender to receiver, but does NOT update the `rewardDebt` for either party. The receiver inherits a clean reward state, meaning they can immediately call `claim()` and receive rewards as if they had been staking since the original deposit time.

**Exploit Path**:
1. Alice stakes 1,000 CHRN at block 100 → accumulates 500 CHRN in rewards by block 200
2. Alice claims 500 CHRN of rewards → her `rewardDebt` is updated
3. Alice transfers stake to her second address (Bob)
4. Bob's `rewardDebt` is 0 (not carried over from Alice)
5. Bob calls `claim()` → receives another 500 CHRN (same period rewards, double-claimed)
6. Bob transfers back to Alice → repeat indefinitely
7. Total rewards extracted = N × legitimate_reward_amount

**Recommendation**: In `transferStake()`, settle pending rewards for BOTH sender and receiver before transferring, then set receiver's `rewardDebt` to the current `accRewardPerShare * newBalance`.

---

### V-03: Delegatecall Storage Collision in Upgradeable Vault

| Field | Value |
|-------|-------|
| **Severity** | Critical |
| **Impact** | Complete Accounting Corruption — totalDeposits = implementation address |
| **Likelihood** | High (occurs on any proxy interaction) |
| **File** | `UpgradeableVault.sol` |
| **Location** | Proxy stores `implementation` at slot 0; impl stores `totalDeposits` at slot 0 |
| **Difficulty** | Hard (requires understanding proxy storage delegatecall semantics) |

**Description**: The `UpgradeableVault` uses a minimal proxy pattern where the proxy contract stores the `implementation` address at storage slot 0. The implementation contract declares `totalDeposits` as its first state variable — also at slot 0, and `owner` at slot 1. When the proxy `delegatecall`s the implementation, the implementation's code runs against the PROXY's storage. This means:
- Reading `totalDeposits` actually reads the `implementation` address (cast to uint256)
- Writing `totalDeposits` overwrites the `implementation` address
- Reading `owner` reads whatever is at slot 1 in the proxy

This collision corrupts all vault accounting from the moment the proxy is deployed.

**Exploit Path**:
1. Proxy is deployed with `implementation = 0xABCD...1234` at slot 0
2. User calls `deposit(1000)` through proxy → delegatecall to impl
3. Impl reads `totalDeposits` → gets `0xABCD...1234` cast to uint256 (huge number)
4. All share calculations based on `totalDeposits` are wildly incorrect
5. A malicious upgrade (`upgradeTo(newImpl)`) writes new address to slot 0
6. This simultaneously changes `totalDeposits` → complete accounting reset
7. Users who deposited before upgrade lose all tracked balances

**Recommendation**: Use the EIP-1967 storage pattern where the implementation address is stored at a pseudo-random slot (`bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)`), avoiding collision with sequential storage slots.

---

### V-04: Timelock Bypass via Self-Referential Admin Override

| Field | Value |
|-------|-------|
| **Severity** | High |
| **Impact** | Governance Safety Bypass — admin can execute instantly |
| **Likelihood** | Medium (requires admin cooperation or compromise) |
| **File** | `TimelockController.sol` |
| **Location** | `schedule()` + `execute()` — `MIN_DELAY` can be set to 0 via self-referential call |
| **Difficulty** | Medium |

**Description**: The `TimelockController` enforces a minimum delay (e.g., 2 days) on admin operations. However, the `setMinDelay()` function is itself gated through the timelock. An admin can schedule a call to `setMinDelay(0)`, wait the current delay period, execute it, and then all subsequent operations have ZERO delay — effectively bypassing the timelock entirely.

More critically, `block.timestamp` has a ~15-second miner tolerance. Combined with scheduling at block boundaries, the effective delay can be shorter than the configured minimum.

**Exploit Path**:
1. Current `MIN_DELAY = 2 days`
2. Admin schedules `timelock.setMinDelay(0)` with the 2-day delay
3. After 2 days, admin executes → `MIN_DELAY` is now 0
4. Admin can now schedule AND execute any operation instantly
5. Admin drains treasury, changes ownership, upgrades contracts — all with zero governance delay
6. Community has no time window to react or veto

**Recommendation**: Enforce an immutable minimum delay floor that cannot be changed (e.g., `MIN_DELAY >= 1 day` hardcoded), or require a separate multi-sig approval for delay reduction below a threshold.

---

### V-05: Cross-Contract Stale Balance Dependency

| Field | Value |
|-------|-------|
| **Severity** | Medium |
| **Impact** | Incorrect Accounting Decisions Based on Stale Data |
| **Likelihood** | Medium (requires non-standard token operations) |
| **File** | `BalanceRegistry.sol` |
| **Location** | `getBalance()` returns cached values; updated only via explicit `recordDeposit/recordWithdraw` |
| **Difficulty** | Medium |

**Description**: The `BalanceRegistry` provides balance lookups for other protocol contracts. It caches balances and updates them only when `recordDeposit()` or `recordWithdraw()` is explicitly called. If tokens are transferred via direct ERC20 `transfer()` (bypassing the registry), the cached balance becomes stale. Any contract calling `BalanceRegistry.getBalance()` for accounting decisions operates on incorrect data.

**Exploit Path**:
1. User deposits 1,000 CHRN via the standard flow → registry records 1,000
2. User directly calls `ChronosToken.transfer(vault, 500)` → vault receives 500 extra tokens
3. `BalanceRegistry.getBalance(vault)` still returns 1,000 (not 1,500)
4. Contracts relying on registry for share price, collateral checks, or fee calculations use stale value
5. Accounting diverges: actual balance > recorded balance → value trapped
6. Or: user withdraws via standard flow → registry tracks 1,000 but vault sends based on actual balance

**Recommendation**: Use actual `balanceOf()` calls instead of cached values for critical accounting, or implement hooks in the token's `transfer()` function to auto-update the registry.

---

## 6. Vulnerability Summary

| ID | Name | Severity | Impact | Difficulty | Primary Contract |
|----|------|----------|--------|------------|-----------------|
| V-01 | K-Invariant Fee Break | **Critical** | LP value extraction | Hard | ChronosAMM |
| V-02 | Reward Debt Transfer Gap | **High** | Double reward claims | Easy | StakingRewards |
| V-03 | Delegatecall Storage Collision | **Critical** | Accounting corruption | Hard | UpgradeableVault |
| V-04 | Timelock Self-Referential Bypass | **High** | Governance bypass | Medium | TimelockController |
| V-05 | Stale Balance Registry | **Medium** | Incorrect accounting | Medium | BalanceRegistry |

**Severity Distribution**: 2 Critical, 2 High, 1 Medium

---

## 7. Security Design Rationale

The protocol spans **five distinct vulnerability categories** across different DeFi primitives:

1. **AMM invariant analysis** (V-01): Fee accumulation breaking k-constant assumptions
2. **Reward accounting integrity** (V-02): State not propagated on position transfer
3. **Proxy storage layout** (V-03): Delegatecall storage collision — requires cross-contract storage analysis
4. **Governance safety** (V-04): Self-referential timelock override — a subtle admin privilege escalation
5. **Cross-contract stale state** (V-05): Cached data diverging from actual token balances

---

## 8. Build & Test

```bash
# Build all contracts
forge build

# Run the test suite
forge test -vv

# Generate a gas and coverage report
forge coverage
```
