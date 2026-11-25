// Deploy and configure the testbed in resumable, receipt-backed stages.
// Business contracts come from the short-timer build in out-testbed (script/base-qa/build-qa-core.mjs).
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { ethers, root, runDir, chainId, qaConfig, readArtifact, openRun, sendStep } from './runner.mjs';

const v2 = '0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24';
const v3 = '0x2626664c2603336E57B271c5C0b26F421741e481';
const oneInch = '0x111111125421ca6dc452d289314280a0f8842a65';
const zero = ethers.constants.AddressZero;
const qaConversionRatio = '0.3928569546';
const qaMigrationWindowSeconds = 30 * 24 * 60 * 60;
const qaMigrationStartDelaySeconds = 300;
const c = (id) => {
  const address = ctx.state.contracts[id];
  if (!address) throw new Error('Missing prerequisite deployment: ' + id);
  return address;
};
const ctx = await openRun();
const publicWallets = JSON.parse(await readFile(path.join(root, 'integration/testing/base/wallets.json')));
const addr = Object.fromEntries(publicWallets.accounts.map(x => [x.role, x.address]));
const phase = process.argv[2] || 'all';
const phases = ['tokens', 'mocks', 'core', 'config', 'seed', 'ownership'];
if (phase !== 'all' && !phases.includes(phase)) throw new Error('Unknown stage: ' + phase);

