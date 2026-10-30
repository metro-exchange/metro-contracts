# Contract Function Reference

Swap and compound `bytes` arguments use the [version-2 envelope](integration/docs/new-features.md#swap-execution-data) with a quoted input cap. The four Core function signatures and all deposit encodings are unchanged.

This index follows the current `src/` contracts. See [legacy integration](integration/docs/existing-features.md), [new actions](integration/docs/new-features.md), and [roles/configuration](integration/docs/contract-api.md) for call flows. Solidity identifiers are preserved exactly.

## MetroToken

`constructor(string name_,string symbol_,address owner_)` deploys the capped ERC-20. `cap()` and `MAX_SUPPLY()` both expose the immutable `100_000_000 ether` maximum. The owner uses `setMinter(address,bool)`; only an approved minter may call `mint(address,uint256)`, and all minters share the one cap. ERC-20 and ERC-2612 Permit are supported. There is no burn entrypoint.

## ThorMigrationEscrow

Users call `migrateThor(uint256)` or `migrateYThor(uint256)`. Each successful call appends an independent position; a wallet may migrate either token repeatedly within its window and cumulative cap. The owner configures `setMigrationStartTime(uint256)`, `setDeadlines(uint256,uint256)`, `setRatios(uint256,uint256)` (nonzero and one-time), and `setCaps(uint256,uint256)`. A zero constructor start time is a Base QA-only shortcut for the Escrow deployment block. The owner also has `pause()`, `unpause()`, and `rescueTokens(address,address,uint256)`; THOR and yTHOR cannot be rescued. Caps and migrated counters are measured in post-conversion METRO principal, not input-token units. yTHOR reward weight belongs to xMETRO, not Escrow.

## xMETRO

xMETRO is immutable. `XMetroCoreLogic.sol` is internal code compiled into it, not a separately deployed or linked Library.

### Stake, positions, and withdrawal queues

- `stake(uint256)`; `stakeAndEnableAutocompound(uint256)`
- `requestUnstake(uint256)`; `withdrawFree(uint256)`
- Escrow-only `creditThorFromMigration(address,uint256)`; user `previewThorExit(address,uint256)`, `requestThorExit(uint256)`, `exitAndStakeThor(uint256)`, `withdrawThor(uint256)`
- Escrow-only `creditYThorFromMigration(address,uint256)`; user `previewYThorExit(address,uint256)`, `exitYThor(uint256,ExitMode)`, `withdrawYThor(uint256)`
- Contributor `stakeContributor(uint256,address)`, `requestWithdrawUnlockedContributor(uint256)`, `claimAndStakeUnlockedContributor(uint256)`, `withdrawContributor(uint256)`

This Base QA build has `UNSTAKE_DELAY = 30 minutes`, THOR exit from 50% at 1 hour to 100% at 3 hours, and yTHOR exit from 20% of converted principal at 4 hours to 100% over the next 12 hours. Production uses 72 hours, days 30–90, and day 120 plus four years (4 * 365 days) respectively. `previewWithdrawableNow(address)` aggregates currently exit-eligible THOR/yTHOR payouts and unlocked Contributor value; it excludes every already-requested withdrawal queue. Queue information is available through the corresponding `unstakeRequestCount*`, `unstakeRequest*`, and `unstakeCursor*` getters.

### Reward accounting

- `depositRewards(uint256)` accepts calls only from the bound RewardDistributor.
- `claimRewards()` claims the caller's USDC pending balance.
- `claimable(address)` and `claimableMany(address[])` provide quotes; the latter is per input element and does not deduplicate.
- `rewardWeightOf(address)` and `totalRewardWeight()` apply the current yTHOR multiplier after excluding the fixed treasury's migration principal.
- `migrationRewardExcludedAddress()` returns the immutable migration-only exclusion address.
- `YTHOR_EXIT_START_BPS()` is `2000`; `YTHOR_EXIT_MAX_BPS()` is `10000`, both relative to converted METRO principal.
- `totalSharesOf(address)` and `totalShares()` report actual METRO-principal shares, not multiplied reward weight.

Ordinary shares and eligible yTHOR principal have separate reward accumulators, so changing the multiplier does not reprice accrued rewards. The excluded address keeps normal ordinary-stake, Contributor, transfer and exit-to-stake rewards.

The constructor fixes `migrationRewardExcludedAddress` from the existing `forfeitureRecipient_` argument; no constructor argument or user-action signature changes. For production, configure `FORFEITURE_RECIPIENT=0x7D8911eB1C72F0Ba29302bE30301B75Cec81F622`. Both production addresses are immutable. The treasury keeps normal migration and exit rights. If it exits early, forfeited METRO returns to that same recipient and only the payout is queued or staked; the project's intention not to exit early is not an on-chain restriction.

For a future Base QA deployment, explicitly set the existing `BASE_QA_FORFEITURE_RECIPIENT` before creating the deployment plan. The script rejects missing addresses or a different address in a saved plan. QA `setForfeitureRecipient()` changes only the forfeiture recipient; it never changes the fixed migration reward exclusion address or historical rewards. The existing on-chain QA deployment has not acquired these changes.

### Manual Adapter action

```solidity
claimAndExecute(bytes32 strategyId,uint256 minAmountOut,uint256 deadline,bytes executionData)
    returns (uint256 rewardIn,uint256 amountOut)
```

The Core consumes all of the caller's available USDC rewards, sends that amount to its current Adapter proxy, and fixes the beneficiary/recipient to the caller. A failure reverts the complete reward accounting and asset movement. Swap data is `abi.encode(dexType,routeData)` (`0=Uniswap V2`, `1=Uniswap V3`, `2=1inch V6`). Aave V3/V4 use empty data. Maple uses empty data once authorized or ABI-encoded `(bitmap,signatureDeadline,v,r,s)` for authorization.

### General auto strategy

- `enableAutoStrategy(bytes32)`; `disableAutoStrategy()`; `getAutoStrategyPreference(address)`
- Keeper-only `executeAutoStrategyBatch(bytes32,address[],uint256,uint256[],uint256,bytes)`

A preference binds the strategy ID, Core Adapter epoch, Adapter logic epoch, protocol-domain revision, and strategy revision. The Core filters zero/duplicate addresses, empty pending balances, wrong or stale preferences, and disabled users without consuming their rewards. Aave V4 minimum outputs follow the original candidate indexes through filtering.

### Legacy Auto-Compound retained

- `enableAutocompound()`; `disableAutocompound()`
- `autocompound(uint256,uint256,bytes)`
- Keeper-only `autocompoundBatch(address[],uint256,uint256,bytes)`

Legacy compound and general auto strategies are mutually exclusive. A batch swaps USDC to METRO once and mints proportional xMETRO shares. The largest-pending user receives integer dust; a tie follows candidate order.

### Administration

- `setDeFiAdapter(address proxy)` checks runtime code, core/USDC/METRO binding, Adapter family, valid configuration, and logic version. A full replacement increments `deFiAdapterEpoch`.
- `setYThorRewardWeightBps(uint256)` changes future rewards for all eligible active yTHOR positions without pausing. `10,000=1x`; zero and sub-1x values are valid up to the technical bound.
- `setForfeitureRecipient(address)` is Base QA-only and lets the current owner redirect future THOR/yTHOR exit forfeitures to a nonzero address. Production has an immutable recipient and no setter.
- `setAutoCompoundOperator(address,bool)`; `setMigrationEscrow(address)`; `setRewardDistributor(address)`; `setContributor(address,bool)`; `setDefaultMaxVestingSchedules(uint256)`
- `pause()`; `unpause()`; `rescueERC20(address,address,uint256)` (principal-backing METRO is protected)
- Core, Escrow and Distributor expose `pendingOwner()`, `transferOwnership(address)` and `acceptOwnership()`. Nomination preserves the current owner; a zero target cancels it. Acceptance clears pending ownership. `renounceOwnership()` clears both owner fields and is irreversible; Core/Escrow reject it while paused. Paused handovers remain available. MetroToken remains one-step. The Core constructor leaves it unpaused.

Normal configuration and UUPS implementation upgrades do not require a pause. A full proxy replacement should remain paused throughout its multi-transaction handover. A UUPS implementation upgrade increments `logicEpoch` without changing the proxy address; a proxy replacement increments `deFiAdapterEpoch`. Both make older auto preferences stale.

### Emergency USDC distribution

`emergencyDistribute(address[])` is owner-only, requires a paused Core, and has reentrancy protection. The nonempty candidate list has no fixed on-chain length cap. Zero, duplicate, and zero-pending addresses are skipped. A failed transfer reverts the whole batch. No METRO principal or migration position is moved.

## XMetroDeFiAdapter through its ERC1967 proxy

Users and Keepers do **not** call the Adapter execution functions directly. Only the currently bound, unpaused xMETRO can call `execute(ManualExecution)` and `executeBatch(BatchExecution)`, each returning `ExecutionResult`.

### Identity and readbacks

`xMETRO()`, `USDC()`, `METRO()`, `adapterFamilyId()`, `implementationVersion()`, `logicEpoch()`, `strategyInfo(bytes32)`, `configuration()`, `aaveV4Giver()`, and UUPS `UPGRADE_INTERFACE_VERSION()` (`5.0.0`).

```text
strategyId = keccak256(abi.encode(chainId, keccak256("XMETRO_DEFI_STRATEGY_V1"), kind, outputToken))
```

Aave V4 uses `outputToken=address(0)` because its user supply is internal Spoke shares rather than a separate ERC-20.

### Owner configuration

The current Core owner sends these calls to the currently bound **proxy**, not to its implementation. Effective changes advance applicable revisions and invalidate stale preferences:

- `setRouters(address v2,address v3,address oneInch)` fixes three deployed swap targets.
- `setSwapMetroConfig(bool enabled,bool autoEnabled)` and `setSwapTokenConfig(address tokenOut,bool enabled,bool autoEnabled)` manage METRO and allowlisted output swaps.
- `setAaveV3Config(address pool,address aUSDC,uint16 referralCode,bool enabled,bool autoEnabled)` validates aUSDC-to-USDC, aUSDC-to-Pool, and Pool reserve-to-aUSDC relationships.
- `setAaveV4Config(address spoke,address giver,uint256 reserveId,bool enabled,bool autoEnabled)` validates the USDC reserve plus Giver registration and activation.
- `setMapleConfig(address syrupRouter,bytes32 depositData,bool enabled,bool autoEnabled)` validates Router/Pool/PoolManager/PermissionManager and USDC/share relationships.

Disabling an Aave or Maple path does not call the old external protocol. Reenabling validates it again.

### Execution rules

- V2 checks the USDC-to-output address path; V3 checks packed single/multihop endpoints and fee path length. Both fix exact input, minimum output, recipient, and deadline.
- 1inch accepts only validated AggregationRouter V6 `swap(executor,description,data)`, with exact USDC input, allowlisted output, the Adapter as Router recipient, nonempty call data, and no unsupported partial/native/Permit2 behavior.
- Aave V3 deposits manually for the user or once for a batch, then distributes only newly received scaled aToken shares without consuming prior donations.
- Aave V4 uses the official Giver per user in one Core transaction; it checks Giver activation, user permission, returned `(shares,assets)`, actual asset spend, share increases, and each user's minimum.
- Maple checks authorization or signature, calls `deposit` or `authorizeAndDeposit`, and distributes newly received syrupUSDC shares.

All paths check spent/received balances, minimum output, recipients, cleared temporary allowances, and pre-existing balance baselines. The seven stable error categories are `AccessStateFailure`, `ConfigurationFailure`, `InvalidExecutionRequest`, `SlippageFailure`, `AccountingFailure`, `AaveV4AuthorizationFailure`, and `MapleAuthorizationFailure`.

### Upgrade and rescue

`upgradeToAndCall(address,bytes)` is the UUPS entrypoint. Authorization requires the current Core owner, a still-bound proxy, a different implementation with the expected Adapter family, and OpenZeppelin ERC-1822/1967 checks; it does not require a Core pause. A successful upgrade increments `logicEpoch` once and emits `Upgraded`. `rescueERC20(address,address,uint256)` requires the Core owner and a paused Core. An old replaced proxy may still be rescued but cannot be configured or upgraded.

The Adapter's ERC-7201 storage namespace is `0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00`.

## RewardDistributor

The owner configures `setOperator(address,bool)`, `setCommissionVault(address)`, `setMaxCommissionSplitBps(uint16)`, and `rescueTokens(address,address,uint256)`. A nonzero Vault must match USDC and this Distributor, be finalized, and be unpaused. The split BPS range is `0..10,000`.

An approved operator calls `distribute(uint256)` to pull USDC from its approved wallet, or `distributeFromBalance(uint256)` to use Distributor-held USDC. For each gross amount:

```text
cap        = grossAmount * maxCommissionSplitBps / 10,000
commission = min(cap, commissionVault.requiredTopUp())
netReward  = grossAmount - commission
```

The Distributor transfers commission USDC directly to the Vault, then deposits `netReward` into xMETRO. It does not approve the Vault, invoke a Vault deposit callback, or maintain a cross-batch commission debt ledger.

## Position queries and events

Read `thorPositionCount(user)` / `yThorPositionCount(user)` before querying `thorPositions(user, positionId)` / `yThorPositions(user, positionId)`. Each returns `(principal, migratedAt, exitedAt, exited)`. IDs start at zero independently for each user and asset, are never reused, and counts include exited positions. Out-of-range queries and exits revert with array `Panic(0x32)`. A valid premature or exited position has an ineligible preview; attempting its exit reverts with `InvalidConfiguration`.

`previewThorExit(user, positionId)` / `previewYThorExit(user, positionId)` return eligibility, rate in BPS, payout, forfeiture and eligibility timestamp. Exit calls select one of the caller's positions: `requestThorExit(positionId)`, `exitAndStakeThor(positionId)`, or `exitYThor(positionId, mode)` (`Liquid=0`, `Stake=1`). Only Liquid creates a withdrawal queue entry; queue indices are independent of position IDs. Counts and individual reads support client-side paging. `previewWithdrawableNow(user)` sums eligible open positions and Contributor value, excludes queues, and scans history; do not make claims or single-position exits depend on that aggregate call for large accounts.

`ThorPositionCreated` and `YThorPositionCreated` carry `(indexed user, indexed positionId, principal, migratedAt)`. `ThorExited` and `YThorExited` carry `(indexed user, indexed positionId, principal, payout, forfeited, rateBps, mode, exitedAt, indexed forfeitureRecipient)`. Index positions by chain ID, Core address, user, asset and position ID. The Escrow's two `hasMigrated*` getters are removed; migration availability depends on the window, caps and permissions.

## Reward accounting precision

Core tracks signed reward debt at the existing `1e24` accumulator precision. Share changes retain the full debt product. Claims, emergency payments, manual actions, and automatic batches consume only whole USDC base units and retain the fractional remainder. Zero-value claims preserve that remainder. `rewardDebt(user)` keeps its ABI and displays USDC base units, truncating negative fractions toward zero; use `claimable` / `claimableMany` for payable amounts instead of reconstructing them from the display getter. Adapter inputs and event amounts remain in token base units.

`YTHOR_EXIT_RAMP()` returns seconds: `126144000` for production, `43200` for QA. These are compiled constants with no Owner setter.

Initial configuration logs and their emitters are listed in [events and indexing](integration/docs/existing-features.md#events-and-indexing).

## Business errors

The following errors have no arguments. Decode with the matching contract ABI; external failures and Solidity panics retain their original data. Check ordering and business conditions are unchanged.

| Contract | Error | Trigger |
| --- | --- | --- |
| MetroToken | `MinterStatusUnchanged()` | same status |
| MetroToken | `UnauthorizedMinter()` | not minter |
| MetroToken | `InvalidRecipient()` | bad to |
| MetroToken | `ZeroAmount()` | zero amount |
| ThorMigrationEscrow | `ZeroXMetro()` | zero xMETRO |
| ThorMigrationEscrow | `ZeroMigrationToken()` | zero token |
| ThorMigrationEscrow | `InvalidMigrationStartTime()` | bad start time |
| ThorMigrationEscrow | `MigrationNotStarted()` | not started |
| ThorMigrationEscrow | `ZeroAmount()` | zero amount |
| ThorMigrationEscrow | `ThorConfigurationMissing()` | thor config not set |
| ThorMigrationEscrow | `ThorMigrationExpired()` | thor expired |
| ThorMigrationEscrow | `ZeroMintAmount()` | zero mint |
| ThorMigrationEscrow | `ThorCapExceeded()` | thor cap |
| ThorMigrationEscrow | `YThorConfigurationMissing()` | ythor config not set |
| ThorMigrationEscrow | `YThorMigrationExpired()` | ythor expired |
| ThorMigrationEscrow | `YThorCapExceeded()` | ythor cap |
| ThorMigrationEscrow | `InvalidMigrationDeadline()` | bad deadline |
| ThorMigrationEscrow | `DeadlineNotAfterMigrationStart()` | deadline before start |
| ThorMigrationEscrow | `InvalidMigrationRatio()` | bad ratio |
| ThorMigrationEscrow | `MigrationRatiosLocked()` | ratios locked |
| ThorMigrationEscrow | `InvalidMigrationCap()` | bad cap |
| ThorMigrationEscrow | `MigrationTokenRescueForbidden()` | cannot rescue migration tokens |
| ThorMigrationEscrow | `InvalidRecipient()` | bad to |
| RewardDistributor | `ZeroXMetro()` | zero xMETRO |
| RewardDistributor | `UnauthorizedOperator()` | only operator |
| RewardDistributor | `InvalidOperator()` | bad operator |
| RewardDistributor | `CommissionSplitEnabled()` | split enabled |
| RewardDistributor | `InvalidCommissionSplitBps()` | bps > 10000 |
| RewardDistributor | `ZeroAmount()` | zero amount |
| RewardDistributor | `InsufficientRewardBalance()` | insufficient balance |
| RewardDistributor | `ZeroCommissionVault()` | zero vault |
| RewardDistributor | `CommissionVaultNotContract()` | vault not contract |
| RewardDistributor | `CommissionTokenMismatch()` | token mismatch |
| RewardDistributor | `CommissionDistributorMismatch()` | distributor mismatch |
| RewardDistributor | `CommissionVaultMigrationPending()` | vault migration pending |
| RewardDistributor | `CommissionVaultPaused()` | vault paused |
| RewardDistributor | `InvalidRecipient()` | bad to |
