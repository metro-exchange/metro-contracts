# New-Feature Integration

This guide explains how frontend and backend clients construct calls for the new and replaced reward paths. See [contract roles and API](contract-api.md) for administration, [existing features](existing-features.md) for legacy compatibility, and the [integration index](../README.md) for environment-specific results. Never use a local fork contract address as a production address.

## Dynamic yTHOR reward weight and METRO cap

Read `xMETRO.yThorRewardWeightBps()` (`10,000=1x`, `20,000=2x`). The owner may call `setYThorRewardWeightBps(weightBps)` without pausing. Zero and values below 1x are supported; the contract's technical maximum is `uint128.max`, not an arbitrary fixed 5x business cap. A change affects **future reward deposits for all eligible active yTHOR positions**, including already-migrated holders, and never reprices accrued pending rewards. Listen for `YThorRewardWeightBpsUpdated`, then refresh `rewardWeightOf(user)` and `totalRewardWeight()`. `totalSharesOf(user)` is principal, not reward weight. If no positive reward weight remains, a reward deposit cannot be allocated and reverts.

The fixed `migrationRewardExcludedAddress()` is excluded only for its THOR/yTHOR migration positions. Ordinary stakes and payouts exited into staking remain eligible; see [the treasury rules](contract-api.md#treasury-migration-reward-exclusion).

METRO `cap()` and `MAX_SUPPLY()` are permanently `100_000_000 ether`. All minters share that cap; migration principal consumes mint capacity, while reward multipliers do not. Check both Escrow caps and remaining global METRO supply.

## Manual claim and execution

Users send this call to **xMETRO**, not to the Adapter:

```solidity
claimAndExecute(
    bytes32 strategyId,
    uint256 minAmountOut,
    uint256 deadline,
    bytes executionData
) returns (uint256 rewardAmount, uint256 amountOut)
```

Read `claimable(user)`, `deFiAdapter()`, and `strategyInfo(strategyId)` first. The Core computes and consumes the caller's entire current pending USDC; the frontend cannot substitute an arbitrary wallet balance or recipient. Prepare the minimum output and protocol data for that amount. On success, inspect `ClaimAndExecuted` plus the output token balance or protocol position and refresh pending. A submitted transaction hash is not proof of success. This entrypoint does not need user USDC approval or prior auto opt-in. Rewards earned from normal stake, THOR, yTHOR, and Contributor positions share this same pending balance.

USDC-to-METRO-and-stake uses the preserved `autocompound(minMetroOut,deadline,swapData)` entrypoint, not `claimAndExecute` with the SwapMetro strategy.

## Strategy IDs and result units

Use ABI encoding, **not** `abi.encodePacked`:

```solidity
strategyId = keccak256(abi.encode(
    block.chainid,
    keccak256("XMETRO_DEFI_STRATEGY_V1"),
    uint8(kind),
    outputToken
));
```

| `kind` | Path | `outputToken` used in ID | Minimum/result unit |
| ---: | --- | --- | --- |
| 1 | METRO compound | METRO | METRO smallest units (18 decimals) |
| 2 | Output-token swap | Allowlisted ERC-20 | Token smallest units; query `decimals()` |
| 3 | Aave V3 | Configured aUSDC | Nominal aUSDC converted from scaled shares and index |
| 4 | Aave V4 | Zero address | Spoke supply shares, not USDC or an ERC-20 balance |
| 5 | Maple | Configured syrupUSDC | syrupUSDC share units |

Always read `strategyInfo` to verify kind, output token, `enabled`, and `autoEnabled`; calculability alone does not mean a strategy is configured. The initial Ethereum swap-output set is USDT, WBTC, GHO, XAUT, and syrupUSDC. Swapping into syrupUSDC (`kind=2`) and depositing USDC into Maple (`kind=5`) are different strategies.

## Swap execution data

All routes start with USDC. `minAmountOut` must be positive; the outer `deadline` is a future Unix timestamp. Encode:

```solidity
executionData = abi.encode(
    keccak256("XMETRO_SWAP_V2"), uint8(dexType), uint256(maxRewardIn), bytes(routeData)
);
```

| `dexType` | `routeData` | Requirement |
| ---: | --- | --- |
| 0: Uniswap V2 | `abi.encode(address[] path)` | At least two assets, USDC first and configured output last. |
| 1: Uniswap V3 | Packed `token + uint24 fee + token ...` | Correct path length and endpoint assets; do not encode as `address[]`. |
| 2: 1inch V6 | Full Router calldata including selector | Only validated general `swap(executor,description,data)` calls are supported. |

Adapter implementation version 2 requires this envelope for all three DEX types. `maxRewardIn` is the nonzero USDC input used by the same quote as the minimum output, route and deadline (6-decimal base units). Actual input above this cap reverts the whole Core action, restoring rewards, transfers and accounting. Equal or smaller input still has to pass the existing minimum-output and routing checks; 1inch additionally requires its exact input. Legacy `(uint8,bytes)` data is rejected. Deposits retain their existing format.

For batches, quote only the unique users whose current strategy preferences and revisions are eligible. If rewards increase beyond the saved cap, obtain a complete new quote and simulate again; never raise only the cap or use an unlimited default. A successful simulation does not prevent later reward arrivals, which the on-chain check handles atomically.

1inch calldata must match the selected chain and configured Router, exact USDC input, allowlisted output, and **Adapter proxy** as Router output recipient—not the Core, implementation, or final user. The supported general swap selector is `0x07ed2379`. Native value, partial fill, extra-native, and Permit2 flags are not accepted. The Adapter verifies actual spent/received balances and forwards output to the user.

If the project uses its 1inch Affiliate, the backend supplies `fee` and `referrer` in its 1inch API request. The contracts have no separate affiliate ledger and do not enforce an affiliate fee on every swap. A normal public-site quote does not prove affiliate charging. Quotes and calldata must be regenerated against current amount, recipient, route, slippage, and deadline.

## Deposits

Deposit actions also enter through `claimAndExecute`. The **outer** `deadline` is zero and `executionData` is not a swap-route envelope.

| Protocol | `executionData` | User-side authorization | Result |
| --- | --- | --- | --- |
| Aave V3 | Empty `0x` | No user USDC approval | Manual deposit credits aUSDC to the user. |
| Aave V4 | Empty `0x` | User authorizes the official Giver as position manager in the Spoke | Spoke records supply shares; no separate receipt ERC-20. |
| Maple | Empty if already authorized; otherwise encoded signature | Signature authorizes actual Adapter proxy | syrupUSDC shares are delivered to the user. |

For Aave V4, first obtain `giver = AdapterProxy.aaveV4Giver()`. Each user calls `Spoke.setUserPositionManager(giver,true)` and may later revoke with `false`. The Giver must be registered and active for that Spoke. The flow is user permission → xMETRO → Adapter's USDC → Giver → Spoke user shares. The user does not approve USDC for this reward action; the Adapter sets and clears its temporary allowance to the Giver.

For Maple, obtain a live protocol signature for the actual Adapter proxy and Pool and pass:

```solidity
abi.encode(uint256(bitmap), uint256(signatureDeadline), uint8(v), bytes32(r), bytes32(s))
```

Convert API `v=0/1` to `27/28`. The signature deadline is distinct from the outer action deadline (zero for deposit). Never fabricate or reuse a signature for another lender, nonce, pool, or proxy. `depositData` is an owner-set Adapter configuration value, not part of this signature encoding. After authorization, use empty execution data for ordinary deposits.

## Auto preferences and Keeper batches

Users call `enableAutoStrategy(strategyId)` or `disableAutoStrategy()` for auto swap/deposit, or the legacy `enableAutocompound()` / `disableAutocompound()` pair for Auto-Compound. These modes are mutually exclusive. Disabling remains possible during a Core pause; enabling and execution do not. Opting in does not itself start a transaction or schedule periodic execution.

An authorized Keeper sends to **xMETRO**:

```solidity
executeAutoStrategyBatch(
    bytes32 strategyId,
    address[] candidates,
    uint256 minTotalAmountOut,
    uint256[] minUserAmountsOut,
    uint256 deadline,
    bytes executionData
) returns (uint256 totalRewardAmount, uint256 amountOut)
```

The backend deduplicates candidate addresses, checks `getAutoStrategyPreference` and `claimableMany`, obtains fresh quotes or deposit estimates for actual pending rewards, simulates and estimates the complete transaction, and sends only an economically acceptable batch. The Core repeats all relevant checks on-chain; a failure rolls back the whole batch. There is no fixed 50/100/200-user business limit, but gas capacity and rounding constrain practical batch size.

| Path | `minUserAmountsOut` | Execution |
| --- | --- | --- |
| Auto-Swap | Empty | One swap, proportional token distribution. |
| Aave V3 | Empty | One deposit, proportional scaled aToken distribution. |
| Aave V4 | Same length as the **original** `candidates` array | One supply per effective user in the same Core transaction; each effective minimum must be positive. |
| Maple | Empty | One deposit, proportional syrupUSDC distribution. |

`minTotalAmountOut` must be positive. For V4, candidate filtering also filters minima by the original indexes; do not submit an array sized only to the already-filtered users. Legacy Auto-Compound instead uses `autocompoundBatch(users,minMetroOut,deadline,swapData)` and performs one USDC-to-METRO swap before Core mints proportional shares.

Auto preferences carry strategy ID, Core Adapter epoch, Adapter logic epoch, protocol-domain revision, and strategy revision. A Router/strategy change, UUPS upgrade, or full proxy replacement can invalidate preferences without removing pending rewards. Users must opt in again to the current strategy; the Keeper cannot silently renew consent. A new Maple proxy needs a new Maple authorization, while Aave V4 Giver permission depends on the Spoke/Giver pair rather than the project proxy.

## Commission routing and emergency payout

The reward operator calls `Distributor.distribute(grossAmount)` with USDC approval from its own wallet or `distributeFromBalance(grossAmount)` using pre-funded Distributor USDC. Commission is `min(grossAmount * maxCommissionSplitBps / 10_000, Vault.requiredTopUp())`; the balance enters xMETRO. The Distributor transfers USDC directly to the Vault—no Vault approval or deposit callback. Use `DistributionRouted` for gross/commission/net values; `RewardsDistributed.amount` and the Core's `RewardsDeposited.amount` refer to **net** rewards. Vault internal management and settlement are outside this guide.

Only the xMETRO owner can call `emergencyDistribute(users)`, and only while the Core is paused. It pays each recorded USDC pending balance directly to its user, skipping zero addresses, duplicates, and zero balances. It does not exit positions, move METRO principal, or migrate the system. A Keeper-only wallet cannot call it.

## Event and error handling

Use Core `ClaimAndExecuted`, `AutoStrategyBatchExecuted`, `AutoCompounded`, and `AutocompoundBatchExecuted` as appropriate, plus Adapter `UserStrategySettled` for per-user batch results. One ERC-20 `Transfer` alone does not establish complete business success. Adapter errors distinguish access/state, configuration, invalid request, slippage, accounting, Aave V4 authorization, and Maple authorization failures. Refresh chain state before retrying; do not bypass checks by zeroing minimum output, changing a fixed recipient, or fabricating a signature.

Base QA uses TestTokens, Aave/Maple mocks, and real V2 liquidity; Ethereum forks test real Ethereum protocols. See the [Base checklist](../testing/base/BASE_ONCHAIN_FUNCTIONAL_TEST_CHECKLIST.md), [Ethereum checklist](../testing/ethereum-fork/CHECKLIST.md), and [fork results](../testing/ethereum-fork/RESULTS.md) for actual coverage and the historical F-01 observation with current regression status.

## Reward accounting precision

Core tracks signed reward debt at the existing `1e24` accumulator precision. Share changes retain the full debt product. Claims, emergency payments, manual actions, and automatic batches consume only whole USDC base units and retain the fractional remainder. Zero-value claims preserve that remainder. `rewardDebt(user)` keeps its ABI and displays USDC base units, truncating negative fractions toward zero; use `claimable` / `claimableMany` for payable amounts instead of reconstructing them from the display getter. Adapter inputs and event amounts remain in token base units.
