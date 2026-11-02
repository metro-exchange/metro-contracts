# Upstream Protocol Reference for Base QA Mocks

This archive pins the external-protocol interfaces and verified source used to compare the Base QA mocks. Its reference point is Ethereum block `26,077,998`. Proxy implementations were identified using code and the EIP-1967 implementation slot at that block, rather than assuming an explorer's latest displayed implementation was active then.

`manifest.json` records addresses, implementation addresses, block hash, archived-source SHA-256, runtime Keccak-256 and source links. Each contract directory retains the original `verified-source.json`, `sources.json` and `abi.json`. Archived external source is not compiled into the project contracts. The archive is reference material, not a claim that every external protocol was rebuilt locally or that Base Mock behavior is identical in every untested subsystem.

| Path | Referenced components | Events on the tested path |
| --- | --- | --- |
| Aave V3 | Pool implementation, aUSDC implementation and dependencies | Pool `Supply`; aToken `Mint`, `BalanceTransfer` and `Transfer`; relevant Pool reserve events |
| Aave V4 | Official Giver and Spoke implementations | `RegisterSpoke`, `UpdatePositionManager`, `SetUserPositionManager`, Spoke `Supply`, Giver `SupplyOnBehalfOf` |
| Maple | SyrupRouter, syrupUSDC Pool, PoolManager and PermissionManager implementations | PermissionManager `LenderBitmapsSet`; Pool `Deposit` and `Transfer`; Router `DepositData` |

The Base V4 QA call chain is `Adapter → Mock Giver → Mock Spoke`: the user authorizes the Mock Giver in the Mock Spoke. The project Adapter Proxy is not independently activated by Aave governance in this model. On Ethereum, a separate fork test uses the official active Giver/Spoke pair.

## Compatibility boundary

For the project-integrated calls, compare function selectors, argument types and ordering, tuple layouts, return values, mutability, and event signature, field names/types/order, `indexed` flags, emission point and semantics. The appropriate Mock component emits each event; a Router must not fabricate events belonging to the Pool or PermissionManager. Addresses, balances, timestamps and test rates are naturally different in Base QA.

The mocks intentionally omit unrelated lending, liquidation and production-governance internals. The tested V3 path debits TestUSDC, mints/transfers scaled aToken balances and emits corresponding Pool/aToken events. The V4 path checks user position-manager permission and accounts shares per user through Giver and Spoke. The Maple path checks a test signature and FUNCTION_LEVEL bitmaps, performs a Pool deposit and distributes Syrup shares. Mock PoolManager/Hub internals are simplified and are not evidence of their production behavior.

`mint`, `donateScaled`, `configureMock`, `setBehavior`, `setIndex` and similar methods are explicitly QA controls, not claimed production protocol functions. The new QA versions restrict administrative controls to each Mock's transferable Owner; user-owned position-manager choices and authorized Maple Router operations retain their protocol roles. Never deposit assets of real value into these mocks.

Run `FOUNDRY_PROFILE=core forge test --match-contract BaseQAProtocolMocksTest -vv` to verify Core → Adapter → Mock deposits, batches, events, balances, administration and rollback locally. Base on-chain acceptance still requires actual Base receipts and state readbacks in the [Base checklist](../../../../integration/testing/base/BASE_ONCHAIN_FUNCTIONAL_TEST_CHECKLIST.md). Ethereum fork acceptance requires its separate [checklist](../../../../integration/testing/ethereum-fork/CHECKLIST.md).
