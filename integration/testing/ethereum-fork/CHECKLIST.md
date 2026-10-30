# Ethereum Mainnet Fork Functional Test Checklist

## October 30 audit remediation acceptance

| Coverage | Evidence / status |
| --- | --- |
| E-07/E-08/E-17: capped V2/V3/1inch data; stale quotes preserve rewards; fresh quotes succeed | Adapter/Core unit and invariant tests; `AutoCompound.t.sol::test_E07_StaleInputCapRollsBackAndFreshQuoteCompounds`; see current results for executed scope |
| E-01/E-09: pending ownership, acceptance, paused renounce protection | Updated governance and deployment-script tests |
| E-21/E-22/X-07: implementation version 2, unchanged epoch rules, ABI/storage compatibility and size | Existing Adapter, Core and deployment tests |
| E-01/E-09: initial stored configuration events, proxy emitters and rejected reinitialization | Escrow/Core unit and Adapter configuration tests |
| E-21/E-22/X-07: Solidity 0.8.38 / Osaka artifacts and transient guards on the target fork | Rebuild all profiles; run callback/retry tests locally and protocol scenarios with an available RPC |

Local results and skipped RPC scenarios are recorded in [RESULTS.md](RESULTS.md). The tables below describe earlier revisions, not acceptance of this remediation.

## October 24 source acceptance (historical)

| Updated coverage | Required evidence |
| --- | --- |
| E-01: new Core runtime/initcode lengths, unchanged size limits, initial bindings | Actual production-artifact deployment and size tests |
| E-13: 20%-100% of converted yTHOR principal, one-time exits, balances and cooldown | Unit/fuzz/mock tests and production `MigrationExit.t.sol` |
| E-14: treasury migration exclusion, normal ordinary rewards, exit-to-stake and preserved historical accrual | Unit/integration/fuzz/invariant tests and production `YThorRewardWeight.t.sol` |
| Reward settlement and rollback | Claims, emergency payments, manual/batch actions, positive-net-reward rollback and commission-only routing |

Results are recorded in [RESULTS.md](RESULTS.md). QA compiles the production fork suite and runs its own accelerated unit/core tests. These are local checks, with no on-chain deployment or GitHub publication implied.



## October 21 source acceptance (historical)

The checked tables below are historical results for the previous revision. They do not certify this update. Current commands and results are recorded separately in [RESULTS.md](RESULTS.md).

| Updated coverage | Acceptance source |
| --- | --- |
| E-10: repeated migrations, cumulative caps, independent position IDs and rollback | Local Escrow/Core tests and updated `MigrationExit.t.sol` |
| E-12/E-13: indexed exits, per-position clocks, production 120 days + 4 * 365 days; 10/20/30/40/50% boundaries | Unit/fuzz tests and updated production fork suite |
| E-05/E-07/E-14: F-01 precision, zero claims, transfer fractions, continuous compounding and multiple yTHOR positions | Unit/core/fuzz/invariant tests and updated production fork suite |

The formal fork suite executes against production artifacts. The QA branch only compiles that suite; its own unit/core tests validate accelerated time constants. Historical five-year/once-flag results below are preserved as historical facts.

## Historical execution record

This checklist tracks tests that deploy the project contracts locally against an Ethereum mainnet fork. It is not an Ethereum mainnet deployment. Actual results, source/artifact provenance, commands, and logs are in [RESULTS.md](RESULTS.md). A checked group means its in-scope assertions ran successfully on the recorded version; an unchecked group has an outstanding assertion. Do not infer a pass from the presence of a test file or from a Base Mock transaction.

The recorded fork uses chain ID `1`, block `26,077,998` (`0xb75cb3bedaa74adf79199d847c94bbca4724d092da355d3e13c354773e2eb2aa`). Project contracts, including METRO, xMETRO, Escrow, Distributor, Adapter implementation and Proxy, and a fresh Commission Vault are deployed with normal CREATE calls. Real mainnet USDC/THOR/yTHOR holders supply test balances by ordinary transfers on the local fork. METRO is newly minted by its authorized Minter. Rewards pass through the real Distributor. Successful external integrations use the fork's actual Uniswap, Aave, Maple, and 1inch contracts, not Mock protocol contracts. Time travel and account impersonation affect only the local fork.

## Existing functions and base accounting

