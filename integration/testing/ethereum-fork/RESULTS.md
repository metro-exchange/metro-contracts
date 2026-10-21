# Ethereum Mainnet Fork Results and Evidence

## October 21 update: multi-position migration and precision

Baseline: `60754e05436c6c8056b60eac481d0bdc96a89d4c` plus the local uncommitted changes recorded in the [manifest](evidence/2026-10-21-multi-migration/manifest.json). The three changed business sources are `ThorMigrationEscrow.sol`, `XMetroCoreLogic.sol`, and `xMETRO.sol`. Production yTHOR now reaches 50% at migration + 120 days + 4 * 365 days. QA retains its 4-hour delay and 12-hour ramp. Both variants preserve fractional reward debt and use indexed migration positions.

| Suite | Passed | Failed | Skipped | Evidence |
| --- | ---: | ---: | ---: | --- |
| regression | 133 | 0 | 0 | [Log](evidence/2026-10-21-multi-migration/regression.log) |
| core | 53 | 0 | 2 | [Log](evidence/2026-10-21-multi-migration/core.log) |
| adapter | 43 | 0 | 2 | [Log](evidence/2026-10-21-multi-migration/adapter.log) |
| deployment | 1 | 0 | 0 | [Log](evidence/2026-10-21-multi-migration/deployment.log) |

The formal Ethereum fork suite compiled successfully in this QA tree. It was not executed with QA artifacts because its expected time constants are production values. The corresponding production tree passed all 156 fork tests; this QA tree uses its own local unit/core tests for accelerated timing.

Core runtime is **22,805 bytes**, under the unchanged **23,552-byte** project limit; constructor bytecode is 24,353 bytes before arguments. Adapter runtime remains 20,487 bytes. Local CREATE/deployment-script tests passed. Four optional pinned ETH/Base deployment tests were skipped because RPC variables were explicitly unset in local profiles; these are not represented as passing tests.

Coverage added to existing test files includes repeated migrations and cap rollback, stable IDs and independent clocks, out-of-order exits and queues, exact yTHOR quarter/boundary payouts, reward fractions in all four settlement helpers, transfers and negative debt, mixed accumulators, an independent accrual reference model, and funded-liability invariants. Fuzz tests use 256 runs; invariant campaigns use 128 runs at depth 100. The former balance-shortfall exceptions were removed from the Adapter invariant handler.

ABI export/signature checks, changed-file formatting, example syntax, zero/large position ID encoding, all four indexed events, and English-only changed-file checks passed. QA Maple script arguments are `16/0/0`; the current deployed addresses, token balances and permissions were not changed. Old F-01 and Base N-04 evidence below remains historical; no new Base acceptance is claimed.

Reproduction from the matching tree after dependencies are installed:

```sh
FOUNDRY_PROFILE=adapter forge build --offline
FOUNDRY_PROFILE=core forge build --offline
FOUNDRY_PROFILE=regression forge test --offline
FOUNDRY_PROFILE=core forge test --offline
FOUNDRY_PROFILE=adapter forge test --offline
FOUNDRY_PROFILE=deployment-test forge test --offline
FOUNDRY_PROFILE=fork-v2 forge build --offline
```

Production fork execution only:

```sh
ETH_RPC_URL=https://eth.drpc.org FOUNDRY_PROFILE=fork-v2 forge test --offline --match-path 'test/fork-v2/mainnet/*.t.sol' -vv
```

These commands execute locally. They do not broadcast transactions. Historical gas studies and Affiliate coverage were not repeated.

## Historical execution record

This file reports the recorded execution for the [functional checklist](CHECKLIST.md). All transactions occurred on a **local fork**, never on Ethereum mainnet. Check the source/artifact manifest when comparing these results with a later build; a changed source tree is not automatically covered by an older log.

These Ethereum results belong to the production-time source identified in the manifest, not to this Base QA branch's shortened-time bytecode. They must not be counted as a fork run of the Base QA deployment.

## Recorded run

| Item | Recorded value |
| --- | --- |
| Run ID | `2026-09-29-eth26077998-01` |
| Chain and fork block | Ethereum, chain ID `1`, block `26,077,998` |
| Block hash | `0xb75cb3bedaa74adf79199d847c94bbca4724d092da355d3e13c354773e2eb2aa` |
| Block timestamp | `1790623139` |
| Build | `solc 0.8.30`, Osaka EVM, Core/Adapter optimizer 50 runs, `via_ir=true`; full hashes in [manifest.json](evidence/2026-09-29-eth26077998-01/manifest.json) |
| Complete 15-suite run | **155 passed, 1 failed, 0 skipped** out of 156; [actual Forge log](evidence/2026-09-29-eth26077998-01/current-mainnet-suite-rerun.log) |
| Functional checkpoints | **140/143 accepted**; E-05.07, E-07.02 and E-14.07 remain open because of F-01 |
| Additional cross-check | X-03 partly covered, not accepted as a full real-protocol matrix |
| Batch gas matrix | **40/45** size/path cells produced successful local receipts; five cells have no successful receipt |

