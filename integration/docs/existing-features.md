# Existing-Feature Migration and Compatibility

This guide compares the current contracts with the saved pre-change repository commit `e81be64c5fe97eb5380d0d7cac0ef18903877a46`. Existing staking, ERC-20, reward claiming, Contributor vesting, and Auto-Compound are not counted as wholly new features. See [new features](new-features.md), [roles and API](contract-api.md), and the [function reference](../../CONTRACT_FUNCTION_REFERENCE.md).

## Update addresses, ABIs, and approvals

The new system uses an immutable xMETRO user entrypoint and an upgradeable DeFi Adapter. Users still call xMETRO for staking, claiming, and reward actions, and call the Escrow to migrate. The old SwapAdapter is no longer the execution entrypoint. Existing balances, approvals, and user preferences do **not** move to new contracts merely because the frontend changes an address. This document is not a migration plan for any already-live legacy balances.

| Action | Transaction target | Prior approval |
| --- | --- | --- |
| Stake or stake-and-enable-compound | xMETRO | User approves METRO to xMETRO |
| Create Contributor schedule | xMETRO | Allowlisted contributor approves their own METRO to xMETRO |
| THOR / yTHOR migration | Escrow | User approves the respective input token to Escrow |
| Claim USDC or compound pending rewards | xMETRO | No user USDC approval |
| Request an exit, withdraw after cooldown, or exit to stake | xMETRO | No additional METRO approval |
| `distribute(amount)` | RewardDistributor | Operator approves its USDC to Distributor |
| `distributeFromBalance(amount)` | RewardDistributor | Uses USDC already held by Distributor |

Users do not approve the Adapter or Commission Vault for reward USDC. Keeper and reward operator are independent permissions even if one wallet holds both. Use integer smallest units: METRO/xMETRO have 18 decimals, USDC has 6, and output tokens use their on-chain `decimals()`. Time arguments are Unix seconds.

## THOR: two old tranches become one position

| Previous API or data | Current API or data | Integration change |
| --- | --- | --- |
| `migrateThor10m(amountIn)`, `migrateThor3m(amountIn)` | `migrateThor(amountIn)` | Remove the 10-month/3-month choice. |
| `cap10M`, `cap3M`; `minted10M`, `minted3M` | `capThor()`, `migratedThor()` | Display a single METRO-principal cap and used amount. |
| `ratio10M`, `ratio3M` | `ratioThor()` | Quote one 18-decimal ratio. |
| `deadline10M`, `deadline3M` | `deadlineThor()` | Use the unified THOR deadline. |
| Multiple `thorLock*` records | `thorPositions(user)` | Read one principal, migration time, exit time, and exited flag. |
| `requestWithdrawUnlockedThor(maxLocks)` | `requestThorExit()` | One-time exit enters the THOR cooldown queue. |
| `claimAndStakeUnlockedThor(maxLocks)` | `exitAndStakeThor()` | One-time payout becomes transferable xMETRO. |
| `creditLockedTHORFromMigration(...)` | `creditThorFromMigration(user,principal)` | Escrow-only; never called by the frontend. |

Before migration, read `migrationStartTime`, `deadlineThor`, `ratioThor`, `capThor`, `migratedThor`, and `hasMigratedThor(user)`. Approve THOR to Escrow and call `migrateThor(amountIn)`. Principal is `floor(amountIn * ratioThor / 1e18)`. Each address migrates THOR at most once; migration creates locked principal, not immediately transferable xMETRO.

`previewThorExit(user)` returns `eligible`, `rateBps`, `payout`, `forfeited`, and `eligibleAt`. Production payout is 50% at day 30 and increases linearly to 100% at day 90. `requestThorExit()` plus `withdrawThor(maxRequests)` is the liquid path; `exitAndStakeThor()` is the stake path. Either path closes the entire THOR position.

## yTHOR migration and reward presentation

`migrateYThor(amountIn)` keeps its name but now creates one position; check `hasMigratedYThor(user)` first. Read `yThorPositions(user)` instead of old multiple vesting entries. `exitYThor(0)` requests liquid exit and later `withdrawYThor(maxRequests)`; `exitYThor(1)` stakes the payout immediately. Both are one-time exits. `creditYThorFromMigration` is Escrow-only.

Principal is `floor(amountIn * ratioYThor / 1e18)`; the reward multiplier does not increase redeemable principal. In this Base QA build, payout starts at 10% after 4 hours and grows to 50% during the following 12 hours. Production uses day 120 and five years. Unreturned principal goes to `forfeitureRecipient`, not to a burn address. THOR and yTHOR migration markers are independent.

