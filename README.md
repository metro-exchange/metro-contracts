# THOR/yTHOR Migration to METRO

This Foundry project implements THOR/yTHOR migration, METRO staking, USDC rewards, automated reward actions, commission routing, and upgradeable DeFi integrations.

## Contract architecture

- `src/metro.sol`: METRO ERC-20 with Permit, owner-managed minters, and an immutable 100 million token supply cap.
- `src/xMETRO.sol`: immutable user-facing core for staking, migration positions, vesting, reward accounting, actions, and emergency reward distribution.
- `src/XMetroCoreLogic.sol`: internal code compiled into xMETRO; it is not separately deployed or linked as an external library.
- `src/XMetroDeFiAdapter.sol`: UUPS implementation behind an ERC1967 proxy for swaps and DeFi deposits. It does not write xMETRO storage.
- `src/ThorMigrationEscrow.sol`: THOR/yTHOR migration, ratios, caps, deadlines, and independent one-time migration markers.
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

xMETRO uses one-step `transferOwnership`, permits `renounceOwnership`, and starts unpaused. Renouncing is irreversible: configuration, reward-weight changes, and Adapter upgrades would become unavailable. If xMETRO is paused at that point, it could not be unpaused.

Aave V4 users authorize the configured official GiverPositionManager on the Spoke. The Adapter supplies USDC through that Giver; the Adapter proxy itself does not require separate Spoke activation. A replacement Adapter proxy does not require users to repeat their Giver approval if the Spoke and Giver remain unchanged. Maple authorization, by contrast, is specific to the Adapter proxy and must be obtained again for a new proxy.

The architecture has no external Actions Library, ProxyAdmin, or arbitrary target/selector executor. A normal UUPS upgrade keeps the proxy address and increments `logicEpoch`; replacing the entire proxy increments the core's `deFiAdapterEpoch`. Both changes invalidate stale auto preferences.

## Reward actions

A user may enable either legacy Auto-Compound or one general auto strategy, not both. A user may disable a preference while paused; enabling and executing actions require an unpaused core.

- `claimAndExecute(strategyId,minAmountOut,deadline,executionData)` consumes the caller's available USDC rewards. The recipient is fixed to the caller.
- `enableAutoStrategy` and `disableAutoStrategy` select or clear an auto swap/deposit preference.
- `executeAutoStrategyBatch` is Keeper-only and rechecks pending rewards, candidate deduplication, strategy selection, and preference versions on-chain.
- Legacy `enableAutocompound`, `disableAutocompound`, `autocompound`, and `autocompoundBatch` remain available. USDC-to-METRO compounding returns METRO to the core, which mints xMETRO shares.

Supported routes are USDC-to-METRO compounding through Uniswap V2/V3 or 1inch; swaps into approved ERC-20 outputs; Aave V3 deposits with scaled aToken distribution for batches; Aave V4 per-user supplies through the official Giver; and Maple deposits with authorization when needed and proportional syrupUSDC distribution. The initial Ethereum swap outputs are USDT, WBTC, GHO, XAUT, and syrupUSDC. The owner may enable or disable standard ERC-20 outputs; this is an asset allowlist, not an unrestricted execution mechanism.

Core and Adapter check actual USDC spent, output balance or share changes, minimum output, fixed recipients, and pre-existing balance baselines. Temporary allowances are cleared after execution. Both have reentrancy protection. Aave/Maple disabling does not call the old external protocol; enabling performs binding checks again. Configuration changes invalidate affected auto preferences without requiring a global pause.

Maple configuration stores a SyrupRouter and `bytes32 depositData`; syrupUSDC is derived from `router.pool()`. `bytes32(0)` is supported. An initial GraphQL authorization must be requested for the actual Adapter proxy address; API `v=0/1` is converted off-chain to `27/28`. The applicable transfer and transferFrom permission bitmaps must also permit batch share distribution.

## Migration and exits

- Each address may migrate THOR once and yTHOR once; the markers are independent.
- THOR cannot exit before day 30; the payout rises linearly from 50% on day 30 to 100% on day 90.
- yTHOR principal uses the configured `ratioYThor`. Reward weight starts at the constructor's `YTHOR_REWARD_WEIGHT_BPS` (`10,000 = 1x`) and may be changed by the xMETRO owner without pausing. The current weight applies to future reward deposits for all active yTHOR positions; accrued rewards are not repriced. yTHOR cannot exit before day 120; its payout rises from 10% then to 50% over five years.
- Forfeited principal goes to the immutable `forfeitureRecipient`.
- Liquid exits for free stake, THOR, yTHOR, and Contributor positions have separate 72-hour withdrawal queues. Exit-to-stake produces transferable xMETRO immediately.
- Contributor vesting has a 180-day cliff followed by 2.5 years of linear release.
- Transferring METRO to a dead address does not restore mint capacity; the global cap is permanently fixed at 100,000,000 METRO.

## Commission routing

```text
cap        = gross * maxCommissionSplitBps / 10,000
commission = min(cap, CommissionVault.requiredTopUp())
netReward  = gross - commission
```

The Distributor transfers the commission directly to the Vault and deposits the remaining USDC into xMETRO. It does not approve the Vault, invoke a Vault deposit callback, or carry a commission shortfall across batches. A nonzero split requires a compatible, finalized, unpaused Vault; setting the split to zero bypasses Vault calls.

## Production and Base QA versions

The production branch retains the full time constants and is the audit/mainnet baseline. The project-facing Base QA branch shortens seven waiting periods: 30-minute unstake delay; THOR exit at 1–3 hours; yTHOR exit starting at 4 hours with a 12-hour ramp; and a 6-hour Contributor cliff plus 6-hour vesting period. The QA build also allows its owner to change the forfeiture recipient for future exits and accepts a zero Escrow constructor start time as the deployment-block timestamp. The production recipient is immutable, and its Escrow requires an explicit start time. Other business ratios, one-step ownership, and default unpaused state remain aligned; the two builds do not have identical ABIs or bytecode. QA uses freshly deployed owner-mintable TestTokens, Aave/Maple protocol mocks, and real Base Uniswap V2 liquidity. Mock integration does not prove the production protocols are available on Base.

Historical rapid-QA addresses and receipts are test evidence only. The fresh project-facing deployment and its transaction hashes are recorded in the Base QA branch's integration config and checklist. The production branch keeps a Base config template; it must not be mistaken for a second deployment or mixed with historical addresses.

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

`script/Deploy.s.sol` transfers xMETRO ownership in one step and leaves it unpaused; no `acceptOwnership()` or initial `unpause()` is required. `script/VerifyDeployment.s.sol` can read back the broadcast deployment.

```bash
# Ethereum
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --rpc-url "$ETH_RPC_URL" --broadcast

# Base
FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --broadcast
```
