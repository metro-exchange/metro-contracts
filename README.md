# THOR/yTHOR Migration to METRO

## November 13: METRO ownership and Contributor revocation

METRO now requires the nominated owner to accept ownership. Only the current Core owner may revoke a Contributor schedule: vested-but-unclaimed principal becomes ordinary xMETRO and unvested METRO goes to the current `forfeitureRecipient`. Existing rewards, queues and schedule indices are preserved. See [the API](integration/docs/contract-api.md#contributor-vesting-revocation) and [validation results](integration/testing/ethereum-fork/RESULTS.md). These source changes do not update previously deployed instances.

## November 9: configurable exit forfeiture recipient

The production Core owner can now change the recipient of future THOR/yTHOR exit forfeitures, matching the existing QA interface. The fixed treasury migration exclusion and user payout rules remain unchanged. See [the recipient API](integration/docs/contract-api.md#exit-forfeiture-recipient) and [validation results](integration/testing/ethereum-fork/RESULTS.md).

## November 3: Sherlock Issue #24

THOR exits now use two fixed payout levels. Production pays 50% of converted METRO principal from 30 days until just before 90 days, then 100% at 90 days and later. Base QA uses the same levels at 1 hour and 3 hours. Earlier exits are blocked. Each position closes once; queued payouts do not increase later. yTHOR rules and existing deployed instances are unchanged. See [Issue #24](https://github.com/sherlock-audit2/2026-10-thorswap-oct-16th-2026/issues/24) and the [validation results](integration/testing/ethereum-fork/RESULTS.md).

## October 30 audit remediation

The local source includes capped swap inputs (Adapter implementation version 2), two-step ownership for METRO/Core/Escrow/Distributor, transient reentrancy guards, custom business errors, and initial configuration events. Existing deployed instances and historical configuration files retain their original behavior.

Build with the pinned Solidity **0.8.38** compiler and **Osaka** EVM target in `foundry.toml`. Core, Escrow and Distributor use OpenZeppelin `ReentrancyGuardTransient`; their target chain must support EIP-1153 and the other instructions emitted for Osaka. Adapter keeps its existing proxy-local guard. Rebuild Core, Adapter and deployment artifacts together and recompute approved initcode hashes; old artifacts must not be mixed with this source. See [validation results](integration/testing/ethereum-fork/RESULTS.md) for executed checks and remaining RPC coverage.

## October 24 source update

This source version changes yTHOR exits to 20%-100% of the converted METRO principal. Production opens exits after 120 days and reaches 100% over the following `4 * 365 days`; Base QA keeps its 4-hour delay and 12-hour ramp. Repeated migrations, independent position IDs, one complete exit per position, and `1e24` reward-debt precision are retained.

Only THOR/yTHOR migration positions owned by `migrationRewardExcludedAddress()` earn no USDC rewards and are excluded from the allocation denominator. Ordinary stakes, Contributor shares, received free xMETRO and migration payouts staked after exit retain normal prospective rewards. Existing earned rewards and fractional entitlements are preserved.

The constructor initializes `forfeitureRecipient` and permanently fixes `migrationRewardExcludedAddress` from the same `forfeitureRecipient_` argument. For production, keep `FORFEITURE_RECIPIENT=0x7D8911eB1C72F0Ba29302bE30301B75Cec81F622` at construction. To use another forfeiture destination, the current Core owner calls `setForfeitureRecipient(newRecipient)` afterward; passing the new destination to the constructor instead would also change the fixed exclusion address.

Both production and Base QA allow a nonzero forfeiture recipient to be set, including while paused. The change applies to future THOR/yTHOR exits by all users, including already-created open positions, and to future Contributor revocations of existing or new schedules. It does not change the fixed excluded treasury, reward weights, accrued rewards, prior transfers or queued payouts. The treasury retains normal exit and ordinary-staking rights; its own forfeitures return to it only while it is the configured recipient. This does not enforce a 90-day treasury lock.

For a future Base QA deployment, explicitly set `BASE_QA_FORFEITURE_RECIPIENT` to the initial excluded treasury before creating the deployment plan. The script rejects missing addresses or a conflicting saved plan. Read `forfeitureRecipient()` and `migrationRewardExcludedAddress()` independently after any owner update. Source changes do not modify existing deployments; use the ABI matching the deployed revision.

The existing Base QA deployment and its address/configuration records remain unchanged. Use the ABI and examples from that deployment's revision (QA baseline `60754e05436c6c8056b60eac481d0bdc96a89d4c`) with its existing addresses. This version's ABI/examples target newly created local instances or a future deployment requested by the project. Source changes do not update an immutable deployed Core or migrate its storage.

This Foundry project implements THOR/yTHOR migration, METRO staking, USDC rewards, automated reward actions, commission routing, and upgradeable DeFi integrations.

**Base QA branch:** this branch uses the seven shortened waiting periods listed below. It is not the production-time audit build. The checked-in Base QA records describe the earlier deployment and its initial roles; verify current ownership separately before operating those contracts.

## Contract architecture

- `src/metro.sol`: METRO ERC-20 with Permit, owner-managed minters, and an immutable 100 million token supply cap.
- `src/xMETRO.sol`: immutable user-facing core for staking, migration positions, vesting, reward accounting, actions, and emergency reward distribution.
- `src/XMetroCoreLogic.sol`: internal code compiled into xMETRO; it is not separately deployed or linked as an external library.
- `src/XMetroDeFiAdapter.sol`: UUPS implementation behind an ERC1967 proxy for swaps and DeFi deposits. It does not write xMETRO storage.
- `src/ThorMigrationEscrow.sol`: THOR/yTHOR migration, ratios, caps, deadlines, and repeated migrations within cumulative caps.
- `src/RewardDistributor.sol`: operator-triggered USDC reward distribution and optional commission routing.

“Two-contract reward architecture” refers to xMETRO and its DeFi Adapter, not to the total number of deployed addresses. METRO, Escrow, Distributor, the Adapter implementation, and its proxy have separate addresses. Users and Keepers call xMETRO; only the currently bound xMETRO may invoke the Adapter execution functions.

```text
User / frontend / Keeper
          |
          v
  Immutable xMETRO core
          |
          v
 ERC1967 Adapter proxy --UUPS--> XMetroDeFiAdapter implementation
          |
          +--> Uniswap V2 / V3 / 1inch AggregationRouter
          +--> Aave V3 Pool
          +--> Aave V4 GiverPositionManager --> Spoke
          +--> Maple SyrupRouter
```

MetroToken, xMETRO, ThorMigrationEscrow and RewardDistributor use two-step ownership. `transferOwnership(target)` nominates a pending owner; only that address can call `acceptOwnership()` to receive authority. A zero target cancels the nomination. Core and Escrow reject `renounceOwnership()` while paused, but still permit ownership handover and subsequent unpause. Renouncing while unpaused remains irreversible; Distributor retains its existing renounce behavior. METRO ownership and minter permissions remain independent; the Core starts unpaused.

Aave V4 users authorize the configured official GiverPositionManager on the Spoke. The Adapter supplies USDC through that Giver; the Adapter proxy itself does not require separate Spoke activation. A replacement Adapter proxy does not require users to repeat their Giver approval if the Spoke and Giver remain unchanged. Maple authorization, by contrast, is specific to the Adapter proxy and must be obtained again for a new proxy.

The architecture has no external Actions Library, ProxyAdmin, or arbitrary target/selector executor. A normal UUPS upgrade keeps the proxy address and increments `logicEpoch`; replacing the entire proxy increments the core's `deFiAdapterEpoch`. Both changes invalidate stale auto preferences.

## Reward actions

Adapter implementation version 2 requires the [versioned swap envelope](integration/docs/new-features.md#swap-execution-data) with a nonzero quoted USDC input cap for all four manual/batch swap and compound entrypoints. An increase above that cap reverts the complete action without consuming rewards. Core function signatures and deposit encodings are unchanged. Existing deployment records describe their original revisions.

A user may enable either legacy Auto-Compound or one general auto strategy, not both. A user may disable a preference while paused; enabling and executing actions require an unpaused core.

- `claimAndExecute(strategyId,minAmountOut,deadline,executionData)` consumes the caller's available USDC rewards. The recipient is fixed to the caller.
- `enableAutoStrategy` and `disableAutoStrategy` select or clear an auto swap/deposit preference.
- `executeAutoStrategyBatch` is Keeper-only and rechecks pending rewards, candidate deduplication, strategy selection, and preference versions on-chain.
- Legacy `enableAutocompound`, `disableAutocompound`, `autocompound`, and `autocompoundBatch` remain available. USDC-to-METRO compounding returns METRO to the core, which mints xMETRO shares.

Supported routes are USDC-to-METRO compounding through Uniswap V2/V3 or 1inch; swaps into approved ERC-20 outputs; Aave V3 deposits with scaled aToken distribution for batches; Aave V4 per-user supplies through the official Giver; and Maple deposits with authorization when needed and proportional syrupUSDC distribution. The initial Ethereum swap outputs are USDT, WBTC, GHO, XAUT, and syrupUSDC. The owner may enable or disable standard ERC-20 outputs; this is an asset allowlist, not an unrestricted execution mechanism.

Core and Adapter check actual USDC spent, output balance or share changes, minimum output, fixed recipients, and pre-existing balance baselines. Temporary allowances are cleared after execution. Both have reentrancy protection. Aave/Maple disabling does not call the old external protocol; enabling performs binding checks again. Configuration changes invalidate affected auto preferences without requiring a global pause.

Maple configuration stores a SyrupRouter and `bytes32 depositData`; syrupUSDC is derived from `router.pool()`. `bytes32(0)` is supported. An initial GraphQL authorization must be requested for the actual Adapter proxy address; API `v=0/1` is converted off-chain to `27/28`. The applicable transfer and transferFrom permission bitmaps must also permit batch share distribution.

## Migration and exits

- Each address may migrate THOR and yTHOR repeatedly within the migration window and cumulative caps. Each call creates an independently timed position.
- THOR cannot exit before 1 hour. The payout is fixed at 50% of converted METRO principal from 1 hour until just before 3 hours, and is 100% at 3 hours and later. Production uses the same two levels at days 30 and 90.
- yTHOR principal uses the configured `ratioYThor`. Reward weight starts at the constructor's `YTHOR_REWARD_WEIGHT_BPS` (`10,000 = 1x`) and may be changed by the xMETRO owner without pausing. The current weight applies to future reward deposits for eligible active yTHOR positions, excluding those owned by `migrationRewardExcludedAddress()`; accrued rewards are not repriced. This QA build opens yTHOR exit at 4 hours and increases payout from 20% to 100% of the converted METRO principal over the next 12 hours. Production uses day 120 and a four-year ramp (4 * 365 days after the initial 120 days).
- Forfeited principal goes to the current `forfeitureRecipient`. The Core owner can redirect future THOR/yTHOR exit forfeitures and unvested Contributor recoveries with `setForfeitureRecipient(address)` in both builds.
- Liquid exits for free stake, THOR, yTHOR, and Contributor positions have separate 30-minute QA withdrawal queues (72 hours in production). Exit-to-stake produces transferable xMETRO immediately.
- Contributor vesting has a 6-hour QA cliff followed by 6 hours of linear release (180 days and 2.5 years in production).
- Transferring METRO to a dead address does not restore mint capacity; the global cap is permanently fixed at 100,000,000 METRO.

Only the current Core owner can call `revokeContributorVesting(user,scheduleId)`. Vested-but-unclaimed principal becomes ordinary xMETRO; unvested METRO goes to the current `forfeitureRecipient`. Prior rewards, queues and other plans remain intact. The schedule closes in place without changing its index. Contributor creation still requires the existing whitelist. See [revocation rules and integration](integration/docs/contract-api.md#contributor-vesting-revocation).

## Commission routing

```text
cap        = gross * maxCommissionSplitBps / 10,000
commission = min(cap, CommissionVault.requiredTopUp())
netReward  = gross - commission
```

The Distributor transfers the commission directly to the Vault and deposits the remaining USDC into xMETRO. It does not approve the Vault, invoke a Vault deposit callback, or carry a commission shortfall across batches. A nonzero split requires a compatible, finalized, unpaused Vault; setting the split to zero bypasses Vault calls.

## Production and Base QA versions

The production branch retains the full time constants and is the audit/mainnet baseline. The project-facing Base QA branch shortens seven waiting periods: 30-minute unstake delay; THOR pays a fixed 50% from 1 hour until just before 3 hours, then 100% at 3 hours and later; yTHOR exit starting at 4 hours with a 12-hour ramp; and a 6-hour Contributor cliff plus 6-hour vesting period. QA migration starts in the Escrow deployment block, and the THOR and yTHOR deadlines are both 30 days later. Both QA conversion ratios are `0.3928569546`. Both builds allow the Core owner to update the forfeiture recipient. QA additionally allows an Escrow constructor start value of zero to mean its deployment block; production requires an explicit start time. Other business ratios, two-step business-contract ownership, and default unpaused state remain aligned; their time constants and bytecode differ. QA uses freshly deployed owner-mintable TestTokens, Aave/Maple protocol mocks, and real Base Uniswap V2 liquidity. Mock integration does not prove the production protocols are available on Base.

Historical rapid-QA addresses and receipts are test evidence only. The fresh project-facing deployment is recorded separately in `integration/config/base-qa.json`; that file must never mix historical addresses with the new deployment.

## Repository guide

- [Contract function reference](CONTRACT_FUNCTION_REFERENCE.md)
- [Frontend/backend integration](integration/README.md)
- `src/`: business contracts
- `script/`: production deployment, verification, and Adapter lifecycle scripts
- `script/base-qa/`: Base QA deployment tools on the QA branch
- `.env.example`: production deployment parameters; use chain-specific values
- `deployments/<chainId>/addresses.json`: verified deployment addresses and settings

## Configure and deploy

Copy `.env.example` to an untracked local `.env`. Fill in the signing EOA, intended owner, chain-specific tokens and routers, migration ratios/windows, and integrations that are ready to enable. Never commit a private key. Build and inspect the intended release artifacts before broadcasting; a dry run is not evidence that any transaction was sent. Deployment and configuration consist of multiple transactions, so verify every receipt and on-chain binding.

The recorded Base QA system is already deployed at the addresses in [`integration/config/base-qa.json`](integration/config/base-qa.json). Its TestTokens, mocks, liquidity, and project contracts were prepared with `script/base-qa/`; that deployment helper uses local signer material and the public QA role-address file. The Forge commands below describe a separate generic deployment, not the recorded 87-transaction QA setup.

`script/Deploy.s.sol` nominates the target owner for METRO, Core, Escrow and Distributor after configuration, skipping nomination when the target is the deployer. Its JSON `owner` is the target; per-contract Owner/pendingOwner fields record actual deployment-time state. The target must accept each contract separately. `script/VerifyDeployment.s.sol` requires all four live owners to equal the target and all pending owners to be zero, even if the original deployment snapshot still records pending acceptance. The JSON includes `metroOwner` and `metroPendingOwner`; nomination does not transfer mint roles. Core starts unpaused.

```bash
# Ethereum
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --rpc-url "$ETH_RPC_URL" --broadcast

# Base
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --broadcast
```

## Reward accounting precision

Core tracks signed reward debt at the existing `1e24` accumulator precision. Share changes retain the full debt product. Claims, emergency payments, manual actions, and automatic batches consume only whole USDC base units and retain the fractional remainder. Zero-value claims preserve that remainder. `rewardDebt(user)` keeps its ABI and displays USDC base units, truncating negative fractions toward zero; use `claimable` / `claimableMany` for payable amounts instead of reconstructing them from the display getter. Adapter inputs and event amounts remain in token base units.