async function contract(name, address) {
  const a = await readArtifact(name);
  return new ethers.Contract(address, a.abi, ctx.provider);
}
async function deploy(id, name, args) {
  const a = await readArtifact(name);
  const factory = new ethers.ContractFactory(a.abi, a.bytecode.object);
  const tx = factory.getDeployTransaction(...args);
  return (await sendStep(ctx, { id, tx, expectContract: true })).contractAddress;
}
async function call(id, name, contractId, fn, args, role = 'deployer') {
  const target = await contract(name, c(contractId));
  return sendStep(ctx, {
    id, role, tx: { to: target.address, data: target.interface.encodeFunctionData(fn, args) }
  });
}
async function recordReadbacks(label, values) {
  await mkdir(path.join(runDir, 'readbacks'), { recursive: true });
  const block = await ctx.provider.getBlock('latest');
  const file = path.join(runDir, 'readbacks', label + '.json');
  await writeFile(file, JSON.stringify({
    chainId, blockNumber: block.number, blockHash: block.hash, blockTimestamp: block.timestamp, values
  }, (_, v) => ethers.BigNumber.isBigNumber(v) ? v.toString() : v, 2) + '\n');
}
async function tokenStage() {
  const tokens = [
    ['TestUSDC', 'Test USDC', 'TestUSDC', 6],
    ['TestTHOR', 'Test THOR', 'TestTHOR', 18],
    ['TestYTHOR', 'Test yTHOR', 'TestYTHOR', 18],
    ['TestUSDT', 'Test USDT', 'TestUSDT', 6],
    ['TestWBTC', 'Test WBTC', 'TestWBTC', 8],
    ['TestGHO', 'Test GHO', 'TestGHO', 18],
    ['TestXAUT', 'Test XAUT', 'TestXAUT', 6],
    ['TestExtraToken', 'Test Extra Token', 'TestExtraToken', 18]
  ];
  for (const [id, name, symbol, decimals] of tokens) await deploy(id, 'ERC20Mintable', [name, symbol, decimals]);
  await deploy('TestSyrupUSDC', 'MockSyrupUSDC', [c('TestUSDC')]);
  const readbacks = {};
  for (const [id, name, symbol, decimals] of tokens) {
    const token = await contract('ERC20Mintable', c(id));
    const actual = [await token.name(), await token.symbol(), Number(await token.decimals())];
    if (JSON.stringify(actual) !== JSON.stringify([name, symbol, decimals])) throw new Error('Token metadata mismatch: ' + id);
    readbacks[id] = { address: c(id), name: actual[0], symbol: actual[1], decimals: actual[2], totalSupply: (await token.totalSupply()).toString() };
  }
  const syrup = await contract('MockSyrupUSDC', c('TestSyrupUSDC'));
  if ((await syrup.asset()).toLowerCase() !== c('TestUSDC').toLowerCase()) throw new Error('Syrup asset mismatch');
  readbacks.TestSyrupUSDC = { address: c('TestSyrupUSDC'), asset: await syrup.asset(), decimals: Number(await syrup.decimals()) };
  await recordReadbacks('tokens', readbacks);
}
async function mockStage() {
  await deploy('MockAaveV3Pool', 'MockAaveV3Pool', [c('TestUSDC'), ethers.BigNumber.from(10).pow(27)]);
  const pool = await contract('MockAaveV3Pool', c('MockAaveV3Pool'));
  ctx.state.contracts.MockScaledAToken = await pool.aUsdc();
  await ctx.persist();
  await deploy('MockAaveV4Spoke', 'MockAaveV4Spoke', [c('TestUSDC'), 7]);
  await deploy('MockAaveV4Giver', 'MockAaveV4Giver', [c('MockAaveV4Spoke')]);
  await deploy('MockPoolPermissionManager', 'MockPoolPermissionManager', []);
  await deploy('MockSyrupRouter', 'MockSyrupRouter', [
    c('TestUSDC'), c('TestSyrupUSDC'), c('MockPoolPermissionManager'), addr.rewardOperator
  ]);
  await call('maple-bind-syrup', 'MockSyrupUSDC', 'TestSyrupUSDC', 'configureMock',
    [c('MockSyrupRouter'), c('MockPoolPermissionManager')]);
  await call('maple-grant-signer', 'MockPoolPermissionManager', 'MockPoolPermissionManager',
    'setPermissionAdmin', [addr.rewardOperator, true]);
  await call('maple-grant-deployer', 'MockPoolPermissionManager', 'MockPoolPermissionManager',
    'setPermissionAdmin', [addr.deployer, true]);
  await call('maple-grant-router', 'MockPoolPermissionManager', 'MockPoolPermissionManager',
    'setPermissionAdmin', [c('MockSyrupRouter'), true]);
  const syrup = await contract('MockSyrupUSDC', c('TestSyrupUSDC'));
  const maple = await contract('MockSyrupRouter', c('MockSyrupRouter'));
  const giver = await contract('MockAaveV4Giver', c('MockAaveV4Giver'));
  if ((await maple.pool()).toLowerCase() !== c('TestSyrupUSDC').toLowerCase()) throw new Error('Maple Pool binding mismatch');
  if ((await syrup.manager()).toLowerCase() !== c('MockSyrupRouter').toLowerCase()) throw new Error('Syrup manager mismatch');
  if (!(await giver.isSpokeRegistered(c('MockAaveV4Spoke')))) throw new Error('Giver Spoke is not registered');
  await recordReadbacks('mocks', {
    aUsdc: c('MockScaledAToken'), v3Pool: c('MockAaveV3Pool'),
    v4Spoke: c('MockAaveV4Spoke'), giver: c('MockAaveV4Giver'),
    mapleRouter: c('MockSyrupRouter'), maplePool: c('TestSyrupUSDC'),
    maplePermissionManager: c('MockPoolPermissionManager')
  });
}
function requireAddress(name) {
  const value = process.env[name];
  if (!value || !ethers.utils.isAddress(value) || value === zero) throw new Error('Set ' + name + ' to a nonzero address');
  return ethers.utils.getAddress(value);
}
async function preparePlan() {
  if (process.env.BASE_QA_MIGRATION_START_TIME || process.env.BASE_QA_DEADLINE_THOR || process.env.BASE_QA_DEADLINE_YTHOR ||
      (process.env.BASE_QA_RATIO_THOR && process.env.BASE_QA_RATIO_THOR !== qaConversionRatio) ||
      (process.env.BASE_QA_RATIO_YTHOR && process.env.BASE_QA_RATIO_YTHOR !== qaConversionRatio)) {
    throw new Error('The testbed migration starts 5 minutes after Escrow deployment; both deadlines are +30 days and both ratios are 0.3928569546');
  }
  const forfeitureRecipient = requireAddress('BASE_QA_FORFEITURE_RECIPIENT');
  if (ctx.state.plan && ctx.state.plan.forfeitureRecipient.toLowerCase() !== forfeitureRecipient.toLowerCase()) {
    throw new Error('Recorded plan differs from the selected treasury; do not reuse an old deployment plan');
  }
  if (!ctx.state.plan) {
    const initialYThorRewardWeightBps = Number(process.env.BASE_QA_YTHOR_REWARD_WEIGHT_BPS || 20000);
    if (!Number.isSafeInteger(initialYThorRewardWeightBps) || initialYThorRewardWeightBps < 0) {
      throw new Error('A valid initial reward weight is required');
    }
    const parsedRatio = ethers.utils.parseEther(qaConversionRatio);
    ctx.state.plan = {
      migrationStartTime: null,
      migrationStartMode: 'near_future',
      migrationStartDelaySeconds: qaMigrationStartDelaySeconds,
      migrationWindowSeconds: qaMigrationWindowSeconds,
      deadlineThor: null,
      deadlineYThor: null,
      capThor: ethers.utils.parseEther('1000000').toString(),
      capYThor: ethers.utils.parseEther('1000000').toString(),
      ratioThor: parsedRatio.toString(),
      ratioYThor: parsedRatio.toString(),
      forfeitureRecipient,
      distributorTreasury: process.env.BASE_QA_DISTRIBUTOR_TREASURY
        ? requireAddress('BASE_QA_DISTRIBUTOR_TREASURY') : forfeitureRecipient,
      polVault: requireAddress('BASE_QA_POL_VAULT'),
      forwarderDripRate: process.env.BASE_QA_FORWARDER_DRIP_RATE || ethers.utils.parseUnits('1000', 6).toString(),
      forwarderDripPeriod: Number(process.env.BASE_QA_FORWARDER_DRIP_PERIOD || 60),
      forwarderMaxReserve: process.env.BASE_QA_FORWARDER_MAX_RESERVE || ethers.utils.parseUnits('10000', 6).toString(),
      forwarderFunding: ethers.utils.parseUnits('50000', 6).toString(),
      initialYThorRewardWeightBps
    };
    if (ctx.state.plan.forwarderDripRate !== '0' && !(ctx.state.plan.forwarderDripPeriod > 0)) {
      throw new Error('A nonzero forwarder drip rate needs a positive drip period');
    }
    await ctx.persist();
  }
  const plan = ctx.state.plan;
  const expectedRatio = ethers.utils.parseEther(qaConversionRatio).toString();
  if (plan.migrationStartMode !== 'near_future' || plan.migrationWindowSeconds !== qaMigrationWindowSeconds ||
      plan.ratioThor !== expectedRatio || plan.ratioYThor !== expectedRatio ||
      (plan.deadlineThor !== null && plan.deadlineThor !== plan.migrationStartTime + qaMigrationWindowSeconds) ||
      (plan.deadlineYThor !== null && plan.deadlineYThor !== plan.migrationStartTime + qaMigrationWindowSeconds)) {
    throw new Error('Recorded testbed migration plan does not match the approved 30-day specification');
  }
}
function maskImmutables(code, immutableReferences) {
  const bytes = ethers.utils.arrayify(code);
  for (const ranges of Object.values(immutableReferences)) {
    for (const { start, length } of ranges) bytes.fill(0, start, start + length);
  }
  return ethers.utils.hexlify(bytes);
}
async function readBackTimers() {
  const expected = qaConfig.timeConstantsSeconds;
  const core = await contract('xMETRO', c('Core'));
  const publicTimers = {
    UNSTAKE_DELAY: expected.unstakeDelay,
    YTHOR_EXIT_RAMP: expected.yThorExitRamp,
    CONTRIBUTOR_CLIFF: expected.contributorCliff,
    CONTRIBUTOR_DURATION: expected.contributorDuration
  };
  const actual = {};
  for (const name of Object.keys(publicTimers)) actual[name] = Number(await core[name]());
  const { deployedBytecode } = await readArtifact('xMETRO');
  const runtimeMatchesShortTimerBuild =
    maskImmutables(await ctx.provider.getCode(c('Core')), deployedBytecode.immutableReferences) ===
    maskImmutables(deployedBytecode.object, deployedBytecode.immutableReferences);
  await recordReadbacks('timers', { expected, actual, runtimeMatchesShortTimerBuild });
  for (const [name, value] of Object.entries(publicTimers)) {
    if (actual[name] !== value) throw new Error(`Timer ${name} is ${actual[name]}, expected ${value}`);
  }
  if (!runtimeMatchesShortTimerBuild) {
    throw new Error('Core runtime code differs from the short-timer build; library timers are not verified');
  }
}
async function coreStage() {
  const plan = ctx.state.plan;
  await deploy('METRO', 'MetroToken', ['METRO', 'METRO', addr.deployer]);
  await deploy('Core', 'xMETRO', [
    addr.deployer, c('METRO'), c('TestUSDC'), plan.forfeitureRecipient, plan.initialYThorRewardWeightBps
  ]);
  await readBackTimers();
  await deploy('AdapterImplementation', 'XMetroDeFiAdapter', []);
  const impl = await contract('XMetroDeFiAdapter', c('AdapterImplementation'));
  const initData = impl.interface.encodeFunctionData('initialize', [c('Core'), c('TestUSDC'), c('METRO')]);
  await deploy('AdapterProxy', 'ERC1967Proxy', [c('AdapterImplementation'), initData]);
  await deploy('Distributor', 'MetroDistributorV1', [c('Core'), plan.distributorTreasury, plan.polVault, addr.deployer]);
  await deploy('Forwarder', 'RateLimitedForwarder', [
    c('TestUSDC'), c('Distributor'), addr.deployer,
    plan.forwarderDripRate, plan.forwarderDripPeriod, plan.forwarderMaxReserve
  ]);
  if (!ctx.state.steps.Escrow) {
    plan.migrationStartTime = (await ctx.provider.getBlock('latest')).timestamp + plan.migrationStartDelaySeconds;
    plan.deadlineThor = plan.migrationStartTime + plan.migrationWindowSeconds;
    plan.deadlineYThor = plan.deadlineThor;
    await ctx.persist();
  }
  await deploy('Escrow', 'ThorMigrationEscrow', [
    addr.deployer, c('Core'), c('TestTHOR'), c('TestYTHOR'), plan.migrationStartTime
  ]);
  const escrow = await contract('ThorMigrationEscrow', c('Escrow'));
  if (Number(await escrow.migrationStartTime()) !== plan.migrationStartTime) throw new Error('Escrow migration start mismatch');
  await deploy('Vault', 'CommissionVault', [
    c('TestUSDC'), c('Distributor'), addr.rewardOperator, addr.owner,
    1000000000, 1000000000, false, 3600, 3600
  ]);
  const core = await contract('xMETRO', c('Core'));
  const distributor = await contract('MetroDistributorV1', c('Distributor'));
  const forwarder = await contract('RateLimitedForwarder', c('Forwarder'));
  const vault = await contract('CommissionVault', c('Vault'));
  const same = (a, b) => a.toLowerCase() === b.toLowerCase();
  if (await core.paused()) throw new Error('Core must deploy unpaused');
  if (!same(await core.rewardToken(), c('TestUSDC'))) throw new Error('Core rewardToken mismatch');
  if (!same(await core.forfeitureRecipient(), plan.forfeitureRecipient)) throw new Error('Core forfeiture recipient mismatch');
  if (!same(await core.migrationRewardExcludedAddress(), plan.forfeitureRecipient)) {
    throw new Error('Core migration reward exclusion address mismatch');
  }
  if (!same(await distributor.treasury(), plan.distributorTreasury) || !same(await distributor.polVault(), plan.polVault)) {
    throw new Error('Distributor treasury or POL vault mismatch');
  }
  if (!same(await forwarder.token(), c('TestUSDC')) || !same(await forwarder.recipient(), c('Distributor'))) {
    throw new Error('Forwarder token or recipient mismatch');
  }
  if (!same(await vault.usdc(), c('TestUSDC'))) throw new Error('Vault USDC mismatch');
  if (!same(await vault.distributor(), c('Distributor'))) throw new Error('Vault Distributor mismatch');
  if (!(await vault.migrationFinalized())) throw new Error('Vault migration is not finalized');
  await recordReadbacks('core-deployed', {
    contracts: ctx.state.contracts,
    corePaused: await core.paused(), coreOwner: await core.owner(),
    rewardToken: await core.rewardToken(), metro: await core.METRO(),
    migrationRewardExcludedAddress: await core.migrationRewardExcludedAddress(),
    distributorTreasury: await distributor.treasury(), distributorPolVault: await distributor.polVault(),
    forwarderToken: await forwarder.token(), forwarderRecipient: await forwarder.recipient(),
    forwarderDripRate: await forwarder.dripRate(), forwarderDripPeriod: await forwarder.dripPeriod(),
    forwarderMaxReserve: await forwarder.maxReserve(),
    vaultUSDC: await vault.usdc(), vaultDistributor: await vault.distributor(),
    vaultMigrationFinalized: await vault.migrationFinalized(), plan
  });
}
async function configStage() {
  for (const [name, address] of [['V2', v2], ['V3', v3], ['1inch', oneInch]]) {
    if ((await ctx.provider.getCode(address)) === '0x') throw new Error(name + ' router has no code');
  }
  await call('metro-minter-core', 'MetroToken', 'METRO', 'setMinter', [c('Core'), true]);
  await call('metro-minter-deployer', 'MetroToken', 'METRO', 'setMinter', [addr.deployer, true]);
  await call('core-bind-adapter', 'xMETRO', 'Core', 'setDeFiAdapter', [c('AdapterProxy')]);
  await call('adapter-routers', 'XMetroDeFiAdapter', 'AdapterProxy', 'setRouters', [v2, v3, oneInch]);
  await call('adapter-swap-metro', 'XMetroDeFiAdapter', 'AdapterProxy', 'setSwapMetroConfig', [true, true]);
  for (const id of ['TestUSDT', 'TestWBTC', 'TestGHO', 'TestXAUT', 'TestSyrupUSDC']) {
    await call('adapter-swap-' + id, 'XMetroDeFiAdapter', 'AdapterProxy', 'setSwapTokenConfig', [c(id), true, true]);
  }
  await call('adapter-aave-v3', 'XMetroDeFiAdapter', 'AdapterProxy', 'setAaveV3Config',
    [c('MockAaveV3Pool'), c('MockScaledAToken'), 17, true, true]);
  await call('v4-activate-giver', 'MockAaveV4Spoke', 'MockAaveV4Spoke', 'updatePositionManager',
    [c('MockAaveV4Giver'), true]);
  await call('adapter-aave-v4', 'XMetroDeFiAdapter', 'AdapterProxy', 'setAaveV4Config',
    [c('MockAaveV4Spoke'), c('MockAaveV4Giver'), 7, true, true]);
  await call('adapter-maple', 'XMetroDeFiAdapter', 'AdapterProxy', 'setMapleConfig',
    [c('MockSyrupRouter'), ethers.utils.formatBytes32String('0:xMETRO'), true, true]);
  const deposit = ethers.utils.formatBytes32String('P:deposit');
  const transfer = ethers.utils.formatBytes32String('P:transfer');
  const transferFrom = ethers.utils.formatBytes32String('P:transferFrom');
  for (const [key, value, bitmap] of [['deposit', deposit, 16], ['transfer', transfer, 0], ['transferFrom', transferFrom, 0]]) {
    await call('maple-bitmap-' + key, 'MockPoolPermissionManager', 'MockPoolPermissionManager',
      'setPoolBitmap', [c('MockSyrupRouter'), value, bitmap]);
  }
  await call('maple-lender-bitmap', 'MockPoolPermissionManager', 'MockPoolPermissionManager',
    'setLenderBitmap', [c('MockSyrupRouter'), 16]);
  const qaUsers = publicWallets.accounts.filter(x => /^user\d+$/.test(x.role)).map(x => x.address);
  await call('maple-user-bitmaps', 'MockPoolPermissionManager', 'MockPoolPermissionManager',
    'setLenderBitmaps', [qaUsers, qaUsers.map(() => 16)]);
  await call('distributor-forwarder', 'MetroDistributorV1', 'Distributor', 'setForwarder', [c('Forwarder')]);
  await call('distributor-operator', 'MetroDistributorV1', 'Distributor', 'setOperator', [addr.rewardOperator, true]);
  await call('distributor-vault', 'MetroDistributorV1', 'Distributor', 'setCommissionVault', [c('Vault')]);
  await call('forwarder-unpause', 'RateLimitedForwarder', 'Forwarder', 'unpause', []);
  await call('core-bind-distributor', 'xMETRO', 'Core', 'setRewardDistributor', [c('Distributor')]);
  await call('core-keeper', 'xMETRO', 'Core', 'setAutoCompoundOperator', [addr.keeper, true]);
  await call('core-contributor', 'xMETRO', 'Core', 'setContributor', [addr.user10, true]);
  await call('escrow-caps', 'ThorMigrationEscrow', 'Escrow', 'setCaps',
    [ctx.state.plan.capThor, ctx.state.plan.capYThor]);
  await call('escrow-ratios', 'ThorMigrationEscrow', 'Escrow', 'setRatios',
    [ctx.state.plan.ratioThor, ctx.state.plan.ratioYThor]);
  await call('escrow-deadlines', 'ThorMigrationEscrow', 'Escrow', 'setDeadlines',
    [ctx.state.plan.deadlineThor, ctx.state.plan.deadlineYThor]);
  await call('core-bind-escrow', 'xMETRO', 'Core', 'setMigrationEscrow', [c('Escrow')]);
  const core = await contract('xMETRO', c('Core'));
  const adapter = await contract('XMetroDeFiAdapter', c('AdapterProxy'));
  const distributor = await contract('MetroDistributorV1', c('Distributor'));
  const forwarder = await contract('RateLimitedForwarder', c('Forwarder'));
  const escrow = await contract('ThorMigrationEscrow', c('Escrow'));
  if (await core.paused()) throw new Error('Core unexpectedly paused during configuration');
  if ((await core.deFiAdapter()).toLowerCase() !== c('AdapterProxy').toLowerCase()) throw new Error('Core Adapter binding mismatch');
  if ((await core.rewardDistributor()).toLowerCase() !== c('Distributor').toLowerCase()) throw new Error('Core Distributor binding mismatch');
  if ((await distributor.commissionVault()).toLowerCase() !== c('Vault').toLowerCase() ||
      Number(await distributor.maxCommissionSplitBps()) !== 0) throw new Error('Initial commission routing mismatch');
  if ((await distributor.forwarder()).toLowerCase() !== c('Forwarder').toLowerCase() ||
      (await forwarder.recipient()).toLowerCase() !== c('Distributor').toLowerCase() || await forwarder.paused()) {
    throw new Error('Forwarder binding mismatch or forwarder still paused');
  }
  if ((await core.migrationEscrow()).toLowerCase() !== c('Escrow').toLowerCase()) throw new Error('Core Escrow binding mismatch');
  if (!(await escrow.ratioThor()).eq(ctx.state.plan.ratioThor) ||
      !(await escrow.ratioYThor()).eq(ctx.state.plan.ratioYThor) ||
      Number(await escrow.deadlineThor()) !== ctx.state.plan.deadlineThor ||
      Number(await escrow.deadlineYThor()) !== ctx.state.plan.deadlineYThor) {
    throw new Error('On-chain migration ratios or deadlines differ from the approved Base QA plan');
  }
  if ((await adapter.aaveV4Giver()).toLowerCase() !== c('MockAaveV4Giver').toLowerCase()) throw new Error('V4 Giver configuration mismatch');
  if (!(await (await contract('MockAaveV4Spoke', c('MockAaveV4Spoke'))).activeManagers(c('MockAaveV4Giver')))) {
    throw new Error('Mock Giver is not active');
  }
  await recordReadbacks('configured', {
    corePaused: await core.paused(), coreAdapter: await core.deFiAdapter(),
    coreDistributor: await core.rewardDistributor(), coreEscrow: await core.migrationEscrow(),
    commissionVault: await distributor.commissionVault(),
    maxCommissionSplitBps: await distributor.maxCommissionSplitBps(),
    distributorForwarder: await distributor.forwarder(), forwarderRecipient: await forwarder.recipient(),
    forwarderPaused: await forwarder.paused(),
    adapterConfiguration: await adapter.configuration(),
    aaveV4Giver: await adapter.aaveV4Giver(),
    escrowStartTime: await escrow.migrationStartTime(),
    escrowDeadlineThor: await escrow.deadlineThor(),
    escrowDeadlineYThor: await escrow.deadlineYThor()
  });
}
async function seedStage() {
  const tokenMints = [
    ['TestUSDC', '100000', 6], ['TestTHOR', '10000', 18], ['TestYTHOR', '10000', 18],
    ['TestUSDT', '10000', 6], ['TestWBTC', '10000', 8], ['TestGHO', '10000', 18],
    ['TestXAUT', '10000', 6], ['TestExtraToken', '10000', 18]
  ];
  for (const [id, amount, decimals] of tokenMints) {
    await call('mint-' + id, 'ERC20Mintable', id, 'mint', [addr.deployer, ethers.utils.parseUnits(amount, decimals)]);
  }
  await call('mint-TestSyrupUSDC', 'MockSyrupUSDC', 'TestSyrupUSDC', 'mint',
    [addr.deployer, ethers.utils.parseUnits('10000', 6)]);
  await call('mint-METRO', 'MetroToken', 'METRO', 'mint',
    [addr.deployer, ethers.utils.parseEther('10000')]);
  await call('mint-TestUSDC-Forwarder', 'ERC20Mintable', 'TestUSDC', 'mint', [c('Forwarder'), ctx.state.plan.forwarderFunding]);
  const metro = await contract('MetroToken', c('METRO'));
  const usdc = await contract('ERC20Mintable', c('TestUSDC'));
  if (!(await metro.totalSupply()).eq(ethers.utils.parseEther('10000'))) throw new Error('Initial METRO supply mismatch');
  await recordReadbacks('seed', { metroTotalSupply: await metro.totalSupply(),
    usdcDeployerBalance: await usdc.balanceOf(addr.deployer), usdcForwarderBalance: await usdc.balanceOf(c('Forwarder')) });
}
async function ownershipStage() {
  const core = await contract('xMETRO', c('Core'));
  const ownedContracts = [
    ['METRO', 'MetroToken'], ['Core', 'xMETRO'], ['Distributor', 'MetroDistributorV1'],
    ['Forwarder', 'RateLimitedForwarder'],
    ['Escrow', 'ThorMigrationEscrow'], ['TestSyrupUSDC', 'MockSyrupUSDC'],
    ['MockAaveV3Pool', 'MockAaveV3Pool'], ['MockAaveV4Spoke', 'MockAaveV4Spoke'],
    ['MockAaveV4Giver', 'MockAaveV4Giver'],
    ['MockPoolPermissionManager', 'MockPoolPermissionManager'], ['MockSyrupRouter', 'MockSyrupRouter'],
    ...['TestUSDC', 'TestTHOR', 'TestYTHOR', 'TestUSDT', 'TestWBTC', 'TestGHO', 'TestXAUT', 'TestExtraToken']
      .map(id => [id, 'ERC20Mintable'])
  ];
  const pendingOwners = {};
  for (const [id, artifact] of ownedContracts) {
    if (['METRO', 'Core', 'Escrow', 'Distributor', 'Forwarder'].includes(id)) {
      pendingOwners[id] = await (await contract(artifact, c(id))).pendingOwner();
      if (pendingOwners[id] !== ethers.constants.AddressZero) throw new Error('Unexpected pending owner: ' + id);
    }
    const owner = await (await contract(artifact, c(id))).owner();
    if (owner.toLowerCase() !== addr.deployer.toLowerCase()) throw new Error('Unexpected owner: ' + id);
  }
  const vault = await contract('CommissionVault', c('Vault'));
  if ((await vault.owner()).toLowerCase() !== addr.deployer.toLowerCase()) throw new Error('Unexpected Vault owner');
  if ((await vault.operator()).toLowerCase() !== addr.rewardOperator.toLowerCase()) throw new Error('Unexpected Vault operator');
  if ((await vault.guardian()).toLowerCase() !== addr.owner.toLowerCase()) throw new Error('Unexpected Vault guardian');
  if (await core.paused()) throw new Error('Core unexpectedly paused');
  await recordReadbacks('ownership', {
    corePendingOwner: pendingOwners.Core, escrowPendingOwner: pendingOwners.Escrow,
    distributorPendingOwner: pendingOwners.Distributor, forwarderPendingOwner: pendingOwners.Forwarder,
    metroPendingOwner: pendingOwners.METRO,
    pendingProjectHandover: true, coreOwner: await core.owner(), corePaused: await core.paused(),
    metroOwner: await (await contract('MetroToken', c('METRO'))).owner(),
    escrowOwner: await (await contract('ThorMigrationEscrow', c('Escrow'))).owner(),
    distributorOwner: await (await contract('MetroDistributorV1', c('Distributor'))).owner(),
    forwarderOwner: await (await contract('RateLimitedForwarder', c('Forwarder'))).owner(),
    vaultOwner: await vault.owner(), vaultOperator: await vault.operator(), vaultGuardian: await vault.guardian(),
    ownedContracts: ownedContracts.map(([id]) => ({ id, address: c(id), owner: addr.deployer }))
  });
}

// Validate immutable and one-time configuration before the first transaction of a full run.
if (phase === 'all' || phase === 'core') await preparePlan();
for (const name of phases) {
  if (phase !== 'all' && phase !== name) continue;
  console.log('Stage', name);
  if (name === 'tokens') await tokenStage();
  if (name === 'mocks') await mockStage();
  if (name === 'core') await coreStage();
  if (name === 'config') await configStage();
  if (name === 'seed') await seedStage();
  if (name === 'ownership') await ownershipStage();
}
