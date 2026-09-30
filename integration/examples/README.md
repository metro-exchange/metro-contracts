# xMETRO Integration Examples

These runnable Node.js modules use `ethers` 5.8.0 and the ABI files from this delivery. Install dependencies in this directory with `npm install`, then run `npm run check`. They export functions for a frontend/backend to call with its own signer; they do **not** load a private key or broadcast anything on import.

- [`user-actions.mjs`](user-actions.mjs): approve and stake METRO, migrate THOR/yTHOR, claim, choose automatic actions, submit manual actions, request/withdraw, and authorize an Aave V4 Giver.
- [`backend-actions.mjs`](backend-actions.mjs): Operator reward funding, Keeper batch execution with unique candidates and an optional gas/reward check, and event queries.

Load a verified environment file such as [`base-qa.json`](../config/base-qa.json). The examples reject a `pending_fresh_deployment` or `not_deployed` status. This QA branch contains the new Base deployment addresses and setup transaction hashes; verify on-chain permissions before sending a test action. Setup alone does not mark the functional checklist passed. `ethereum.json` deliberately contains no production deployment addresses.

All balances and minimums are integer base units: METRO/THOR/yTHOR generally use 18 decimals, USDC uses 6, and each output asset has its own decimals. For a V2 swap, `executionData = abi.encode(uint8(0), abi.encode(path))`; the path begins with USDC and ends with the configured output. For a V4 batch, pass a nonzero minimum for each original candidate; for every other batch strategy pass an empty `minUserAmountsOut` array. For Maple first authorization, request the signature for the **Adapter Proxy**; do not ask users to approve USDC to the Adapter.

Example imports:

```js
import { ethers } from 'ethers';
import { loadConfig, approveAndStake, buildV2ExecutionData } from './user-actions.mjs';

const config = await loadConfig('../config/base-qa.json');
const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
const signer = provider.getSigner(); // Replace with the actual wallet/Safe integration.
const data = buildV2ExecutionData([config.tokens.TestUSDC, config.tokens.TestUSDT]);
// await approveAndStake(signer, config, ethers.utils.parseEther('10'));
```

These are integration examples, not a deployment script or a promise that an external protocol accepts a given token or route. Review a quoted route, deadlines, minimum output and network before any transaction.