The principal command was:

```bash
ETH_RPC_URL=<Ethereum RPC> FOUNDRY_PROFILE=fork-v2 \
  forge test --match-path 'test/fork-v2/mainnet/*.t.sol' -vv
```

The [fork block readback](evidence/2026-09-29-eth26077998-01/fork-block.json), [version provenance](evidence/2026-09-29-eth26077998-01/continuation-provenance.json), [Core layout](evidence/2026-09-29-eth26077998-01/core-storage-layout.json), and [Adapter layout](evidence/2026-09-29-eth26077998-01/adapter-storage-layout.json) are retained. Historical test functions for the superseded two-step Owner/default-paused design are not counted as current ownership evidence. The current business code uses one-step ownership and does not pause Core in its constructor; later focused regression and artifact checks are recorded in [the current-Core log](evidence/2026-09-29-eth26077998-01/X07-current-core-rerun.log) and [artifact log](evidence/2026-09-29-eth26077998-01/X07-current-release-artifacts.log). These focused reruns do not turn the failed full-suite assertion into a pass.

## Project deployment and real assets

The test normally CREATE-deployed fresh METRO, Core, Escrow, Distributor, Adapter implementation, ERC1967 Proxy and a Vault from the supplied source. The recorded local addresses include Core `0x2e234DAe75C793f67A35089C9d99245E1C58470b`, Proxy `0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9`, Distributor `0xc7183455a4C133Ae270771860664b6B7ec320bB1`, and Escrow `0xa0Cb889707d426A7A386870A03bc70d1b0697598`. These are deterministic **local fork addresses**, not production deployments.

USDC, THOR and yTHOR were transferred from accounts with actual balances at the fork block; see [source-account readbacks](evidence/2026-09-29-eth26077998-01/real-token-sources.json). The test did not replace those token contracts or write balance/allowance storage. Fresh METRO was minted by its authorized Minter. The new METRO/USDC V2 pair was funded through the real Router. Its test liquidity and price are not proposed production liquidity.

## Functional evidence index

The links below point to actual Forge logs and test files. A log for a group may contain several test functions; the [checklist](CHECKLIST.md) defines the acceptance scope.

| Checks | Test file(s) | Evidence and outcome |
| --- | --- | --- |
| E-01–E-05 | `DeploymentGovernance.t.sol`, `TokenStakeRewards.t.sol` | [Focused base log](evidence/2026-09-29-eth26077998-01/E01-E05-forge.log): 28 passed; E-05's tiny-reward sample passed, but the broader rounding check remains open after F-01. |
| E-06 | `ContributorVesting.t.sol` | [Cliff/linear/queue log](evidence/2026-09-29-eth26077998-01/E06-forge.log): 8 passed. The known zero-yield cursor rollback was observed, not fixed. |
| E-07–E-08 | `AutoCompound.t.sol` | [Compound log](evidence/2026-09-29-eth26077998-01/E07-E08-forge.log): 9 passed, 1 failed (E-07.02/F-01). Real V2 succeeded on the other paths. |
| E-09, E-23 | `DeploymentGovernance.t.sol` | [Governance/emergency log](evidence/2026-09-29-eth26077998-01/E01-E09-E23-forge.log): 18 passed. A 101-user emergency distribution is a Forge transaction, not a separate Anvil gas-matrix receipt. |
| E-10–E-13 | `MigrationExit.t.sol` | [Real THOR/yTHOR migration and exit log](evidence/2026-09-29-eth26077998-01/E10-E13-forge.log): 20 passed. |
| E-14 | `YThorRewardWeight.t.sol` | [Weight log](evidence/2026-09-29-eth26077998-01/E14-forge.log): 7 focused tests passed; E-14.07 remains open because the related global reward-debt sequence fails elsewhere. |
| E-15 | `MigrationExit.t.sol` | [Aggregate preview log](evidence/2026-09-29-eth26077998-01/E15-forge.log): 3 passed. |
| E-16 | `CommissionRouting.t.sol` | [New Vault integration log](evidence/2026-09-29-eth26077998-01/E16-forge.log): 7 passed. This does not audit the Vault's internal payout implementation. |
| E-17 | `SwapRoutes.t.sol`, `OneInchSwap.t.sol` | [V2/V3 log](evidence/2026-09-29-eth26077998-01/E17-V2-V3-forge.log), [five-output 1inch log](evidence/2026-09-29-eth26077998-01/E17-X02-X04-final-forge.log), and [website route data](evidence/2026-09-29-eth26077998-01/oneinch-gas-proxy-five-routes.json). Ordinary swap only; no Affiliate acceptance. |
| E-18 | `AaveV3Deposit.t.sol` | [Real Pool/aUSDC log](evidence/2026-09-29-eth26077998-01/E18-forge.log): 4 passed. |
| E-19 | `AaveV4GiverDeposit.t.sol` | [Official Giver/Spoke log](evidence/2026-09-29-eth26077998-01/E19-forge.log): 7 passed. The Giver was already registered/active; no simulated Aave administrator approval. |
| E-20 | `MapleDeposit.t.sol` | [Real Router/syrupUSDC log](evidence/2026-09-29-eth26077998-01/E20-forge.log): 6 passed, with [actual API authorization data](evidence/2026-09-29-eth26077998-01/maple-api-response.json) for this Proxy. |
| E-21–E-22, X-05 | `AdapterLifecycle.t.sol` | [Complete lifecycle rerun](evidence/2026-09-29-eth26077998-01/X05-E21-E22-forge.log): 14 passed; [new-Proxy Maple authorization](evidence/2026-09-29-eth26077998-01/maple-new-proxy-api-response.json) was obtained separately. |
| X-01, X-06 | `CrossSourcePaths.t.sol`, `CommissionNetPaths.t.sol` | [Cross-source and commission-net log](evidence/2026-09-29-eth26077998-01/X01-X06-five-swaps-forge.log). |
| X-02, X-04 | Protocol suites | [Five-swap negative/event rerun](evidence/2026-09-29-eth26077998-01/E17-X02-X04-final-forge.log) and protocol logs above. |
| X-07 | Release checks | [Artifact verification](evidence/2026-09-29-eth26077998-01/X07-current-release-artifacts.log) and [current-Core rerun](evidence/2026-09-29-eth26077998-01/X07-current-core-rerun.log). |

