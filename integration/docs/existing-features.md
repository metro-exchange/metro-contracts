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

## THOR: one migration path with multiple positions

| Previous API or data | Current API or data | Integration change |
| --- | --- | --- |
| `migrateThor10m(amountIn)`, `migrateThor3m(amountIn)` | `migrateThor(amountIn)` | Remove the 10-month/3-month choice. |
| `cap10M`, `cap3M`; `minted10M`, `minted3M` | `capThor()`, `migratedThor()` | Display a single METRO-principal cap and used amount. |
| `ratio10M`, `ratio3M` | `ratioThor()` | Quote one 18-decimal ratio. |
| `deadline10M`, `deadline3M` | `deadlineThor()` | Use the unified THOR deadline. |
| Multiple `thorLock*` records | `thorPositions(user, positionId)` | Read the selected position's principal, migration time, exit time, and exited flag. |
| `requestWithdrawUnlockedThor(maxLocks)` | `requestThorExit(positionId)` | One-time exit enters the THOR cooldown queue. |
| `claimAndStakeUnlockedThor(maxLocks)` | `exitAndStakeThor(positionId)` | One-time payout becomes transferable xMETRO. |
| `creditLockedTHORFromMigration(...)` | `creditThorFromMigration(user,principal)` | Escrow-only; never called by the frontend. |

Before migration, read `migrationStartTime`, `deadlineThor`, `ratioThor`, `capThor`, and `migratedThor`. Approve THOR to Escrow and call `migrateThor(amountIn)`. Principal is `floor(amountIn * ratioThor / 1e18)`. Each successful migration appends a new position and creates locked principal. Repeated migrations remain subject to the window, cumulative cap and ratio.

`previewThorExit(user, positionId)` returns `eligible`, `rateBps`, `payout`, `forfeited`, and `eligibleAt`. Production payout is 50% at day 30 and increases linearly to 100% at day 90. `requestThorExit(positionId)` plus `withdrawThor(maxRequests)` is the liquid path; `exitAndStakeThor(positionId)` is the stake path. Either path closes only the selected THOR position in full.

## yTHOR migration and reward presentation

`migrateYThor(amountIn)` appends a new position on every successful call. Read `yThorPositionCount(user)` and `yThorPositions(user, positionId)`. `exitYThor(positionId, 0)` requests a liquid exit followed by `withdrawYThor(maxRequests)`; `exitYThor(positionId, 1)` stakes the payout immediately. Each position exits only once; other positions remain independent. `creditYThorFromMigration` remains Escrow-only.

Principal is `floor(amountIn * ratioYThor / 1e18)`; the reward multiplier does not increase redeemable principal. At day 120, the payout starts at 20% of converted principal and grows to 100% during the following four years (4 * 365 days). Unreturned principal goes to `forfeitureRecipient`, not to a burn address. Position IDs are independent for each user and asset.

For reward UI, read `rewardWeightOf(user)` and `totalRewardWeight()`. `totalSharesOf(user)` reports actual principal shares and must not be mistaken for weighted reward shares. Do not hardcode a 2x yTHOR multiplier: the current owner-set weight affects future rewards for all eligible active yTHOR positions without repricing historical pending.

## Changed management parameter meanings

| Old call | New call | Meaning |
| --- | --- | --- |
| `setDeadlines(deadline10M,deadline3M)` | `setDeadlines(deadlineThor,deadlineYThor)` | Same selector, now two different input tokens. |
| `setCaps(cap10M,cap3M)` | `setCaps(capThor,capYThor)` | Same selector, now METRO-principal caps for THOR and yTHOR. |
| `setRatios(ratio10M,ratio3M,ratioYThor)` | `setRatios(ratioThor,ratioYThor)` | Two 1e18-scaled nonzero values; callable once. |
| `setYThorLimits(cap,deadline)` | `setCaps` plus `setDeadlines` | Supply both tokens' settings. |
| `setSwapAdapter(address)` | `setDeFiAdapter(proxy)` | Bind the new Adapter **proxy**, not its implementation. |
| `setDefaultMaxThorLocks(maxLocks)` | Removed | Each exit selects a position ID; no scan limit is needed. |

The current Core, Escrow and Distributor use two-step ownership: nomination preserves the old owner until the pending owner accepts. A zero nomination cancels handover. Core/Escrow forbid renouncing while paused, but allow handover; Distributor has no pause mechanism. Core still starts unpaused. Already-deployed historical QA contracts still follow their own deployed ABI and must not be silently treated as the new version.

