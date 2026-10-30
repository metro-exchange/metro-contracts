# Base On-Chain Functional Test Checklist

## October 30 audit remediation: future on-chain checks

- [ ] On a future version-2 Adapter, exercise V2/V3/1inch input caps and rejection of legacy data.
- [ ] Fund rewards after quoting; confirm all four Core swap/compound paths revert above the saved cap, preserve rewards and succeed with a complete fresh quote.

No deployment or on-chain transaction was performed for this source change. The historical deployment rows and hashes below remain unchanged.

## October 24 source acceptance: future on-chain checks

These items apply to a future deployment of the updated source. The existing QA addresses, transactions and permissions below remain historical deployment facts and have not been changed. Local tests do not mark an on-chain checkbox as passed.

| Check | Status |
| --- | --- |
| yTHOR pays 20/40/60/80/100% of converted principal at 4/7/10/13/16 hours, including adjacent-second boundaries | [ ] Not deployed |
| 100 yTHOR at a 0.5 test ratio creates 50 principal and pays 10 at the start or 50 at maturity; actual QA ratios remain configured | [ ] Not deployed |
| Fixed exclusion address matches the explicitly selected initial QA treasury; changing the forfeiture recipient leaves the exclusion unchanged | [ ] Not deployed |
| Treasury migration principal has zero weight; ordinary stakes, Contributor shares and exit-to-stake payouts retain rewards | [ ] Not deployed |
| Normal treasury exits, self-recipient forfeitures, queue cooldowns and no retroactive rewards | [ ] Not deployed |



## October 21 update: historical local-validation scope

The deployment records below describe existing QA contracts. This source update does not redeploy them or change their addresses or permissions. Use their matching deployed revision's ABI. New indexed interfaces are validated locally and require a later project-requested deployment for on-chain acceptance.

| Future on-chain check | Status |
| --- | --- |
| Repeat THOR/yTHOR migration; independent IDs/timestamps; out-of-order exits; stable IDs after exit | [ ] Not deployed |
| QA yTHOR 10/20/30/40/50% at 4/7/10/13/16 hours; boundary +/- 1 second; one complete settlement per position | [ ] Not deployed |
| Retained reward fractions through claims, transfers, exits and manual/automatic actions; payable rewards covered by funds | [ ] Not deployed |

Production now uses 120 days plus 1,460 days (126,144,000 seconds) to reach 50%; QA still uses a 43,200-second ramp. The historical N-04 failure remains in its original record; local precision regression results are recorded separately in [RESULTS.md](../ethereum-fork/RESULTS.md).

This is the production branch's **Base QA test template**, not its execution record. The Base QA branch holds the new project's actual deployment addresses and on-chain transaction hashes. Every box here remains unchecked because this production-time bytecode was not deployed to Base. Transactions against either the historical or new QA build do not prove this build passed. Chain ID for the QA environment is `8453`; no Ethereum fork transaction counts as a Base on-chain result.

An earlier short-duration Base run exercised the same broad feature groups. Its transactions are explicitly identified as **historical evidence**, not as results for this new deployment. The older run left yTHOR exit case N-04 unresolved because of a one-micro-USDC reward-rounding discrepancy. It must not be marked passed for the new deployment without a fresh assertion.

## Test environment

The new environment uses one owner-mintable TestUSDC throughout, owner-mintable TestTHOR, TestYTHOR, TestUSDT, TestWBTC, TestGHO, TestXAUT, TestExtraToken, and owner-controlled TestSyrupUSDC. METRO is the actual capped `MetroToken`, not an unlimited mock. The deployer initially owns all test tokens and the Mock protocol administration contracts; ownership is transferable to the project's management address after it is provided. Do not transfer any role to an unknown address. `MetroToken` minting is a separate role and must be transferred or revoked explicitly during handover.

TestUSDC is not accepted by production Aave or Maple USDC markets. Base therefore tests our **real project contracts** against interface-compatible Aave V3 Pool/aToken, Aave V4 Spoke/GiverPositionManager, and Maple Router/PermissionManager/Syrup mocks. Each mock must perform the relevant permission check, token debit, accounting, and protocol event emission; a success-only stub is insufficient. The Mock protocol events must decode with the corresponding protocol ABI for the tested path. Actual Ethereum protocol compatibility is tested separately on an Ethereum mainnet fork. Swaps on Base use the real Uniswap V2 Router and funded TestUSDC pairs. Test-token routes need not be supported by 1inch, so 1inch and Affiliate validation belong to the Ethereum fork, not this Base run.

The QA build shortens seven time constants. It also adds an Owner-only forfeiture-recipient setter and interprets a zero Escrow constructor start time as the deployment block. Production has an immutable recipient and requires an explicit start time, so the two builds do not have identical interfaces or bytecode. Other business ratios and permissions remain aligned. The Vault is deployed from the supplied source and tested only at the RewardDistributor integration boundary.