| ID | Result | Required coverage | Test file |
| --- | --- | --- | --- |
| E-01 | [x] | Normal CREATE, code size/linking, Proxy initialization, bindings, deployment configuration, genuine Token funding, and real V2 liquidity. | `DeploymentGovernance.t.sol` |
| E-02 | [x] | METRO ERC-20, permit/nonce/domain, Minter grant/revoke, and global 100 million supply cap across Minters. | `TokenStakeRewards.t.sol` |
| E-03 | [x] | xMETRO transfer/allowance, non-transferable locked shares, historical pending retained by the sender, and future weight moved to the receiver. | `TokenStakeRewards.t.sol` |
| E-04 | [x] | Stake, stake-and-enable, 72-hour unstake queue, boundaries, pagination, cursor, and rollback. | `TokenStakeRewards.t.sol` |
| E-05 | [ ] | Both Distributor funding paths, Operator permissions, plain claims, share changes, `claimableMany`, zero-weight/zero-delta rejection, and tiny-reward rounding. E-05.07 is not accepted because the F-01 sequence can overstate claimable USDC by one unit. | `TokenStakeRewards.t.sol` |
| E-06 | [x] | Contributor allowlist, multiple schedules, 180-day cliff, 2.5-year linear vesting, claim-to-stake/liquid, queue and cursor semantics. | `ContributorVesting.t.sol` |
| E-07 | [ ] | Legacy single-user Auto-Compound through real V2, manual independence from auto opt-in, min-out, deadline, backing, and allowance cleanup. E-07.02 fails in the continuous-compound F-01 sequence. | `AutoCompound.t.sol` |
| E-08 | [x] | Keeper-only batch compound, one V2 swap, proportional minting, filtering, rounding, and atomic failure. | `AutoCompound.t.sol` |
| E-09 | [x] | Core/Escrow pause and rescue, Distributor/Adapter rescue boundaries, and permission checks. Historical two-step-Owner assertions are excluded from the current one-step-Owner result. | `DeploymentGovernance.t.sol` |

## New and replaced functions

| ID | Result | Required coverage | Test file |
| --- | --- | --- | --- |
| E-10 | [x] | Real THOR/yTHOR approve, custody, METRO mint and position creation; once flags, ratios, caps, deadlines and atomic failure. | `MigrationExit.t.sol` |
| E-11 | [x] | Migration start/deadline/cap/ratio setters and their permissions; the current ratio setter locks ratios on its first call. | `MigrationExit.t.sol` |
| E-12 | [x] | THOR 30–90-day exit curve, liquid or stake payout, forfeiture recipient, queue and preserved historical pending. | `MigrationExit.t.sol` |
| E-13 | [x] | yTHOR 120-day wait and five-year exit curve, liquid or stake payout, removal of active reward weight, queue and historical pending. | `MigrationExit.t.sol` |
| E-14 | [ ] | Owner-adjustable yTHOR reward weight for **all active** holders, prospective rewards only, zero/below-1x settings, migration/exit interactions and rounding. E-14.07 remains unaccepted because of F-01. | `YThorRewardWeight.t.sol` |
| E-15 | [x] | `previewWithdrawableNow` across THOR, yTHOR and unlocked Contributor amounts; withdrawal queues excluded. | `MigrationExit.t.sol` |
| E-16 | [x] | Distributor-to-Vault commission cap/shortfall, net reward, both funding paths, zero/full split and atomic rollback. Vault internals are outside this integration test. | `CommissionRouting.t.sol` |
| E-17 | [x] | USDC to USDT/WBTC/GHO/XAUT/syrupUSDC manual and auto swaps using real website-derived 1inch calldata; V2/V3 regression, whitelist and negative cases. **Affiliate fees are not covered without Affiliate calldata.** | `SwapRoutes.t.sol`, `OneInchSwap.t.sol` |
| E-18 | [x] | Real Aave V3 Pool/aUSDC manual deposit and single-supply batch distribution in scaled units; binding, referral, donation isolation and events. | `AaveV3Deposit.t.sol` |
| E-19 | [x] | Official Aave V4 Giver and Spoke authorization; manual and per-user batch supply, shares, revoked authorization, minima and events. | `AaveV4GiverDeposit.t.sol` |
| E-20 | [x] | Live Maple API authorization for the actual Proxy, first `authorizeAndDeposit`, later `deposit`, batch syrupUSDC distribution, signature and `depositData` checks. | `MapleDeposit.t.sol` |
| E-21 | [x] | Owner configuration while running, strategy/domain/logic revisions, disable-without-old-getter, only-Core execution and auto-preference invalidation. | `AdapterLifecycle.t.sol` |
| E-22 | [x] | UUPS implementation upgrade and full Proxy replacement, storage/epoch checks, old-instance rejection, V4 authorization continuity and Maple reauthorization. | `AdapterLifecycle.t.sol` |
| E-23 | [x] | Paused Owner-only emergency USDC distribution, deduplication and atomicity; old/new Escrow, Distributor and Keeper authority. | `DeploymentGovernance.t.sol` |

