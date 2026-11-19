# xMETRO Integration Examples

## October 24 source update

This source version changes yTHOR exits to 20%-100% of the converted METRO principal. Production opens exits after 120 days and reaches 100% over the following `4 * 365 days`; Base QA keeps its 4-hour delay and 12-hour ramp. Repeated migrations, independent position IDs, one complete exit per position, and `1e24` reward-debt precision are retained.

Only THOR/yTHOR migration positions owned by `migrationRewardExcludedAddress()` earn no USDC rewards and are excluded from the allocation denominator. Ordinary stakes, Contributor shares, received free xMETRO and migration payouts staked after exit retain normal prospective rewards. Existing earned rewards and fractional entitlements are preserved.

The existing Base QA deployment and its address/configuration records remain unchanged. Use the ABI and examples from that deployment's revision (QA baseline `60754e05436c6c8056b60eac481d0bdc96a89d4c`) with its existing addresses. This version's ABI/examples target newly created local instances or a future deployment requested by the project. Source changes do not update an immutable deployed Core or migrate its storage.

These runnable Node.js modules use `ethers` 5.8.0 and the ABI files from this delivery. Install dependencies in this directory with `npm install`, then run `npm run check`. They export functions for a frontend/backend to call with its own signer; they do **not** load a private key or broadcast anything on import.

- [`user-actions.mjs`](user-actions.mjs): approve and stake METRO, migrate THOR/yTHOR, claim, choose automatic actions, submit manual actions, request/withdraw, and authorize an Aave V4 Giver.
- [`backend-actions.mjs`](backend-actions.mjs): Operator reward funding, Keeper batch execution with unique candidates and an optional gas/reward check, and event queries.

Set `CONFIG_FILE` explicitly to a verified environment file for the same contract revision as these ABIs; the example environment has no default configuration path. `loadConfig()` accepts `deployed_pending_handover` and `deployed`; existing deployment JSON remains unchanged. The QA record uses the legacy status `deployed_pending_project_handover`, and belongs to the previous contract revision. Continue testing that deployment with its matching baseline examples. This update does not add status compatibility that would allow new ABIs to be used against old contracts. The Ethereum template remains `not_deployed`.

All balances and minimums are integer base units: METRO/THOR/yTHOR generally use 18 decimals, USDC uses 6, and each output asset has its own decimals. For a V2 swap, use `buildV2ExecutionData(path, quotedRewardIn)` with the same USDC input as the quote; the path begins with USDC and ends with the configured output. For a V4 batch, pass a nonzero minimum for each original candidate; for every other batch strategy pass an empty `minUserAmountsOut` array. For Maple first authorization, request the signature for the **Adapter Proxy**; do not ask users to approve USDC to the Adapter.

Swap helpers require the currently bound Adapter to report implementation version 2 and validate the new domain and nonzero cap before sending. Old or unknown versions are rejected; deposits keep their own encoding. Batch helpers retain the submitted quote unchanged and stop if eligible rewards exceed its cap. Requote the complete payload and simulate again; never raise only the cap. See the [encoding reference](../docs/new-features.md#swap-execution-data).

Example imports (the application supplies `quote`):

```js
import { ethers } from 'ethers';
import { loadConfig, approveAndStake, buildV2ExecutionData, buildSwapExecutionData } from './user-actions.mjs';

const config = await loadConfig(process.env.CONFIG_FILE); // A verified local/new deployment matching these ABIs.
const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
const signer = provider.getSigner(); // Replace with the actual wallet/Safe integration.
// Obtain quote.inputAmount, minimum output, route and deadline together from your quoting integration.
const quotedRewardIn = ethers.BigNumber.from(quote.inputAmount);
const data = buildV2ExecutionData([config.tokens.TestUSDC, config.tokens.TestUSDT], quotedRewardIn);
// V3: buildSwapExecutionData(1, quotedRewardIn, quote.packedPath)
// 1inch: buildSwapExecutionData(2, quotedRewardIn, quote.routerCalldata)
// await approveAndStake(signer, config, ethers.utils.parseEther('10'));
```

These are integration examples, not a deployment script or a promise that an external protocol accepts a given token or route. Review a quoted route, deadlines, minimum output and network before any transaction.

## Read and exit a position

Use decimal strings or ethers BigNumber values for IDs; do not convert large IDs through JavaScript Number.

```js
const positionId = '0';
const count = await core.yThorPositionCount(user);
if (count.gt(positionId)) {
  const position = await core.yThorPositions(user, positionId);
  const quote = await core.previewYThorExit(user, positionId);
  // await exitYThor(signer, config, positionId, 'stake');
}
// THOR: core.thorPositionCount(user), core.thorPositions(user, positionId),
// core.previewThorExit(user, positionId), core.requestThorExit(positionId),
// or core.exitAndStakeThor(positionId).
```

Counts include closed positions. Each position uses its own migration timestamp and permits only one complete exit. Production yTHOR uses a 120-day delay plus a 4 * 365-day ramp; QA keeps a 4-hour delay plus a 12-hour ramp. Read payout amounts from the selected position's preview. See the [API reference](../docs/contract-api.md) for event IDs and queue semantics.
