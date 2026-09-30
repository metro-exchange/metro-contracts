# Base On-Chain Functional Test Checklist

This is the handoff checklist for the **new project-facing Base QA deployment**. A box is checked only after the corresponding action and readback have passed against this new deployment; transactions against an older QA deployment do not count. Public addresses and settings are in [`base-qa.json`](../../config/base-qa.json), and the new deployment transaction hashes are listed below in this checklist. Chain ID must be `8453`. No Ethereum fork transaction counts as a Base on-chain result.

The O/N functional scenarios are provided for the receiving project to execute after handover. Their unchecked status is not a prerequisite for uploading the source or the 87 deployment transactions, and it must not be interpreted as a successful functional test.

An earlier short-duration Base run exercised the same broad feature groups. Its transactions are explicitly identified as **historical evidence**, not as results for this new deployment. The older run left yTHOR exit case N-04 unresolved because of a one-micro-USDC reward-rounding discrepancy. It must not be marked passed for the new deployment without a fresh assertion.

## Test environment

The new environment uses one owner-mintable TestUSDC throughout, owner-mintable TestTHOR, TestYTHOR, TestUSDT, TestWBTC, TestGHO, TestXAUT, TestExtraToken, and owner-controlled TestSyrupUSDC. METRO is the actual capped `MetroToken`, not an unlimited mock. The deployer initially owns all test tokens and the Mock protocol administration contracts; ownership is transferable to the project's management address after it is provided. Do not transfer any role to an unknown address. `MetroToken` minting is a separate role and must be transferred or revoked explicitly during handover.

TestUSDC is not accepted by production Aave or Maple USDC markets. Base therefore tests our **real project contracts** against interface-compatible Aave V3 Pool/aToken, Aave V4 Spoke/GiverPositionManager, and Maple Router/PermissionManager/Syrup mocks. Each mock must perform the relevant permission check, token debit, accounting, and protocol event emission; a success-only stub is insufficient. The Mock protocol events must decode with the corresponding protocol ABI for the tested path. Actual Ethereum protocol compatibility is tested separately on an Ethereum mainnet fork. Swaps on Base use the real Uniswap V2 Router and funded TestUSDC pairs. Test-token routes need not be supported by 1inch, so 1inch and Affiliate validation belong to the Ethereum fork, not this Base run.

Seven waiting-period constants are shortened. QA also permits an Owner-only change of the forfeiture recipient and an Escrow constructor start value of zero to use the deployment block; production keeps its immutable recipient and explicit future start time. Other business ratios and permissions remain aligned. The Vault is deployed from the supplied source and tested only at the RewardDistributor integration boundary.

| Constant | Production | New Base QA |
| --- | ---: | ---: |
| `UNSTAKE_DELAY` | 72 hours | 1,800 seconds (30 minutes) |
| `THOR_EXIT_DELAY` | 30 days | 3,600 seconds (1 hour) |
| `THOR_EXIT_FULL_TIME` | 90 days | 10,800 seconds (3 hours) |
| `YTHOR_EXIT_DELAY` | 120 days | 14,400 seconds (4 hours) |
| `YTHOR_EXIT_RAMP` | 1,825 days | 43,200 seconds (12 hours) |
| `CONTRIBUTOR_CLIFF` | 180 days | 21,600 seconds (6 hours) |
| `CONTRIBUTOR_DURATION` | 912.5 days | 21,600 seconds (6 hours) |

The yTHOR ramp starts after its exit delay; the maximum yTHOR exit scenario takes roughly 16 hours, plus 30 minutes if a liquid withdrawal is requested. Use separate wallets for early, middle, and final exit points. Record actual block timestamps rather than assuming exact wall-clock boundaries. The QA deployment starts migration in the Escrow deployment block; both THOR and yTHOR deadlines are exactly 30 days later, and both conversion ratios are `0.3928569546`. Record the actual start time, deadlines, conversion ratios, recipient, and initial weight in `base-qa.json`.

## P. Deployment and preparation