## Preserved behavior and notable differences

| Functionality | Current call | Important behavior |
| --- | --- | --- |
| Normal staking | `stake`, `stakeAndEnableAutocompound` | Approve METRO to xMETRO; 1:1 free shares. |
| Free unstake | `requestUnstake` then `withdrawFree` | Production cooldown is now 72 hours rather than the previous seven days. |
| xMETRO ERC-20 transfers | `transfer`, `transferFrom` | Transfer free shares and future reward weight; sender keeps accrued pending. |
| USDC claim | `claimable` then `claimRewards` | No user USDC approval; a quote can change before inclusion. |
| Contributor | Existing allowlist, stake, release, liquid/stake exits | 180-day cliff and subsequent 2.5-year release; `maxSchedules=0` uses the configured default scan size. |
| Auto-Compound preference | `enableAutocompound`, `disableAutocompound` | Mutually exclusive with a general auto strategy; disabling remains available while paused. |
| Manual compound | `autocompound(minMetroOut,deadline,swapData)` | Same user entrypoint, execution now uses the Adapter. No prior auto opt-in is required. |
| Keeper compound batch | `autocompoundBatch(users,minMetroOut,deadline,swapData)` | One swap; shares allocated in proportion to pending rewards. |
| Reward injection | `distribute`, `distributeFromBalance` | Same operator entrypoints, now with optional commission diversion; Core receives net rewards. |