The Aave V3 test used Pool `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` and aUSDC `0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c`. The Aave V4 test used official Giver `0x17A54b8d6D9C68e7fa1C7112AC998EA1BA51d11e`, Spoke `0x94e7A5dCbE816e498b89aB752661904E2F56c485`, and USDC reserve ID `7`. The Maple test used Router `0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76` and syrupUSDC `0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b`. These are fork-block-specific integration targets, not a claim that they will stay unchanged.

## F-01: reward-debt rounding failure

In `test_E07_ManualIndependentOfAutoPreference`, successive successful compounding actions are followed by a real Distributor injection of `10,000,000` USDC base units. `claimable(user)` returns `10,000,001`, while Core holds only `10,000,000`. The next compound reverts when Core attempts to transfer the extra unit. The trace and assertions are in the [E-07/E-08 log](evidence/2026-09-29-eth26077998-01/E07-E08-forge.log) and the [complete-suite log](evidence/2026-09-29-eth26077998-01/current-mainnet-suite-rerun.log). This is a demonstrated accounting problem, not a missing RPC credential. The observed root-cause candidate is separately rounded reward-debt updates for changed share balances. No fix is claimed in this record. E-05.07, E-07.02, and E-14.07 stay open, and gas receipts on affected sequences do not prove balance-sheet correctness.

X-03 has real atomic-reversion evidence for V4 last-user revocation/minimum failure and other total-minimum or permission failures, but does not cover every requested last-user failure mode on the real 1inch/V3/Maple paths. Mock fault injection is separate evidence and has not been relabeled as real-protocol success.

## 1inch and Affiliate boundary

The five target assets were exercised with calldata obtained from the public 1inch website for the tested Proxy, amount and output asset. Input/output balances, recipient, supported `swap` selector, Router call and events were checked, including [one detailed USDT trace](evidence/2026-09-29-eth26077998-01/E17-USDT-event-trace.log). The public route is **not** proof of an Affiliate fee or referrer payment. No credentialed, fee-bearing Business API response was available for this run. Tests for unknown selectors or incompatible routes must remain negative tests, not claimed successful Affiliate executions.

## Gas receipts and limits

The gas harness used a local Anvil fork and submitted actual transactions to `127.0.0.1`. The [receipt audit](evidence/2026-09-29-eth26077998-01/gas-receipt-audit.json) and [batch receipt records](evidence/2026-09-29-eth26077998-01/G01-G09-anvil-receipts.json) distinguish successful receipts from estimates, retries and capacity failures. Successful size/path cells total **40 of 45**. The five missing cells are Auto-Swap syrupUSDC/200, Aave V3/200, Aave V4/100 and /200, and Maple/200. Aave V4/100 exceeded the single-transaction gas allowance at estimation; the V4/200 estimate reverted without a conclusive independent cause. Do not split a V4 Core batch into multiple transactions to label either cell passed.

Example 100-user successful gas used on the recorded routes: Auto-Compound `5,114,294` for the first batch and `3,370,094` for a later batch; Auto-Swap USDT `7,471,923`/`4,051,923`; WBTC `7,322,861`/`3,902,857`; GHO `7,239,705`/`3,801,552`. See the raw receipt records for the other paths, versions and prior balances. The Auto-Compound later state can still exhibit F-01; successful receipt status is not an accounting acceptance.

The original gas study and later XAUT retry did not always use identical Core artifacts; the [artifact variant record](evidence/2026-09-29-eth26077998-01/gas-artifact-variants.json) separates them. Do not mix their gas figures as one exact build. Public RPC timeouts also affected some retries, and those attempts remain in the evidence rather than being converted into passes.