| ID | New deployment | Check | New Base evidence |
| --- | --- | --- | --- |
| P-01 | [x] | Deploy all test tokens and METRO; verify decimals, cap, owners, mint rights, and a single TestUSDC. | [New addresses](../../config/base-qa.json); deployment, minter and initial mint hashes are in [the transaction table](#base-qa-deployment-transaction-hashes). `METRO.cap() = 100,000,000e18`; Core and deployer are enabled minters. |
| P-02 | [x] | Deploy Core, Escrow, Distributor, Adapter implementation and ERC1967 Proxy; verify code, one-step Owner model, initial pause state, and bindings. | Deployment and binding hashes are in [the transaction table](#base-qa-deployment-transaction-hashes). Core starts unpaused; Owner is the deployer pending handover. |
| P-03 | [ ] | Deploy/configure Mock V3 Pool/aUSDC, V4 Spoke/Giver, Maple Router/PermissionManager/Syrup; verify owners, interfaces, permissions, and tested events. | — |
| P-04 | [x] | Deploy a fresh Commission Vault for the new TestUSDC and Distributor, bind it in the Distributor, and verify the initial split is zero until the project configures it. | Vault deployment and `distributor-vault` hashes are in [the transaction table](#base-qa-deployment-transaction-hashes); on-chain `maxCommissionSplitBps = 0`. |
| P-05 | [x] | Create and fund real V2 pairs for METRO, five initial output assets, and ExtraToken against TestUSDC; verify Router/Factory and reserves. | [Seven pair addresses](../../config/base-qa.json); all pair-creation, approval and liquidity hashes are in [the transaction table](#base-qa-deployment-transaction-hashes). Each pair received 1,000 TestUSDC and 1,000 output-token units. |
| P-06 | [x] | Verify both QA source files use the seven agreed time constants and record source/artifact hashes. | The seven values are listed above; full SHA-256 hashes appear in [the build-hash table](#base-qa-build-hashes). |
| P-07 | [ ] | Fund role/test wallets and verify Owner, Minter, Operator, Keeper, Contributor, Aave V4 Giver position-manager authorization, and Maple recipient bitmaps for actual testers. | — |
| P-08 | [x] | Record all contract addresses, deploy/configuration hashes, start block, ABI, and key on-chain readbacks in the delivery materials. | [Delivery config](../../config/base-qa.json), [compiled ABI directory](../../abi), [readback summary](#base-qa-deployment-readbacks), and [87 transaction hashes](#base-qa-deployment-transaction-hashes). All 87 receipts were rechecked against canonical Base blocks. |

### Base QA deployment readbacks

| Item | On-chain result |
| --- | --- |
| Chain and Escrow start | Base mainnet `8453`; block `51,977,102`; `2026-09-30 04:45:51 UTC` |
| THOR / yTHOR migration | Both ratios `0.3928569546`; both deadlines `2026-10-30 04:45:51 UTC` (30 days after start) |
| METRO | Cap `100,000,000e18`; Core and deployer enabled as minters |
| xMETRO | Initially unpaused; Owner `0x24aC3A0ac2c6451C9fc947FB7BC7E77261120C76`; Adapter, Distributor and Escrow bound to the addresses in `base-qa.json` |
| Commission | New Vault bound to the new Distributor; initial `maxCommissionSplitBps = 0` |
| V2 liquidity | Seven new TestUSDC pairs, each seeded with 1,000 TestUSDC and 1,000 output-token units |

### Base QA build hashes

These SHA-256 hashes identify the source and compiled artifacts used for this deployment; they are not transaction hashes.

| File or artifact | SHA-256 |
| --- | --- |
| `src/xMETRO.sol` | `1d43115c96236c5e3fec88b33c89037ef30193bc240ec73e80d801372ddf5b7a` |
| `src/XMetroCoreLogic.sol` | `2c5f831b33a7b974135b4e545313b39fe84b65870c2f15eff7d4c3d6f1e049cd` |
| `src/ThorMigrationEscrow.sol` | `7ab703ce86dfe294f70c136fcc65140065d63f8c08cf17c1d91ba4aa078bb2e0` |
| xMETRO artifact | `41f75e2e3e51dcb527866368585626d0505c033fa84a9913aa82038ef033a628` |
| Adapter artifact | `eb996a6a379ba38e16ce5a2a7695e31cf0fe615f1dab52d2a6743577cedfbc1c` |
| Escrow artifact | `b346ff6b4bf68381229720d9c500ffb01c38161cddfb2d0307ef408ffb1910db` |

### Base QA deployment transaction hashes

The following 87 transactions belong to the fresh Base QA deployment (deployer nonces 246–332). Each was rechecked with a successful receipt and a nonzero canonical block hash. These setup transactions do not mark the functional scenarios in sections O and N as passed.

<details>
<summary>Show all 87 BaseScan transaction links</summary>

| Stage | Nonce | Operation | Base transaction |
| --- | ---: | --- | --- |
| Tokens | 246 | `TestUSDC` | [`0x30e534469c978fab37d0b83916cd0d0752c8e9587ca3bd41e6422e97f16d8625`](https://basescan.org/tx/0x30e534469c978fab37d0b83916cd0d0752c8e9587ca3bd41e6422e97f16d8625) |
| Tokens | 247 | `TestTHOR` | [`0xc55968106abdd13f79d95b6e5ff73ce477d18a6d2ca9bbe9a2ac2387eca4501f`](https://basescan.org/tx/0xc55968106abdd13f79d95b6e5ff73ce477d18a6d2ca9bbe9a2ac2387eca4501f) |
| Tokens | 248 | `TestYTHOR` | [`0xbc5146fd0f84888a646ba2affb85e9ee55a565d7b1a9dd40390187bdb975203a`](https://basescan.org/tx/0xbc5146fd0f84888a646ba2affb85e9ee55a565d7b1a9dd40390187bdb975203a) |
| Tokens | 249 | `TestUSDT` | [`0xa3f740922f23e859f6d59a42a74c7eabdf9ff1a88e86f59088c90e2524162075`](https://basescan.org/tx/0xa3f740922f23e859f6d59a42a74c7eabdf9ff1a88e86f59088c90e2524162075) |
| Tokens | 250 | `TestWBTC` | [`0x5955dd66372968df9f08e34063cf4fef38835dace111766d4a927f463176817c`](https://basescan.org/tx/0x5955dd66372968df9f08e34063cf4fef38835dace111766d4a927f463176817c) |
| Tokens | 251 | `TestGHO` | [`0x21eca52893fc0f67a8e08010eb1b1a14f89e81491d4a10b305e388cbca9038de`](https://basescan.org/tx/0x21eca52893fc0f67a8e08010eb1b1a14f89e81491d4a10b305e388cbca9038de) |
| Tokens | 252 | `TestXAUT` | [`0x3b98b2e4af74de91aef7826cdc875360f7fd91b9f554278990d43821748f2464`](https://basescan.org/tx/0x3b98b2e4af74de91aef7826cdc875360f7fd91b9f554278990d43821748f2464) |
| Tokens | 253 | `TestExtraToken` | [`0x67fa48dd296a0cdd38b3530ebd9e0a278bd8052c522df166b04cb16ec565e631`](https://basescan.org/tx/0x67fa48dd296a0cdd38b3530ebd9e0a278bd8052c522df166b04cb16ec565e631) |
| Tokens | 254 | `TestSyrupUSDC` | [`0x050b6e241e8bbaf727865baf2f0bb3db7fdb378727e92fd822ecef59fb0ffa0b`](https://basescan.org/tx/0x050b6e241e8bbaf727865baf2f0bb3db7fdb378727e92fd822ecef59fb0ffa0b) |
| Mocks | 255 | `MockAaveV3Pool` | [`0x11b638128704d6750fb326c35e0480efa72b1ac52af226d27fa590897a3fdc32`](https://basescan.org/tx/0x11b638128704d6750fb326c35e0480efa72b1ac52af226d27fa590897a3fdc32) |
| Mocks | 256 | `MockAaveV4Spoke` | [`0x8bff012c6af934f508cb073ce561e55dbb8fa768d20888ec23604865d5158b95`](https://basescan.org/tx/0x8bff012c6af934f508cb073ce561e55dbb8fa768d20888ec23604865d5158b95) |
| Mocks | 257 | `MockAaveV4Giver` | [`0xc00440c4a50d97816da4f31caee1796d74dfc4cd5a13323c91735c7f2ddf248b`](https://basescan.org/tx/0xc00440c4a50d97816da4f31caee1796d74dfc4cd5a13323c91735c7f2ddf248b) |
| Mocks | 258 | `MockPoolPermissionManager` | [`0x3685f8befb6088c255ce8b4b8e30acbcab820b065f5f272bdb70343d3c17d3d5`](https://basescan.org/tx/0x3685f8befb6088c255ce8b4b8e30acbcab820b065f5f272bdb70343d3c17d3d5) |
| Mocks | 259 | `MockSyrupRouter` | [`0x8fd28c873116d83679208f2a3f2d60a684b5b3a717c050d26a7225ea4cbb430d`](https://basescan.org/tx/0x8fd28c873116d83679208f2a3f2d60a684b5b3a717c050d26a7225ea4cbb430d) |
| Mocks | 260 | `maple-bind-syrup` | [`0xf93e117f7fb1fcc7e22f8cde4f1f04ac461c4ab639ee398791ad00cfca7df620`](https://basescan.org/tx/0xf93e117f7fb1fcc7e22f8cde4f1f04ac461c4ab639ee398791ad00cfca7df620) |
| Mocks | 261 | `maple-grant-signer` | [`0x6ebea239e50cff106f15b5f97017da882315ef72e68311f10ffa8199acf5b8c3`](https://basescan.org/tx/0x6ebea239e50cff106f15b5f97017da882315ef72e68311f10ffa8199acf5b8c3) |
| Mocks | 262 | `maple-grant-deployer` | [`0xd2bac277327b20093519aefe88c6fbb7fab48320f84e5ca14ab19893f1347493`](https://basescan.org/tx/0xd2bac277327b20093519aefe88c6fbb7fab48320f84e5ca14ab19893f1347493) |
| Mocks | 263 | `maple-grant-router` | [`0x242a5e2d9e0648b6e9f3cfe43b3aa828fa1f19f2e83c277aa48b10bf21f2ecb3`](https://basescan.org/tx/0x242a5e2d9e0648b6e9f3cfe43b3aa828fa1f19f2e83c277aa48b10bf21f2ecb3) |
| Core | 264 | `METRO` | [`0x608d6a2aa664c1a7c1030f1d757d664f6a1610e65f309588dea7ef602714f64c`](https://basescan.org/tx/0x608d6a2aa664c1a7c1030f1d757d664f6a1610e65f309588dea7ef602714f64c) |
| Core | 265 | `Core` | [`0x6d6807fe2fa5d66f05a7bc99db2f084ee66988cd429bc6f76159f611e9fabf6a`](https://basescan.org/tx/0x6d6807fe2fa5d66f05a7bc99db2f084ee66988cd429bc6f76159f611e9fabf6a) |
| Core | 266 | `AdapterImplementation` | [`0xd46bd7df7b0ff0d8809d6797884c449a3ddf7358c0d1546931175b309beced2f`](https://basescan.org/tx/0xd46bd7df7b0ff0d8809d6797884c449a3ddf7358c0d1546931175b309beced2f) |
| Core | 267 | `AdapterProxy` | [`0xe7b7ed8fca4e5326d71da1094d07d4f335344fe49d7d06e0cfe1c4ae990a783c`](https://basescan.org/tx/0xe7b7ed8fca4e5326d71da1094d07d4f335344fe49d7d06e0cfe1c4ae990a783c) |
| Core | 268 | `Distributor` | [`0xeb3068493b737e21a0fc75ec378837d3e3db7e8836fdb65857648f91d3efadf8`](https://basescan.org/tx/0xeb3068493b737e21a0fc75ec378837d3e3db7e8836fdb65857648f91d3efadf8) |
| Core | 269 | `Escrow` | [`0xb142b7ed5bb6056bc8a0d08ef51919a24695a023c4863e5ac1852d9b54a0613c`](https://basescan.org/tx/0xb142b7ed5bb6056bc8a0d08ef51919a24695a023c4863e5ac1852d9b54a0613c) |
| Core | 270 | `Vault` | [`0x0d3720a49538a1046f2646eea49859422b7e460d718fe1ef08580bab2a7408f3`](https://basescan.org/tx/0x0d3720a49538a1046f2646eea49859422b7e460d718fe1ef08580bab2a7408f3) |
| Config | 271 | `metro-minter-core` | [`0x592036c534969db73a2f17c0bc86363e5154b79862be16a2febbee3225c3d38c`](https://basescan.org/tx/0x592036c534969db73a2f17c0bc86363e5154b79862be16a2febbee3225c3d38c) |
| Config | 272 | `metro-minter-deployer` | [`0x74c97d5c4aae023835fe20521f78458ecd929c0d7d3ba6c463c8110fb6e40114`](https://basescan.org/tx/0x74c97d5c4aae023835fe20521f78458ecd929c0d7d3ba6c463c8110fb6e40114) |
| Config | 273 | `core-bind-adapter` | [`0xc6c5b86c93837c28f3c30d78eafa9caf732aa2441935a498a342c63ee3b82b12`](https://basescan.org/tx/0xc6c5b86c93837c28f3c30d78eafa9caf732aa2441935a498a342c63ee3b82b12) |
| Config | 274 | `adapter-routers` | [`0x249c6882a3ed5182d84879db864f844e79ec36d81a4bab38607dea13751236de`](https://basescan.org/tx/0x249c6882a3ed5182d84879db864f844e79ec36d81a4bab38607dea13751236de) |
| Config | 275 | `adapter-swap-metro` | [`0x10059e24cf92084e9eaed954235b4751ba229dbf01665c5684081554d5a1268e`](https://basescan.org/tx/0x10059e24cf92084e9eaed954235b4751ba229dbf01665c5684081554d5a1268e) |
| Config | 276 | `adapter-swap-TestUSDT` | [`0x0e9cc97dad4d0a90d3ab7128e32e8c2d0526db1b8260edee9e447eb181014ddd`](https://basescan.org/tx/0x0e9cc97dad4d0a90d3ab7128e32e8c2d0526db1b8260edee9e447eb181014ddd) |
| Config | 277 | `adapter-swap-TestWBTC` | [`0xab7b300c102a510653ed82f358182bede9a8d831e7718c89a7ef6d359210d625`](https://basescan.org/tx/0xab7b300c102a510653ed82f358182bede9a8d831e7718c89a7ef6d359210d625) |
| Config | 278 | `adapter-swap-TestGHO` | [`0x6444e4a2050849da343e16bd0481ff1a35a05f791f55068230e8a864039d2d96`](https://basescan.org/tx/0x6444e4a2050849da343e16bd0481ff1a35a05f791f55068230e8a864039d2d96) |
| Config | 279 | `adapter-swap-TestXAUT` | [`0x9c10c0868094ba105a6e83b4e854c9c6123f1cebfd02bbb37dadf16bbf50a129`](https://basescan.org/tx/0x9c10c0868094ba105a6e83b4e854c9c6123f1cebfd02bbb37dadf16bbf50a129) |
| Config | 280 | `adapter-swap-TestSyrupUSDC` | [`0x8f22333fc5ff5312a27a43ac43b51bc7e751f5f7a2af166c120fb2ac76dd7788`](https://basescan.org/tx/0x8f22333fc5ff5312a27a43ac43b51bc7e751f5f7a2af166c120fb2ac76dd7788) |
| Config | 281 | `adapter-aave-v3` | [`0x770153e0c8e0f63f288541408d69e22321f471016c708e2f7707ca7673c1bbbe`](https://basescan.org/tx/0x770153e0c8e0f63f288541408d69e22321f471016c708e2f7707ca7673c1bbbe) |
| Config | 282 | `v4-activate-giver` | [`0x92ea7198bee898f8c12442e03d774055576488416675cbdc36886d322805c4f0`](https://basescan.org/tx/0x92ea7198bee898f8c12442e03d774055576488416675cbdc36886d322805c4f0) |
| Config | 283 | `adapter-aave-v4` | [`0x5d44f635cb9386158be90e31182d8cd05581674e450a830701b422f78358399a`](https://basescan.org/tx/0x5d44f635cb9386158be90e31182d8cd05581674e450a830701b422f78358399a) |
| Config | 284 | `adapter-maple` | [`0x6ac43205cd66ff6ca60bc5f5c9557cae92e193e0a277b5a484ebfdf59a93b67c`](https://basescan.org/tx/0x6ac43205cd66ff6ca60bc5f5c9557cae92e193e0a277b5a484ebfdf59a93b67c) |
| Config | 285 | `maple-bitmap-deposit` | [`0x46a8927309db29ec970b268499dd2bc737b64e9591eb8eb6ce8562549ce82302`](https://basescan.org/tx/0x46a8927309db29ec970b268499dd2bc737b64e9591eb8eb6ce8562549ce82302) |
| Config | 286 | `maple-bitmap-transfer` | [`0xba66be8c4a90e92ad86d16d65448553182873e54ced146cd65b21187b8175366`](https://basescan.org/tx/0xba66be8c4a90e92ad86d16d65448553182873e54ced146cd65b21187b8175366) |
| Config | 287 | `maple-bitmap-transferFrom` | [`0x225a5c5b511fd1ed7042eacd9c2caf35077809da1a25e78b29e82146ce3bdd5d`](https://basescan.org/tx/0x225a5c5b511fd1ed7042eacd9c2caf35077809da1a25e78b29e82146ce3bdd5d) |
| Config | 288 | `maple-lender-bitmap` | [`0xa1ebc713cd1e0426471597a8e2aeb96db1dce24a7cbb951b8d0fbf9169d86e37`](https://basescan.org/tx/0xa1ebc713cd1e0426471597a8e2aeb96db1dce24a7cbb951b8d0fbf9169d86e37) |
| Config | 289 | `maple-user-bitmaps` | [`0xe4504e7da10d73d2bc0becad55aeffe3849f035f972b99032a57704d32ff14cb`](https://basescan.org/tx/0xe4504e7da10d73d2bc0becad55aeffe3849f035f972b99032a57704d32ff14cb) |
| Config | 290 | `distributor-operator` | [`0xe278a444203c6c7d42c6bc02f05fc973fc0ed6fa1b84c7863fbe724c9886d638`](https://basescan.org/tx/0xe278a444203c6c7d42c6bc02f05fc973fc0ed6fa1b84c7863fbe724c9886d638) |
| Config | 291 | `distributor-vault` | [`0x867484a1e7f2700d87a1f1356e8d9d6acb1155007dc42d1b662f7ff06a1b0a9c`](https://basescan.org/tx/0x867484a1e7f2700d87a1f1356e8d9d6acb1155007dc42d1b662f7ff06a1b0a9c) |
| Config | 292 | `core-bind-distributor` | [`0x25a19c4d26577f267e855c3392f0d30bca0a44117ed80cef24022bba3786014e`](https://basescan.org/tx/0x25a19c4d26577f267e855c3392f0d30bca0a44117ed80cef24022bba3786014e) |
| Config | 293 | `core-keeper` | [`0x39cd41e005c400adf6f2fd18f5b27b06123c8257b95f21d0bab4f8215ccadbe8`](https://basescan.org/tx/0x39cd41e005c400adf6f2fd18f5b27b06123c8257b95f21d0bab4f8215ccadbe8) |
| Config | 294 | `core-contributor` | [`0x425e0f58e644f909283b470702327d2b14a4ef8f5cd7bea919101559f217ac56`](https://basescan.org/tx/0x425e0f58e644f909283b470702327d2b14a4ef8f5cd7bea919101559f217ac56) |
| Config | 295 | `escrow-caps` | [`0x7e5ef77133f7c6e426e8c5ba031ab8012fe09ca0b88a701e05ae556663ca5961`](https://basescan.org/tx/0x7e5ef77133f7c6e426e8c5ba031ab8012fe09ca0b88a701e05ae556663ca5961) |
| Config | 296 | `escrow-ratios` | [`0x34011ba8095d202e176679316077b4cbae84ba66b87980c8eb2aa8eee9f2b514`](https://basescan.org/tx/0x34011ba8095d202e176679316077b4cbae84ba66b87980c8eb2aa8eee9f2b514) |
| Config | 297 | `escrow-deadlines` | [`0x94a659d50300768b5e52a30c5d355487f82932098afe82c283ed7b6b2c776e1d`](https://basescan.org/tx/0x94a659d50300768b5e52a30c5d355487f82932098afe82c283ed7b6b2c776e1d) |
| Config | 298 | `core-bind-escrow` | [`0x4b9deb222c63f20b3f79e116d073de204a05ec7188ff14555dc84c6f88b78655`](https://basescan.org/tx/0x4b9deb222c63f20b3f79e116d073de204a05ec7188ff14555dc84c6f88b78655) |
| Seed | 299 | `mint-TestUSDC` | [`0x0760f58c6cc2e0d67a06cf71c13d8c0d7b8097beb67d830aa9867c7aa8aa3a80`](https://basescan.org/tx/0x0760f58c6cc2e0d67a06cf71c13d8c0d7b8097beb67d830aa9867c7aa8aa3a80) |
| Seed | 300 | `mint-TestTHOR` | [`0xb0e9d4dec0ba32f4e266cd6ffa06fc0fae86f1ec6bd1c365798e4525f1717e57`](https://basescan.org/tx/0xb0e9d4dec0ba32f4e266cd6ffa06fc0fae86f1ec6bd1c365798e4525f1717e57) |
| Seed | 301 | `mint-TestYTHOR` | [`0x6e85861900571fa8085244ad1c64d5ecd03daeb432204770977cee095f7a19aa`](https://basescan.org/tx/0x6e85861900571fa8085244ad1c64d5ecd03daeb432204770977cee095f7a19aa) |
| Seed | 302 | `mint-TestUSDT` | [`0xcc9faf83af0ca22ceca51087972fe7ac4f6585350e9f9e2beba4e610c3321235`](https://basescan.org/tx/0xcc9faf83af0ca22ceca51087972fe7ac4f6585350e9f9e2beba4e610c3321235) |
| Seed | 303 | `mint-TestWBTC` | [`0x58182d6f5c037f8b3aaa2a8bbbe886abc2021a9cd4f050f3cb2447ab50429362`](https://basescan.org/tx/0x58182d6f5c037f8b3aaa2a8bbbe886abc2021a9cd4f050f3cb2447ab50429362) |
| Seed | 304 | `mint-TestGHO` | [`0x829a6986e93774de7e9546eb7c670c56d8519f16e70a76ba44f1ae7c7fd9e1d4`](https://basescan.org/tx/0x829a6986e93774de7e9546eb7c670c56d8519f16e70a76ba44f1ae7c7fd9e1d4) |
| Seed | 305 | `mint-TestXAUT` | [`0x176581b181f7999baeb32a7cd8c11929192c0060c780b8daff8440e1ba5bc8e4`](https://basescan.org/tx/0x176581b181f7999baeb32a7cd8c11929192c0060c780b8daff8440e1ba5bc8e4) |
| Seed | 306 | `mint-TestExtraToken` | [`0x5124fdf80bb87acccfbc385dc82f3ba962204db2e2c95271c3d519407a491228`](https://basescan.org/tx/0x5124fdf80bb87acccfbc385dc82f3ba962204db2e2c95271c3d519407a491228) |
| Seed | 307 | `mint-TestSyrupUSDC` | [`0x7cbf38d0b5171cdd31fa8f32fb414e6808629c45f95e6e2fed2a979b5eb538f9`](https://basescan.org/tx/0x7cbf38d0b5171cdd31fa8f32fb414e6808629c45f95e6e2fed2a979b5eb538f9) |
| Seed | 308 | `mint-METRO` | [`0xf2ec3f1fbf3b7162ef14af2dd3855e100da8fbee5e5e6a58f27ba81a803d3b67`](https://basescan.org/tx/0xf2ec3f1fbf3b7162ef14af2dd3855e100da8fbee5e5e6a58f27ba81a803d3b67) |
| V2 pools | 309 | `v2-create-METRO` | [`0xd11a887dae8922fda66f27957a4457a0cfd566552c7a55ed036ad07edc315442`](https://basescan.org/tx/0xd11a887dae8922fda66f27957a4457a0cfd566552c7a55ed036ad07edc315442) |
| V2 pools | 310 | `v2-create-TestUSDT` | [`0xf35567c4fb93578d5bd08aef7402e940564cef3c740a88b05691822fa9da120f`](https://basescan.org/tx/0xf35567c4fb93578d5bd08aef7402e940564cef3c740a88b05691822fa9da120f) |
| V2 pools | 311 | `v2-create-TestWBTC` | [`0x1d52dbe676046a00e8ea04261bc9f467f133ffca0c51b30e74d08ab1b34217b6`](https://basescan.org/tx/0x1d52dbe676046a00e8ea04261bc9f467f133ffca0c51b30e74d08ab1b34217b6) |
| V2 pools | 312 | `v2-create-TestGHO` | [`0xbfcc5fd23f7ebb52bab3d2e90193627b6c0d0e97b0ce9f701433b5dcdd22f9c3`](https://basescan.org/tx/0xbfcc5fd23f7ebb52bab3d2e90193627b6c0d0e97b0ce9f701433b5dcdd22f9c3) |
| V2 pools | 313 | `v2-create-TestXAUT` | [`0x79453812ccdf77f45f60c06b6ffc4314c7fb7f4ac54ec11cc3e530d92955c441`](https://basescan.org/tx/0x79453812ccdf77f45f60c06b6ffc4314c7fb7f4ac54ec11cc3e530d92955c441) |
| V2 pools | 314 | `v2-create-TestSyrupUSDC` | [`0x40d9f1e23b584974868acfd86987f1d9bdffde0914442ba1e19c13798038a730`](https://basescan.org/tx/0x40d9f1e23b584974868acfd86987f1d9bdffde0914442ba1e19c13798038a730) |
| V2 pools | 315 | `v2-create-TestExtraToken` | [`0x84a587e8db992bfad1a9cb309d36a4810eb403ec1728188d7a834a43b8d085e5`](https://basescan.org/tx/0x84a587e8db992bfad1a9cb309d36a4810eb403ec1728188d7a834a43b8d085e5) |
| V2 pools | 316 | `v2-syrup-permission-deployer` | [`0x07dc7921c5cec823881a0ba6f64923400ba5ca35c46fc3edc52f1681d8cb5589`](https://basescan.org/tx/0x07dc7921c5cec823881a0ba6f64923400ba5ca35c46fc3edc52f1681d8cb5589) |
| V2 pools | 317 | `v2-syrup-permission-pair` | [`0xa9fa1667eb5034fa4af69056c07eb3ffbf9e9b2a9a3ff6348556244fe9eba258`](https://basescan.org/tx/0xa9fa1667eb5034fa4af69056c07eb3ffbf9e9b2a9a3ff6348556244fe9eba258) |
| V2 pools | 318 | `v2-approve-usdc` | [`0x5db41a29a0f3a4c8297079aa3b40b0bd8e64a33cbcb91c5338fffc8e301ef3b7`](https://basescan.org/tx/0x5db41a29a0f3a4c8297079aa3b40b0bd8e64a33cbcb91c5338fffc8e301ef3b7) |
| V2 pools | 319 | `v2-approve-METRO` | [`0x1e17c9b1641856eac72583f470aa6f8925bc22dd2a01f08c807e5fa7e3b80f06`](https://basescan.org/tx/0x1e17c9b1641856eac72583f470aa6f8925bc22dd2a01f08c807e5fa7e3b80f06) |
| V2 pools | 320 | `v2-liquidity-METRO` | [`0x74b31cc918fa6f8e115caf4f1b8b903c33e2762975d5107c71709170d800aea3`](https://basescan.org/tx/0x74b31cc918fa6f8e115caf4f1b8b903c33e2762975d5107c71709170d800aea3) |
| V2 pools | 321 | `v2-approve-TestUSDT` | [`0xc90cca34fb3cb2c8bca85e33259defa04ce1039ccfdb695edfebcf40a0603a00`](https://basescan.org/tx/0xc90cca34fb3cb2c8bca85e33259defa04ce1039ccfdb695edfebcf40a0603a00) |
| V2 pools | 322 | `v2-liquidity-TestUSDT` | [`0x9daac6576acd2a592f13a226eae5eb4cc8c50ce4c8e871f8861bbdb610efec86`](https://basescan.org/tx/0x9daac6576acd2a592f13a226eae5eb4cc8c50ce4c8e871f8861bbdb610efec86) |
| V2 pools | 323 | `v2-approve-TestWBTC` | [`0x2b1884abc3147a1db0859798609d18858c4cc63766c3c75556ce9ba3fe5f8ba3`](https://basescan.org/tx/0x2b1884abc3147a1db0859798609d18858c4cc63766c3c75556ce9ba3fe5f8ba3) |
| V2 pools | 324 | `v2-liquidity-TestWBTC` | [`0x34d51979385b02b3926f6411e5a23c6b021a455e0a1393469ea894886442bc13`](https://basescan.org/tx/0x34d51979385b02b3926f6411e5a23c6b021a455e0a1393469ea894886442bc13) |
| V2 pools | 325 | `v2-approve-TestGHO` | [`0x32236b6cf96b263df0473a688bfc16fac1f454758ffd4be4440fe0c2390328d6`](https://basescan.org/tx/0x32236b6cf96b263df0473a688bfc16fac1f454758ffd4be4440fe0c2390328d6) |
| V2 pools | 326 | `v2-liquidity-TestGHO` | [`0x9e1fcf6329d5f7d6199a5ebdda39add4d7673202369344af982e750cec2c0cda`](https://basescan.org/tx/0x9e1fcf6329d5f7d6199a5ebdda39add4d7673202369344af982e750cec2c0cda) |
| V2 pools | 327 | `v2-approve-TestXAUT` | [`0xb639b4677364e2687b01a3ad6d7ca0a77868f3cbac9f24e403322c36b486b1f6`](https://basescan.org/tx/0xb639b4677364e2687b01a3ad6d7ca0a77868f3cbac9f24e403322c36b486b1f6) |
| V2 pools | 328 | `v2-liquidity-TestXAUT` | [`0xc0e06d46d645128ad4bf59c0837e71a75844a65acd01b6482f6a236dd5a3828b`](https://basescan.org/tx/0xc0e06d46d645128ad4bf59c0837e71a75844a65acd01b6482f6a236dd5a3828b) |
| V2 pools | 329 | `v2-approve-TestSyrupUSDC` | [`0x322d4f3749cc345330a0dec8f14529edd28184bdca448e2c6d80ae31d002ec8e`](https://basescan.org/tx/0x322d4f3749cc345330a0dec8f14529edd28184bdca448e2c6d80ae31d002ec8e) |
| V2 pools | 330 | `v2-liquidity-TestSyrupUSDC` | [`0xc8336a0adf6f18c67176952f383e010e7ef257755d27b6abcdaea4f74276f996`](https://basescan.org/tx/0xc8336a0adf6f18c67176952f383e010e7ef257755d27b6abcdaea4f74276f996) |
| V2 pools | 331 | `v2-approve-TestExtraToken` | [`0xb63b38457683a834ba366b48515e3ad975f367b9635801f414abf5c424d4a502`](https://basescan.org/tx/0xb63b38457683a834ba366b48515e3ad975f367b9635801f414abf5c424d4a502) |
| V2 pools | 332 | `v2-liquidity-TestExtraToken` | [`0xd8fb81eaff079a015c88814c94e33cb0e3a8a94344df82bc50b2b4aa8affaf76`](https://basescan.org/tx/0xd8fb81eaff079a015c88814c94e33cb0e3a8a94344df82bc50b2b4aa8affaf76) |

</details>

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
| N-03 | [ ] | THOR position preview and early/mid/full exit, liquid vs stake, payout, forfeiture, Owner-only QA recipient update, and independent withdrawal queue. | — |
| N-04 | [ ] | yTHOR position preview and early/mid/full exit, liquid vs stake, payout, forfeiture, pending rewards, and queue; specifically check the historical one-micro-USDC discrepancy. | — |
| N-05 | [ ] | Adjustable yTHOR reward weight: historical rewards settle first, all unexited holders receive future weight, and accounting stays conserved. | — |
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
