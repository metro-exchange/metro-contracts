# THOR/yTHOR Migration to METRO

## October 30 audit remediation

The local source includes capped swap inputs (Adapter implementation version 2), two-step ownership for Core/Escrow/Distributor, transient reentrancy guards, custom business errors, and initial configuration events. Existing deployed instances and historical configuration files retain their original behavior.

Build with the pinned Solidity **0.8.38** compiler and **Osaka** EVM target in `foundry.toml`. Core, Escrow and Distributor use OpenZeppelin `ReentrancyGuardTransient`; their target chain must support EIP-1153 and the other instructions emitted for Osaka. Adapter keeps its existing proxy-local guard. Rebuild Core, Adapter and deployment artifacts together and recompute approved initcode hashes; old artifacts must not be mixed with this source. See [validation results](integration/testing/ethereum-fork/RESULTS.md) for executed checks and remaining RPC coverage.

## October 24 source update

This source version changes yTHOR exits to 20%-100% of the converted METRO principal. Production opens exits after 120 days and reaches 100% over the following `4 * 365 days`; Base QA keeps its 4-hour delay and 12-hour ramp. Repeated migrations, independent position IDs, one complete exit per position, and `1e24` reward-debt precision are retained.

Only THOR/yTHOR migration positions owned by `migrationRewardExcludedAddress()` earn no USDC rewards and are excluded from the allocation denominator. Ordinary stakes, Contributor shares, received free xMETRO and migration payouts staked after exit retain normal prospective rewards. Existing earned rewards and fractional entitlements are preserved.

The constructor fixes `migrationRewardExcludedAddress` from the existing `forfeitureRecipient_` argument; no constructor argument or user-action signature changes. For production, configure `FORFEITURE_RECIPIENT=0x7D8911eB1C72F0Ba29302bE30301B75Cec81F622`. Both production addresses are immutable. The treasury keeps normal migration and exit rights. If it exits early, forfeited METRO returns to that same recipient and only the payout is queued or staked; the project's intention not to exit early is not an on-chain restriction.

For a future Base QA deployment, explicitly set the existing `BASE_QA_FORFEITURE_RECIPIENT` before creating the deployment plan. The script rejects missing addresses or a different address in a saved plan. QA `setForfeitureRecipient()` changes only the forfeiture recipient; it never changes the fixed migration reward exclusion address or historical rewards. The existing on-chain QA deployment has not acquired these changes.

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

xMETRO, ThorMigrationEscrow and RewardDistributor use two-step ownership. `transferOwnership(target)` nominates a pending owner; only that address can call `acceptOwnership()` to receive authority. A zero target cancels the nomination. Core and Escrow reject `renounceOwnership()` while paused, but still permit ownership handover and subsequent unpause. Renouncing while unpaused remains irreversible; Distributor retains its existing renounce behavior. MetroToken remains one-step and the Core starts unpaused.

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
- THOR cannot exit before 1 hour; the payout rises linearly from 50% at 1 hour to 100% at 3 hours. Production uses days 30–90.
- yTHOR principal uses the configured `ratioYThor`. Reward weight starts at the constructor's `YTHOR_REWARD_WEIGHT_BPS` (`10,000 = 1x`) and may be changed by the xMETRO owner without pausing. The current weight applies to future reward deposits for eligible active yTHOR positions, excluding those owned by `migrationRewardExcludedAddress()`; accrued rewards are not repriced. This QA build opens yTHOR exit at 4 hours and increases payout from 20% to 100% of the converted METRO principal over the next 12 hours. Production uses day 120 and a four-year ramp (4 * 365 days after the initial 120 days).
- Forfeited principal goes to `forfeitureRecipient`. Only the Base QA xMETRO owner may update this address for future exits; the production recipient remains immutable.
- Liquid exits for free stake, THOR, yTHOR, and Contributor positions have separate 30-minute QA withdrawal queues (72 hours in production). Exit-to-stake produces transferable xMETRO immediately.
- Contributor vesting has a 6-hour QA cliff followed by 6 hours of linear release (180 days and 2.5 years in production).
- Transferring METRO to a dead address does not restore mint capacity; the global cap is permanently fixed at 100,000,000 METRO.

## Commission routing

```text
cap        = gross * maxCommissionSplitBps / 10,000
commission = min(cap, CommissionVault.requiredTopUp())
netReward  = gross - commission
```

The Distributor transfers the commission directly to the Vault and deposits the remaining USDC into xMETRO. It does not approve the Vault, invoke a Vault deposit callback, or carry a commission shortfall across batches. A nonzero split requires a compatible, finalized, unpaused Vault; setting the split to zero bypasses Vault calls.

## Production and Base QA versions

The production branch retains the full time constants and is the audit/mainnet baseline. The project-facing Base QA branch shortens seven waiting periods: 30-minute unstake delay; THOR exit at 1–3 hours; yTHOR exit starting at 4 hours with a 12-hour ramp; and a 6-hour Contributor cliff plus 6-hour vesting period. QA migration starts in the Escrow deployment block, and the THOR and yTHOR deadlines are both 30 days later. Both QA conversion ratios are `0.3928569546`. QA-only differences also allow the owner to update the forfeiture recipient and allow an Escrow constructor start value of zero to mean its deployment block. Production has neither behavior. Other business ratios, two-step business-contract ownership, and default unpaused state remain aligned; the two builds do not have identical ABIs or bytecode. QA uses freshly deployed owner-mintable TestTokens, Aave/Maple protocol mocks, and real Base Uniswap V2 liquidity. Mock integration does not prove the production protocols are available on Base.

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

`script/Deploy.s.sol` nominates the target owner for Core, Escrow and Distributor after configuration, skipping nomination when the target is the deployer. Its JSON `owner` is the target; per-contract Owner/pendingOwner fields record actual deployment-time state. The target must accept each contract separately. `script/VerifyDeployment.s.sol` requires all three live owners to equal the target and all pending owners to be zero, even if the original deployment snapshot still records pending acceptance. Core starts unpaused; MetroToken ownership still transfers in one step.

```bash
# Ethereum
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --rpc-url "$ETH_RPC_URL" --broadcast

# Base
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --broadcast
```

## Reward accounting precision

Core tracks signed reward debt at the existing `1e24` accumulator precision. Share changes retain the full debt product. Claims, emergency payments, manual actions, and automatic batches consume only whole USDC base units and retain the fractional remainder. Zero-value claims preserve that remainder. `rewardDebt(user)` keeps its ABI and displays USDC base units, truncating negative fractions toward zero; use `claimable` / `claimableMany` for payable amounts instead of reconstructing them from the display getter. Adapter inputs and event amounts remain in token base units.