For reward UI, read `rewardWeightOf(user)` and `totalRewardWeight()`. `totalSharesOf(user)` reports actual principal shares and must not be mistaken for weighted reward shares. Do not hardcode a 2x yTHOR multiplier: the current owner-set weight affects future rewards for all active yTHOR positions without repricing historical pending.

## Changed management parameter meanings

| Old call | New call | Meaning |
| --- | --- | --- |
| `setDeadlines(deadline10M,deadline3M)` | `setDeadlines(deadlineThor,deadlineYThor)` | Same selector, now two different input tokens. |
| `setCaps(cap10M,cap3M)` | `setCaps(capThor,capYThor)` | Same selector, now METRO-principal caps for THOR and yTHOR. |
| `setRatios(ratio10M,ratio3M,ratioYThor)` | `setRatios(ratioThor,ratioYThor)` | Two 1e18-scaled nonzero values; callable once. |
| `setYThorLimits(cap,deadline)` | `setCaps` plus `setDeadlines` | Supply both tokens' settings. |
| `setSwapAdapter(address)` | `setDeFiAdapter(proxy)` | Bind the new Adapter **proxy**, not its implementation. |
| `setDefaultMaxThorLocks(maxLocks)` | Removed | THOR is one position, not a scan. |

The current xMETRO uses original one-step ownership, allows renouncing, and starts unpaused; these are not new business features. Already-deployed historical QA contracts still follow their own deployed ABI and must not be silently treated as the new version.

## Preserved behavior and notable differences

| Functionality | Current call | Important behavior |
| --- | --- | --- |
| Normal staking | `stake`, `stakeAndEnableAutocompound` | Approve METRO to xMETRO; 1:1 free shares. |
| Free unstake | `requestUnstake` then `withdrawFree` | Production cooldown is now 72 hours rather than the previous seven days. |
| xMETRO ERC-20 transfers | `transfer`, `transferFrom` | Transfer free shares and future reward weight; sender keeps accrued pending. |
| USDC claim | `claimable` then `claimRewards` | No user USDC approval; a quote can change before inclusion. |
| Contributor | Existing allowlist, stake, release, liquid/stake exits | This QA build has a 6-hour cliff and subsequent 6-hour release; production uses 180 days and 2.5 years. `maxSchedules=0` uses the configured default scan size. |
| Auto-Compound preference | `enableAutocompound`, `disableAutocompound` | Mutually exclusive with a general auto strategy; disabling remains available while paused. |
| Manual compound | `autocompound(minMetroOut,deadline,swapData)` | Same user entrypoint, execution now uses the Adapter. No prior auto opt-in is required. |
| Keeper compound batch | `autocompoundBatch(users,minMetroOut,deadline,swapData)` | One swap; shares allocated in proportion to pending rewards. |
| Reward injection | `distribute`, `distributeFromBalance` | Same operator entrypoints, now with optional commission diversion; Core receives net rewards. |

V2/V3 compound data remains `abi.encode(uint8 dexType, bytes routeData)`. `previewWithdrawableNow(user)` still has four return fields, but its THOR/yTHOR components now mean the payout from a current one-time exit. It includes unlocked Contributor value and excludes all withdrawal queues, even matured ones. Read each queue through its `unstakeRequestCount*`, `unstakeRequest*`, and `unstakeCursor*` getters.

## Events and indexing

| Old event/data | New event/data |
| --- | --- |
| Old four-field `MigratedThor` | `(user,amountIn,principal)`, with no tranche field. |
| `LockedTHORCredited`, `LockedVestingCredited` | `ThorPositionCreated`, `YThorPositionCreated`. |
| Per-schedule THOR/yTHOR release pages | `ThorExited`, `YThorExited`, `UnstakeRequested`, `Withdrawn`. |
| `SwapAdapterUpdated` | `DeFiAdapterUpdated(oldAdapter,newAdapter,adapterEpoch)`. |
| Single-address Distributor/Escrow update events | Old/new-address event formats. |
| `RewardsDistributed` | Amount is the **net** Core reward; `DistributionRouted` records gross and commission. |

Decode each log with the ABI of the contract version that emitted it. Do not reinterpret historical logs using a new event signature.

## Known integration boundaries

`claimableMany` quotes each input element and does not deduplicate or filter strategy preferences. The backend must deduplicate before using its total as a batch economic estimate. Contributor scans with no claimable value can revert without advancing the cursor. A continuous-compound rounding issue remains recorded as F-01 in the [Ethereum fork results](../testing/ethereum-fork/RESULTS.md). None of those known issues should be described as fixed solely because the integration documentation changed.
