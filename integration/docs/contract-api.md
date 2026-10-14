# Contract API, Roles, and Configuration

This guide covers project-contract administration and public integration parameters. User journeys are in [existing features](existing-features.md) and [new features](new-features.md). It does not document the Commission Vault's internal governance or payout rules.

## Roles and permissions

Four project contracts have separate owners: METRO, xMETRO, ThorMigrationEscrow, and RewardDistributor. The Adapter has **no independent owner**: configuration and UUPS upgrades are authorized by the current xMETRO owner. The ERC1967 proxy has no separate ProxyAdmin. Calls to configure or upgrade the Adapter target the **proxy**, not the implementation.

| Role | Owner call | Business permission |
| --- | --- | --- |
| METRO minter | `METRO.setMinter(account,allowed)` | `METRO.mint(to,amount)` within the fixed global cap |
| Contributor | `xMETRO.setContributor(account,allowed)` | `stakeContributor(amount,receiver)` using the caller's own METRO |
| Keeper | `xMETRO.setAutoCompoundOperator(account,allowed)` | Legacy and general auto batches |
| Reward operator | `Distributor.setOperator(account,allowed)` | `distribute` and `distributeFromBalance` |

Owners do not automatically receive these business permissions. `true` grants and `false` revokes. More than one account may be authorized. A Keeper must still respect each user's opt-in; an operator still needs USDC and/or a Distributor balance. The xMETRO core must remain a METRO minter for normal migration.

## Owner configuration

| Contract / caller | Function | Parameters and effect |
| --- | --- | --- |
| METRO owner | `setMinter(minter,allowed)` | Controls mint access; no owner setter can change the 100,000,000 METRO cap. |
| xMETRO owner | `setYThorRewardWeightBps(weightBps)` | `10,000=1x`, `20,000=2x`; values from zero to the contract technical bound. Applies to future reward deposits for all active yTHOR positions, never reprices accrued rewards; no pause required. |
| xMETRO owner | `setContributor(account,allowed)`; `setAutoCompoundOperator(account,allowed)` | Contributor and Keeper allowlists. |
| xMETRO owner | `setDeFiAdapter(proxy)` | Must be the current-family proxy correctly bound to this core, USDC, and METRO. Use the proxy address, not the implementation. |
| xMETRO owner | `setMigrationEscrow(escrow)`; `setRewardDistributor(distributor)` | Requires binding to this core; Distributor must use the same USDC. |
| xMETRO owner | `setDefaultMaxVestingSchedules(count)` | Default for a call with `maxSchedules=0`; not a global schedule cap. |
| xMETRO owner | `pause()`; `unpause()` | Global core pause. Normal configuration does not require pausing. |
| xMETRO owner | `emergencyDistribute(users)` | Requires the core to be paused; pays recorded USDC rewards, not METRO principal. |
| xMETRO owner | `rescueERC20(token,to,amount)` | Cannot rescue principal-backing METRO; other rescue decisions must account for reward liabilities. |
| Escrow owner | `setMigrationStartTime(timestamp)` | Unix seconds; must not be in the past. |
| Escrow owner | `setDeadlines(thorDeadline,yThorDeadline)` | Separate Unix-second deadlines, each after migration start. |
| Escrow owner | `setRatios(thorRatio,yThorRatio)` | 18-decimal fixed-point, both nonzero; can be set **once only**. `0.3928569546` encodes as `392856954600000000`. |
| Escrow owner | `setCaps(thorCap,yThorCap)` | 18-decimal METRO principal limits after conversion, not input-token counts. |
| Escrow owner | `pause()`; `unpause()`; `rescueTokens(token,to,amount)` | Escrow pause is independent; THOR and yTHOR are protected from rescue. |
| Distributor owner | `setOperator(account,allowed)` | Account sending distribution transactions. |
| Distributor owner | `setCommissionVault(vault)` | Nonzero Vault must use the same USDC, bind this Distributor, be finalized, and be unpaused. |
| Distributor owner | `setMaxCommissionSplitBps(bps)` | `0..10,000`; `100=1%`, `0` disables Vault routing. Actual payment also depends on `requiredTopUp()`. |
| Distributor owner | `rescueTokens(token,to,amount)` | Review any undistributed funds first. |

`distribute(amount)` pulls USDC from the operator's wallet, so that wallet must hold USDC and approve the Distributor. `distributeFromBalance(amount)` spends USDC already held by the Distributor and does not need the operator's USDC approval for that call. Both require `amount>0`; USDC uses six decimals (`1_000_000 = 1 USDC`).

```text
commissionCap = grossAmount * maxCommissionSplitBps / 10,000
commission    = min(commissionCap, Vault.requiredTopUp())
coreReward    = grossAmount - commission
```

The Distributor transfers commission USDC directly to the Vault; it neither approves the Vault nor invokes a deposit callback. To clear a Vault, first set the split to zero, then call `setCommissionVault(address(0))`.

## Adapter configuration

All calls below are sent by the **xMETRO owner to the current Adapter proxy**. Effective configuration changes invalidate affected user auto preferences; pending rewards remain intact. Disabling Aave/Maple does not call the old protocol; reenabling verifies bindings again.

