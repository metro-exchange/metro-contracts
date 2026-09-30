// Create and fund seven QA pairs using the official Base Uniswap V2 Factory and Router.
// Existing pairs are only read back; transaction steps resume from the runner state.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { ethers, root, runDir, readArtifact, openRun, sendStep } from './runner.mjs';

const ctx = await openRun();
const factoryAddress = '0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6';
const routerAddress = '0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24';
const factoryAbi = [
  'function getPair(address,address) view returns (address)',
  'function createPair(address,address) returns (address)',
  'event PairCreated(address indexed token0,address indexed token1,address pair,uint256)'
];
const routerAbi = [
  'function factory() view returns (address)',
  'function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) returns (uint256,uint256,uint256)'
];
const pairAbi = [
  'function token0() view returns (address)', 'function token1() view returns (address)',
  'function getReserves() view returns (uint112,uint112,uint32)',
  'function balanceOf(address) view returns (uint256)'
];
const factory = new ethers.Contract(factoryAddress, factoryAbi, ctx.provider);
const router = new ethers.Contract(routerAddress, routerAbi, ctx.provider);
const deployer = ctx.wallets.deployer.address;
const usdc = ctx.state.contracts.TestUSDC;
if (!usdc || (await router.factory()).toLowerCase() !== factoryAddress.toLowerCase()) {
  throw new Error('Router, Factory, or TestUSDC mismatch');
}
if ((await ctx.provider.getCode(factoryAddress)) === '0x' || (await ctx.provider.getCode(routerAddress)) === '0x') {
  throw new Error('The real V2 contract has no code');
}
const pools = [
  ['METRO', 18], ['TestUSDT', 6], ['TestWBTC', 8], ['TestGHO', 18],
  ['TestXAUT', 6], ['TestSyrupUSDC', 6], ['TestExtraToken', 18]
];
ctx.state.pairs ||= {};
const tokenArtifact = await readArtifact('out-core/ERC20Mintable.sol/ERC20Mintable.json');
const syrupArtifact = await readArtifact('out-core/MockSyrupUSDC.sol/MockSyrupUSDC.json');
const metroArtifact = await readArtifact('out-deploy/metro.sol/MetroToken.json');
const ppmArtifact = await readArtifact('out-core/MockDepositProtocols.sol/MockPoolPermissionManager.json');
function token(id) {
  const abi = id === 'METRO' ? metroArtifact.abi : id === 'TestSyrupUSDC' ? syrupArtifact.abi : tokenArtifact.abi;
  return new ethers.Contract(ctx.state.contracts[id], abi, ctx.provider);
}
const ppm = new ethers.Contract(ctx.state.contracts.MockPoolPermissionManager, ppmArtifact.abi, ctx.provider);
async function send(id, to, data) { return sendStep(ctx, { id, tx: { to, data } }); }
async function pairAddress(asset) {
  return factory.getPair(usdc, ctx.state.contracts[asset]);
}
for (const [asset] of pools) {
  if (!ctx.state.contracts[asset]) throw new Error('Missing output token: ' + asset);
  const existing = await pairAddress(asset);
  if (existing === ethers.constants.AddressZero) {
    await send('v2-create-' + asset, factoryAddress,
      factory.interface.encodeFunctionData('createPair', [usdc, ctx.state.contracts[asset]]));
  } else if (!ctx.state.steps['v2-create-' + asset]) {
    throw new Error('An external actor created this QA token pair; inspect before continuing: ' + asset);
  }
  const pair = await pairAddress(asset);
  if (pair === ethers.constants.AddressZero || (await ctx.provider.getCode(pair)) === '0x') throw new Error('Pair has no code: ' + asset);
  ctx.state.pairs[asset] = pair;
  await ctx.persist();
}
// Maple test shares have protocol permissions; enable only the V2 LP/pair operations needed here.
const syrupPair = ctx.state.pairs.TestSyrupUSDC;
for (const [label, lender] of [['deployer', deployer], ['pair', syrupPair]]) {
  await send('v2-syrup-permission-' + label, ppm.address,
    ppm.interface.encodeFunctionData('setLenderBitmap', [lender, 16]));
}
const usdcToken = new ethers.Contract(usdc, tokenArtifact.abi, ctx.provider);
const perPoolUsdc = ethers.utils.parseUnits('1000', 6);
await send('v2-approve-usdc', usdc,
  usdcToken.interface.encodeFunctionData('approve', [routerAddress, perPoolUsdc.mul(pools.length)]));
for (const [asset, decimals] of pools) {
  const output = token(asset);
  const outputAmount = ethers.utils.parseUnits('1000', decimals);
  await send('v2-approve-' + asset, output.address,
    output.interface.encodeFunctionData('approve', [routerAddress, outputAmount]));
  // Seed each pair with 1000:1000 test units; minimums are 99% and deadline uses the pre-broadcast block.
  const deadline = (await ctx.provider.getBlock('latest')).timestamp + 3600;
  await send('v2-liquidity-' + asset, routerAddress, router.interface.encodeFunctionData('addLiquidity', [
    usdc, output.address, perPoolUsdc, outputAmount,
    perPoolUsdc.mul(99).div(100), outputAmount.mul(99).div(100),
    deployer, deadline
  ]));
  const pair = new ethers.Contract(ctx.state.pairs[asset], pairAbi, ctx.provider);
  const token0 = await pair.token0();
  const token1 = await pair.token1();
  const reserves = await pair.getReserves();
  const reserveUSDC = token0.toLowerCase() === usdc.toLowerCase() ? reserves[0] : reserves[1];
  const reserveOut = token1.toLowerCase() === output.address.toLowerCase() ? reserves[1] : reserves[0];
  if (reserveUSDC.lt(perPoolUsdc.mul(99).div(100)) || reserveOut.lt(outputAmount.mul(99).div(100))) {
    throw new Error('V2 reserves are below the expected seeded minimum: ' + asset);
  }
  await mkdir(path.join(runDir, 'readbacks'), { recursive: true });
  const block = await ctx.provider.getBlock('latest');
  await writeFile(path.join(runDir, 'readbacks', 'v2-' + asset + '.json'), JSON.stringify({
    chainId: 8453, blockNumber: block.number, blockHash: block.hash, blockTimestamp: block.timestamp,
    router: routerAddress, factory: factoryAddress, pair: pair.address,
    token0, token1, reserveUSDC: reserveUSDC.toString(), reserveOut: reserveOut.toString(),
    lpBalance: (await pair.balanceOf(deployer)).toString(),
    outputToken: output.address, outputDecimals: decimals,
    createTx: ctx.state.steps['v2-create-' + asset].hash,
    approveOutputTx: ctx.state.steps['v2-approve-' + asset].hash,
    addLiquidityTx: ctx.state.steps['v2-liquidity-' + asset].hash
  }, null, 2) + '\n');
  console.log('V2', asset, pair.address, 'USDC=', reserveUSDC.toString(), 'out=', reserveOut.toString());
}