All V2/V3/1inch compound and swap data now uses the version-2 [swap envelope](new-features.md#swap-execution-data), including a nonzero quoted USDC input cap. Core function signatures remain unchanged; old encoded data is rejected by the new Adapter. `previewWithdrawableNow(user)` still has four return fields, but its THOR/yTHOR components now mean the sum of payouts from all eligible, unexited positions. It includes unlocked Contributor value and excludes all withdrawal queues, even matured ones. Read each queue through its `unstakeRequestCount*`, `unstakeRequest*`, and `unstakeCursor*` getters.

## Events and indexing

| Old event/data | New event/data |
| --- | --- |
| Old four-field `MigratedThor` | `(user,amountIn,principal)`, with no tranche field. |
| `LockedTHORCredited`, `LockedVestingCredited` | `ThorPositionCreated`, `YThorPositionCreated`. |
| Per-schedule THOR/yTHOR release pages | `ThorExited`, `YThorExited`, `UnstakeRequested`, `Withdrawn`. |
| `SwapAdapterUpdated` | `DeFiAdapterUpdated(oldAdapter,newAdapter,adapterEpoch)`. |
| Single-address Distributor/Escrow update events | Old/new-address event formats. |
| `RewardsDistributed` | Amount is the **net** Core reward; `DistributionRouted` records gross and commission. |

New deployments also emit the existing configuration events during construction or initialization:

| Emitter | Initial event | Meaning |
| --- | --- | --- |
| Escrow | `MigrationStartTimeUpdated(storedStart)` | The stored start time; QA input zero resolves to the deployment timestamp. |
| Core | `YThorRewardWeightBpsUpdated(0, initialWeight)` | Includes an initial weight of zero. |
| QA Core only | `ForfeitureRecipientUpdated(address(0), recipient)` | The initial payout recipient; the migration exclusion address remains fixed. |
| Adapter **proxy** | `ConfigurationChanged(strategyId, 1)` for SwapMetro and AaveV4 | Each initial strategy has revision 1 and both enabled flags false. Creation is not activation. |

Index Adapter configuration logs at the proxy address, including the deployment transaction. Read the corresponding getters for full state. Subsequent semantic updates still advance the same revisions; initialization cannot be repeated. For ownership, `OwnershipTransferStarted` only nominates; `OwnershipTransferred` records the actual change after acceptance (or construction/renounce).

Decode each log with the ABI of the contract version that emitted it. Do not reinterpret historical logs using a new event signature.

## Known integration boundaries

`claimableMany` quotes each input element and does not deduplicate or filter strategy preferences. The backend must deduplicate before using its total as a batch economic estimate. Contributor scans with no claimable value can revert without advancing the cursor. The historical F-01 reward-rounding failure and current precision regression results are kept separately in the [test results](../testing/ethereum-fork/RESULTS.md).

| Time from this position's migration | Production payout | QA time |
| --- | ---: | --- |
| 120 days | 20% | 4 hours |
| 120 days + 365 days | 40% | 7 hours |
| 120 days + 2 * 365 days | 60% | 10 hours |
| 120 days + 3 * 365 days | 80% | 13 hours |
| 120 days + 4 * 365 days or later | 100% | 16 hours or later |

Times use fixed seconds, not calendar/leap years. Intermediate payouts follow integer BPS rounding. At exit, unpaid principal goes to `forfeitureRecipient`; the position is fully closed. Liquid payouts are fixed when queued, with the existing 72-hour production / 30-minute QA cooldown. They do not increase during that cooldown.

## Position queries and events

Read `thorPositionCount(user)` / `yThorPositionCount(user)` before querying `thorPositions(user, positionId)` / `yThorPositions(user, positionId)`. Each returns `(principal, migratedAt, exitedAt, exited)`. IDs start at zero independently for each user and asset, are never reused, and counts include exited positions. Out-of-range queries and exits revert with array `Panic(0x32)`. A valid premature or exited position has an ineligible preview; attempting its exit reverts with `InvalidConfiguration`.

`previewThorExit(user, positionId)` / `previewYThorExit(user, positionId)` return eligibility, rate in BPS, payout, forfeiture and eligibility timestamp. Exit calls select one of the caller's positions: `requestThorExit(positionId)`, `exitAndStakeThor(positionId)`, or `exitYThor(positionId, mode)` (`Liquid=0`, `Stake=1`). Only Liquid creates a withdrawal queue entry; queue indices are independent of position IDs. Counts and individual reads support client-side paging. `previewWithdrawableNow(user)` sums eligible open positions and Contributor value, excludes queues, and scans history; do not make claims or single-position exits depend on that aggregate call for large accounts.

`ThorPositionCreated` and `YThorPositionCreated` carry `(indexed user, indexed positionId, principal, migratedAt)`. `ThorExited` and `YThorExited` carry `(indexed user, indexed positionId, principal, payout, forfeited, rateBps, mode, exitedAt, indexed forfeitureRecipient)`. Index positions by chain ID, Core address, user, asset and position ID. The Escrow's two `hasMigrated*` getters are removed; migration availability depends on the window, caps and permissions.

## Reward accounting precision

Core tracks signed reward debt at the existing `1e24` accumulator precision. Share changes retain the full debt product. Claims, emergency payments, manual actions, and automatic batches consume only whole USDC base units and retain the fractional remainder. Zero-value claims preserve that remainder. `rewardDebt(user)` keeps its ABI and displays USDC base units, truncating negative fractions toward zero; use `claimable` / `claimableMany` for payable amounts instead of reconstructing them from the display getter. Adapter inputs and event amounts remain in token base units.

## Converted-principal example and treasury migration rewards

With a configured yTHOR conversion ratio of `0.5e18`, 100 yTHOR creates 50 METRO principal. An eligible ordinary user initially has 100 reward-weight units at 2x, receives 10 METRO at the earliest exit (20% of principal), or 50 METRO at maturity (100%). Conversion ratios and the adjustable reward multiplier remain configuration values. The weight multiplier does not multiply the exit payout.

The fixed treasury's migration positions have zero reward weight, while their full principal remains recorded and backed. Ordinary stakes, Contributor balances and free-share transfers keep their existing behavior. Exiting into staking adds only the payout as ordinary reward-bearing shares at the current accumulator, with no retroactive migration rewards.

The constructor fixes `migrationRewardExcludedAddress` from the existing `forfeitureRecipient_` argument; no constructor argument or user-action signature changes. For production, configure `FORFEITURE_RECIPIENT=0x7D8911eB1C72F0Ba29302bE30301B75Cec81F622`. Both production addresses are immutable. The treasury keeps normal migration and exit rights. If it exits early, forfeited METRO returns to that same recipient and only the payout is queued or staked; the project's intention not to exit early is not an on-chain restriction.

For a future Base QA deployment, explicitly set the existing `BASE_QA_FORFEITURE_RECIPIENT` before creating the deployment plan. The script rejects missing addresses or a different address in a saved plan. QA `setForfeitureRecipient()` changes only the forfeiture recipient; it never changes the fixed migration reward exclusion address or historical rewards. The existing on-chain QA deployment has not acquired these changes.