| Function | Values to supply |
| --- | --- |
| `setRouters(v2,v3,oneInch)` | Three distinct deployed Router addresses on the selected chain. Do not use a Factory or API endpoint. |
| `setSwapMetroConfig(enabled,autoEnabled)` | USDC-to-METRO strategy flags. |
| `setSwapTokenConfig(tokenOut,enabled,autoEnabled)` | Allowlisted output ERC-20. USDC and METRO cannot be ordinary Auto-Swap outputs. |
| `setAaveV3Config(pool,aUSDC,referralCode,enabled,autoEnabled)` | Matched USDC Pool/aToken pair; `referralCode` is uint16. |
| `setAaveV4Config(spoke,giver,reserveId,enabled,autoEnabled)` | Matched Spoke, official Giver, and USDC reserve ID. The Giver must be registered and active. |
| `setMapleConfig(syrupRouter,depositData,enabled,autoEnabled)` | SyrupRouter address and bytes32 deposit data; syrupUSDC is derived from the Router. |
| `upgradeToAndCall(newImplementation,data)` | UUPS implementation upgrade through the proxy. Use `0x` when no initializer call is needed. |
| `rescueERC20(token,to,amount)` | Requires the current core owner **and** a paused core. |

`enabled=true,autoEnabled=false` allows manual use but not Keeper execution. `setSwapTokenConfig`, `setAaveV3Config`, and `setMapleConfig` return a strategy ID; `setAaveV4Config` does not. A normal UUPS upgrade keeps the proxy address and increments its logic epoch. Replacing the entire proxy is a multi-transaction recovery operation: pause the core, prepare and bind the replacement, copy and read back configuration, then unpause. A new Maple proxy needs its own authorization. Existing Aave V4 user permission remains usable if Spoke/Giver are unchanged.

Protocol permissions are separate from project governance:

- Aave V4: each user calls `Spoke.setUserPositionManager(giver,true)` (or `false` to revoke). This authorizes the **Giver** as a position manager; it is not an ERC-20 allowance. The Adapter supplies USDC, so the user does not approve USDC to either contract.
- Maple: request an authorization signature for the actual Adapter proxy when it is not already permitted, then supply the encoded signature through the xMETRO action. A new proxy needs a new authorization.

## Base QA TestTokens and mocks

The new Base QA deployment uses owner-only `mint` for TestUSDC, TestTHOR, TestYTHOR, TestUSDT, TestWBTC, TestGHO, TestXAUT, TestExtraToken, and TestSyrupUSDC. Their `owner()` can be transferred in one step. METRO is the real capped token and uses `setMinter`; its deployer minter permission must be reviewed and revoked during final handover if no longer needed.

QA protocol administration is also owner-controlled: Aave V3 Pool, V4 Spoke, Giver, Maple Router, and PermissionManager expose transferable ownership for their test controls. Aave V3 aUSDC can be minted by the mock Pool on supply; its test-only `donateScaled` permission follows the Pool owner. Aave V4 supplies are internal Spoke shares, not a freely mintable ERC-20. Maple protocol deposits mint syrupUSDC shares through the mock Pool. These mock-only controls do not describe production Aave/Maple governance.

The Base QA Maple mock enforces share-transfer permissions. Its owner must call `MockPoolPermissionManager.setLenderBitmap(tester,16)` for any new test wallet that will receive TestSyrupUSDC through a V2 swap or a Maple deposit. The deployment prepares the included local QA wallets and the V2 pair, but it cannot pre-authorize unknown project test wallets. This bitmap is a mock test setting, not an ERC-20 approval.

Before project addresses are provided, the fresh QA deployment keeps these temporary owner/minter roles locally. `integration/config/base-qa.json` records each actual address and current role; transferring ownership later requires separate on-chain transactions and a new config readback. Historical Base QA addresses are not reusable.

## Two-address handover

Let `A` be the project management address (possibly a multisig) and `B` the backend execution wallet. The current owner of each contract, not a random multisig signer EOA, sends its transfer/configuration transaction.

```solidity
// Configure business permissions while the deployment team still owns these contracts.
rewardDistributor.setOperator(B, true);
xMETRO.setAutoCompoundOperator(B, true);
metro.setMinter(A, true); // Only if A will mint METRO for QA; keep xMETRO as a minter.
mockPermissionManager.setPermissionAdmin(B, true); // If B will sign Base QA Maple authorizations.
// If needed, grant Contributor to the address that will create schedules.
xMETRO.setContributor(contributorAddress, true);

// Transfer ownership last; after these calls, only A can change configuration.
metro.transferOwnership(A);
xMETRO.transferOwnership(A);
escrow.transferOwnership(A);
rewardDistributor.transferOwnership(A);
```

The new xMETRO and the other project contracts use one-step ownership transfer; no `acceptOwnership()` is needed. TestToken and Mock owners are transferred separately. A project Safe can hold ownership and mint control; the backend wallet does not need those powers. If any permission is configured after ownership transfer, A must send that call. Transfer of ownership does not revoke old Keeper, Operator, Minter, Contributor, or Mock permission-admin roles—review and revoke each obsolete allowance explicitly. In particular, revoke the temporary Maple signature admins only after B can sign the QA authorization. Do not use `renounceOwnership()` as a handover method.

## Readback checklist

After each confirmed transaction, read `owner()` from each contract; `METRO.isMinter`, `Distributor.operators`, `xMETRO.autoCompoundOperators`, `xMETRO.contributorWhitelist`, `xMETRO.yThorRewardWeightBps`, core bindings and pause status, Escrow start/deadline/ratio/cap getters, Distributor Vault/split getters, Adapter `configuration`/`strategyInfo`/`aaveV4Giver`, and each user's auto preference when relevant. For QA, also read each TestToken/Mock `owner()` and public mint rights. A local `.env` edit, UI status, or dry run does not change chain state.