| Constant | Production | New Base QA |
| --- | ---: | ---: |
| `UNSTAKE_DELAY` | 72 hours | 1,800 seconds (30 minutes) |
| `THOR_EXIT_DELAY` | 30 days | 3,600 seconds (1 hour) |
| `THOR_EXIT_FULL_TIME` | 90 days | 10,800 seconds (3 hours) |
| `YTHOR_EXIT_DELAY` | 120 days | 14,400 seconds (4 hours) |
| `YTHOR_EXIT_RAMP` | 1,460 days (current source) | 43,200 seconds (12 hours) |
| `CONTRIBUTOR_CLIFF` | 180 days | 21,600 seconds (6 hours) |
| `CONTRIBUTOR_DURATION` | 912.5 days | 21,600 seconds (6 hours) |

The yTHOR ramp starts after its exit delay; the maximum yTHOR exit scenario takes roughly 16 hours, plus 30 minutes if a liquid withdrawal is requested. The existing single-position deployment needs separate wallets for early, middle and final exit points; the new source supports separate positions in one wallet. Record actual block timestamps rather than assuming exact wall-clock boundaries. Migration start/deadlines, conversion ratio, and initial weight are deployment parameters and must be recorded in `base-qa.json`.

## P. Deployment and preparation

| ID | New deployment | Check | New Base evidence |
| --- | --- | --- | --- |
| P-01 | [ ] | Deploy all test tokens and METRO; verify decimals, cap, owners, mint rights, and a single TestUSDC. | — |
| P-02 | [ ] | Deploy Core, Escrow, Distributor, Adapter implementation and ERC1967 Proxy; verify code, one-step Owner model, initial pause state, and bindings. | — |
| P-03 | [ ] | Deploy/configure Mock V3 Pool/aUSDC, V4 Spoke/Giver, Maple Router/PermissionManager/Syrup; verify owners, interfaces, permissions, and tested events. | — |
| P-04 | [ ] | Deploy a fresh Commission Vault for the new TestUSDC and Distributor, bind it in the Distributor, and verify the initial split is zero until the project configures it. | — |
| P-05 | [ ] | Create and fund real V2 pairs for METRO, five initial output assets, and ExtraToken against TestUSDC; verify Router/Factory and reserves. | — |
| P-06 | [ ] | Verify both QA source files use the seven agreed time constants and record source/artifact hashes. | — |
| P-07 | [ ] | Fund role/test wallets and verify Owner, Minter, Operator, Keeper, Contributor, Aave V4 Giver position-manager authorization, and Maple pool bitmaps 16/0/0 and separate Adapter deposit authorization. | — |
| P-08 | [ ] | Record all contract addresses, deploy/configuration hashes, start block, ABI, and on-chain readbacks in the delivery config. | — |

## O. Existing-function regression

| ID | New deployment | Required on-chain scenario | New Base evidence |
| --- | --- | --- | --- |
| O-01 | [ ] | METRO cap/minter, ERC-20 transfer/allowance, metadata, permit expiry/replay, and xMETRO token readbacks. | — |
| O-02 | [ ] | `stake` and `stakeAndEnableAutocompound`; approve METRO to xMETRO and verify principal and minted shares. | — |
| O-03 | [ ] | `requestUnstake` and `withdrawFree`; early rejection, maturity, multiple requests, queue cursor, and no double withdrawal. | — |
| O-04 | [ ] | Distributor Operator authorization, both distribution funding paths, reward deposit, plain claim, and balance/event reconciliation. | — |
| O-05 | [ ] | `claimable`, `claimableMany`, share readbacks, xMETRO transfer/allowance, and preservation of sender's historical pending. | — |
| O-06 | [ ] | Single-user legacy Auto-Compound through the funded real V2 pair, including opt-in/out, output minimum, deadline, and allowance cleanup. | — |
| O-07 | [ ] | Keeper-only `autocompoundBatch`: one swap, proportional user allocation, skipped candidates, rounding, and revoked Keeper. | — |
| O-08 | [ ] | Contributor allowlist, schedule creation, cliff/linear vesting, preview, scan/cursor, liquid and stake claims, and withdrawal queue. | — |
| O-09 | [ ] | Core/Escrow pause, unpause, rescue and role boundaries under the current one-step Owner implementation. | — |

## N. New and replaced-function testing