The tests for E-16 use a newly deployed Vault from the supplied source, but verify only its integration with `RewardDistributor`. They do not claim an independent audit of Vault-internal registration, settlement, payout, roles, timelocks or rescue.

## Cross-path checks

| ID | Result | Required coverage | Test file |
| --- | --- | --- | --- |
| X-01 | [x] | Stake, THOR, yTHOR, Contributor, mixed and exited positions through claim, compound, five swaps and three deposits. | `CrossSourcePaths.t.sol` |
| X-02 | [x] | Single/multiple users, unequal inputs, filtering, zero-rounded output, remainder, minimum-index mapping and invalid arrays. | Protocol and compound suites |
| X-03 | [ ] | Last-user failure reverts all previous user transfers and all protocol/accounting state. Mock fault-injection covers parts of this; the full real-protocol cross-path matrix was not completed. | Protocol suites |
| X-04 | [x] | Decode project and actual protocol events with their ABIs; check emitter, indexed fields, caller, receiver and balances. | Protocol suites |
| X-05 | [x] | Upgrade/replacement storage, preferences and real protocol authorizations. | `AdapterLifecycle.t.sol` |
| X-06 | [x] | Net reward after commission through claim, compound, five swaps, three deposits and emergency distribution. | `CommissionNetPaths.t.sol` |
| X-07 | [x] | Release artifacts, code size/link references, selectors, storage layout and deployment bindings. | `DeploymentGovernance.t.sol` plus artifact verification |

## Gas and capacity

The real-fork batch study records successful local transaction receipts, not merely estimates. Five cells did not produce a successful receipt because of single-transaction gas capacity or estimation limits. In the table, each cell corresponds to 1/10/50/100/200 users, in that order; `—` means no successful receipt and is **not** a business-function pass.

| Path | 1 | 10 | 50 | 100 | 200 |
| --- | --- | --- | --- | --- | --- |
| G-01 Auto-Compound | ✓ | ✓ | ✓ | ✓ | ✓ |
| G-02 Auto-Swap USDT | ✓ | ✓ | ✓ | ✓ | ✓ |
| G-03 Auto-Swap WBTC | ✓ | ✓ | ✓ | ✓ | ✓ |
| G-04 Auto-Swap GHO | ✓ | ✓ | ✓ | ✓ | ✓ |
| G-05 Auto-Swap XAUT | ✓ | ✓ | ✓ | ✓ | ✓ |
| G-06 Auto-Swap syrupUSDC | ✓ | ✓ | ✓ | ✓ | — |
| G-07 Aave V3 | ✓ | ✓ | ✓ | ✓ | — |
| G-08 Aave V4 Giver | ✓ | ✓ | ✓ | — | — |
| G-09 Maple | ✓ | ✓ | ✓ | ✓ | — |

See the receipt-level records in [RESULTS.md](RESULTS.md). Aave V4 still runs each accepted Core batch within one transaction; the table does not split it into multiple transactions to report an artificial success.

## Scope boundaries

- Website-derived 1inch swaps prove ordinary routing for the recorded amounts/assets, not project Affiliate fee or referrer settlement. A separate Affiliate assessment would require real fee-bearing calldata; it is not a prerequisite for this source upload.
- Aave V4 testing uses the official active Giver path; it does not claim that the project's Adapter itself received Aave governance activation.
- Base TestUSDC and protocol Mock results are not substitutes for these Ethereum mainnet-fork integrations.
- The F-01 reward-rounding failure remains an observed result. That earlier handoff did not change or rerun it. The October 21 source update includes the precision fix; see the current acceptance section above. E-05, E-07 and E-14 remain unchecked in this execution record; the failure is not reclassified as a pass. The incomplete X-03 matrix is likewise recorded, not an upload prerequisite.
