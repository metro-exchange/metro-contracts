import { readFile } from 'node:fs/promises';
import ethersPackage from 'ethers';
import { address, assertChain } from './user-actions.mjs';

const { ethers } = ethersPackage;
const coreAbi = JSON.parse(await readFile(new URL('../abi/xMETRO.json', import.meta.url)));
const adapterAbi = JSON.parse(await readFile(new URL('../abi/XMetroDeFiAdapter.json', import.meta.url)));
const distributorAbi = JSON.parse(await readFile(new URL('../abi/RewardDistributor.json', import.meta.url)));
const tokenAbi = [
  'function allowance(address owner,address spender) view returns (uint256)',
  'function approve(address spender,uint256 amount) returns (bool)'
];

function uniqueAddresses(values) {
  if (!Array.isArray(values)) throw new Error('candidates must be an array');
  return [...new Set(values.map(value => address(value, 'candidate').toLowerCase()))]
    .map(ethers.utils.getAddress);
}

export async function distributeFromOperator(signer, config, amountUsdcBaseUnits) {
  await assertChain(signer, config);
  const distributorAddress = address(config.contracts.RewardDistributor, 'RewardDistributor');
  const usdcAddress = address(config.tokens.TestUSDC ?? config.tokens.USDC, 'USDC');
  const token = new ethers.Contract(usdcAddress, tokenAbi, signer);
  const allowance = await token.allowance(await signer.getAddress(), distributorAddress);
  if (allowance.lt(amountUsdcBaseUnits)) await (await token.approve(distributorAddress, amountUsdcBaseUnits)).wait();
  const distributor = new ethers.Contract(distributorAddress, distributorAbi, signer);
  return (await distributor.distribute(amountUsdcBaseUnits)).wait();
}

export async function distributeExistingBalance(signer, config, amountUsdcBaseUnits) {
  await assertChain(signer, config);
  const distributor = new ethers.Contract(address(config.contracts.RewardDistributor, 'RewardDistributor'), distributorAbi, signer);
  return (await distributor.distributeFromBalance(amountUsdcBaseUnits)).wait();
}

export async function eligibleAutoUsers(provider, config, strategyId, candidates) {
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, provider);
  const adapter = new ethers.Contract(address(config.contracts.XMetroDeFiAdapterProxy, 'Adapter Proxy'), adapterAbi, provider);
  const [info, coreEpoch] = await Promise.all([adapter.strategyInfo(strategyId), core.deFiAdapterEpoch()]);
  if (!info.enabled || !info.autoEnabled) throw new Error('Strategy is not enabled for automatic execution');
  const unique = uniqueAddresses(candidates);
  const filtered = [];
  for (const user of unique) {
    const [preference, pending] = await Promise.all([core.getAutoStrategyPreference(user), core.claimable(user)]);
    if (pending.isZero() || preference.strategyId !== strategyId) continue;
    if (!preference.adapterEpoch.eq(coreEpoch) || !preference.logicEpoch.eq(info.logicEpoch)
        || !preference.domainRevision.eq(info.domainRevision)
        || !preference.strategyRevision.eq(info.strategyRevision)) continue;
    filtered.push(user);
  }
  return filtered;
}

export async function runAutoBatch(signer, config, options) {
  await assertChain(signer, config);
  const {
    strategyId, candidates, minTotalAmountOut, minPerUser = {},
    deadline = 0, executionData = '0x', ethPriceUsdc6,
    gasBufferBps = 12_000, maxGasToRewardBps = 500
  } = options;
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer);
  const users = await eligibleAutoUsers(signer.provider, config, strategyId, candidates);
  if (!users.length) throw new Error('No eligible users with current pending rewards');

  const adapter = new ethers.Contract(address(config.contracts.XMetroDeFiAdapterProxy, 'Adapter Proxy'), adapterAbi, signer.provider);
  const info = await adapter.strategyInfo(strategyId);
  // StrategyKind.AaveV4 is 4; its per-user minima align with this filtered candidate array.
  const minUserAmountsOut = Number(info.kind) === 4
    ? users.map(user => {
        const minimum = ethers.BigNumber.from(minPerUser[user.toLowerCase()] ?? 0);
        if (minimum.isZero()) throw new Error(`Missing Aave V4 minimum for ${user}`);
        return minimum;
      })
    : [];
  const [totalPending] = await core.claimableMany(users);
  const estimatedGas = await core.estimateGas.executeAutoStrategyBatch(
    strategyId, users, minTotalAmountOut, minUserAmountsOut, deadline, executionData
  );
  const fee = await signer.provider.getFeeData();
  const gasPrice = fee.maxFeePerGas ?? fee.gasPrice;
  if (!gasPrice) throw new Error('Provider did not return a gas price');
  let safeCostUsdc6 = null;
  if (ethPriceUsdc6 !== undefined) {
    // ETH price is passed in USDC base units per ETH, e.g. 2464210000 for $2,464.21.
    safeCostUsdc6 = estimatedGas.mul(gasPrice).mul(ethPriceUsdc6)
      .div(ethers.constants.WeiPerEther).mul(gasBufferBps).div(10_000);
    const allowed = totalPending.mul(maxGasToRewardBps).div(10_000);
    if (safeCostUsdc6.gt(allowed)) {
      return { executed: false, reason: 'gas-to-reward threshold', users, totalPending, estimatedGas, safeCostUsdc6 };
    }
  }
  const tx = await core.executeAutoStrategyBatch(
    strategyId, users, minTotalAmountOut, minUserAmountsOut, deadline, executionData,
    { gasLimit: estimatedGas.mul(120).div(100) }
  );
  return { executed: true, users, totalPending, estimatedGas, safeCostUsdc6, receipt: await tx.wait() };
}

export async function runCompoundBatch(signer, config, candidates, minMetroOut, deadline, swapData) {
  await assertChain(signer, config);
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer);
  const users = uniqueAddresses(candidates);
  const eligible = [];
  for (const user of users) {
    if (await core.autocompoundEnabled(user) && !(await core.claimable(user)).isZero()) eligible.push(user);
  }
  if (!eligible.length) throw new Error('No eligible compound users');
  return (await core.autocompoundBatch(eligible, minMetroOut, deadline, swapData)).wait();
}

export async function readRecentEvents(provider, config, fromBlock, toBlock) {
  if (fromBlock > toBlock) throw new Error('fromBlock exceeds toBlock');
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, provider);
  const distributor = new ethers.Contract(address(config.contracts.RewardDistributor, 'RewardDistributor'), distributorAbi, provider);
  const [claims, actions, routed] = await Promise.all([
    core.queryFilter(core.filters.RewardClaimed(), fromBlock, toBlock),
    core.queryFilter(core.filters.ClaimAndExecuted(), fromBlock, toBlock),
    distributor.queryFilter(distributor.filters.DistributionRouted(), fromBlock, toBlock)
  ]);
  return { claims, actions, routed };
}