| ID | New deployment | Required on-chain scenario | New Base evidence |
| --- | --- | --- | --- |
| N-01 | [ ] | Immutable 100 million METRO global supply cap at mint boundaries. | — |
| N-02 | [ ] | THOR/yTHOR migration start, deadlines, conversion ratios, per-path caps, and mint/accounting results. | — |
| N-03 | [ ] | THOR position preview and early/mid/full exit, liquid vs stake, payout, forfeiture, and independent withdrawal queue. | — |
| N-04 | [ ] | yTHOR position preview and early/mid/full exit, liquid vs stake, payout, forfeiture, pending rewards, and queue; specifically check the historical one-micro-USDC discrepancy. | — |
| N-05 | [ ] | Adjustable yTHOR reward weight: accrued rewards remain unchanged; future weight applies only to eligible active yTHOR principal, excluding the fixed treasury's migration positions; accounting stays conserved. | — |
| N-06 | [ ] | `previewWithdrawableNow` includes the intended matured sources and excludes unrelated or queued amounts. | — |
| N-07 | [ ] | Distributor commission split to the new Vault and net reward to xMETRO; test zero/partial/full shortfall and both funding paths. | — |
| N-08 | [ ] | Adapter Proxy binding, initialization guard, router and strategy configuration, enable/disable, revisions, and adding ExtraToken. | — |
| N-09 | [ ] | Manual claim-and-swap to each of TestUSDT, TestWBTC, TestGHO, TestXAUT, and TestSyrupUSDC through real V2. | — |
| N-10 | [ ] | Auto-Swap batch for each initial output asset: one V2 swap and proportional delivery to opted-in users. | — |
| N-11 | [ ] | Mock Aave V3 manual and batch deposit, Pool/aToken binding, scaled-balance distribution, referral code, and failure rollback. | — |
| N-12 | [ ] | Mock Aave V4 Giver manual and batch deposit, user position-manager authorization, per-user Spoke shares, revocation, and rollback. | — |
| N-13 | [ ] | Mock Maple first authorized deposit and later deposit, batch share distribution, signature checks, and rollback. | — |
| N-14 | [ ] | Mutual exclusion of legacy compound and Auto strategies; preference invalidation after strategy/router/logic/proxy revisions. | — |
| N-15 | [ ] | UUPS implementation upgrade and complete Adapter Proxy replacement, including configuration, authorization, epoch, and old-adapter rejection. | — |
| N-16 | [ ] | Owner-only emergency USDC distribution while Core is paused; deduplication, zero pending, atomic failure, and unchanged principal. | — |
| N-17 | [ ] | Core endpoint replacement and authorization: old Escrow/Distributor lose authority, new ones work; Adapter direct calls are rejected. | — |
| N-18 | [ ] | Cross-source rewards (stake, THOR, yTHOR, Contributor, mixed, exited) through plain claim, manual, and opted-in automatic paths. | — |
| N-19 | [ ] | Batch edge cases and protocol failure rollback for pending, reward debt, token balances, shares, and transient allowances. | — |
| N-20 | [ ] | Decode Core/Adapter/Distributor/Mock protocol events and reconcile commission, net reward, actions, balances, and failure receipts. | — |

## Historical short-duration run (not the new deployment)

The previous Base run has on-chain transactions for P-01–P-08, O-01–O-09, and N-01–N-03/N-05–N-20. Its N-04 remains unpassed. Representative real transaction hashes include [token deployment](https://basescan.org/tx/0x9d5c3354bf78cc57b8250494698fbf883aae39b065977f6d624d0706d48f21d5), [stake](https://basescan.org/tx/0xa910fc880159923a9a0bb18010c8edab1d7fd2ffee8831366569a780eb4b2a8d), [V2 auto-swap](https://basescan.org/tx/0x438b82e4b66d0187ebbafdeaa5a1ba6571696189d495dffe5edfcfac527a9b63), [V3 deposit](https://basescan.org/tx/0xf35bf73bee02b19a49b0c1febf0fd9991b77b91d3953d9a2f7276093144d3305), [V4 deposit](https://basescan.org/tx/0xae0a78296419024a930e1a47631c1da1bf94cc107d3359959c7f633b22c18b89), [Maple deposit](https://basescan.org/tx/0xa1f756bbe63a6e213ca6bf01767a476044b768d670f3f85d86da911a86953f67), and [commission split](https://basescan.org/tx/0xfd847a3321c4e21b0665898b21b6b3b79fb6f3ec5484e4d97c4c7d841d41014e). Those hashes do **not** certify the new owner-controlled mocks or the longer-time QA build.

Source references: [`src/`](../../../src), [`test/mocks/`](../../../test/mocks), [`test/core/`](../../../test/core), and the [Ethereum fork checklist](../ethereum-fork/CHECKLIST.md). Base Mock coverage proves integration behavior against the mock, not production Aave/Maple availability.

## Maple pool configuration

The Base QA Maple pool bitmaps are `P:deposit=16`, `P:transfer=0`, and `P:transferFrom=0`. This matches the Adapter's transferability check. Receiving TestSyrupUSDC no longer requires setting a bitmap of 16 for each recipient wallet. Deposit authorization for the actual Adapter proxy is a separate requirement and remains in effect. The pool bitmap correction was previously applied in transaction `0x21604b865a2824333c39dc471a856be5f750531c9f623f615489b9e1b9eb236c`; the October 20 readback at Base block 52,860,584 confirmed `16/0/0`. The QA deployment script now uses those same values. This source update performs no chain configuration transactions.
