// Deploy and configure Base QA in resumable, receipt-backed stages.
// Business contracts come from the separate long-duration QA build.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { ethers, root, runDir, readArtifact, openRun, sendStep } from './runner.mjs';

const artifacts = {
  ERC20Mintable: 'out-core/ERC20Mintable.sol/ERC20Mintable.json',
  MockSyrupUSDC: 'out-core/MockSyrupUSDC.sol/MockSyrupUSDC.json',
  MockAaveV3Pool: 'out-core/MockDepositProtocols.sol/MockAaveV3Pool.json',
  MockAaveV4Spoke: 'out-core/MockDepositProtocols.sol/MockAaveV4Spoke.json',
  MockAaveV4Giver: 'out-core/MockAaveV4Giver.sol/MockAaveV4Giver.json',
  MockPoolPermissionManager: 'out-core/MockDepositProtocols.sol/MockPoolPermissionManager.json',
  MockSyrupRouter: 'out-core/MockDepositProtocols.sol/MockSyrupRouter.json',
  MetroToken: 'out-deploy/metro.sol/MetroToken.json',
  xMETRO: 'out-deploy/xMETRO.sol/xMETRO.json',
  XMetroDeFiAdapter: 'out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json',
  ERC1967Proxy: 'out-deploy/ERC1967Proxy.sol/ERC1967Proxy.json',
  RewardDistributor: 'out-deploy/RewardDistributor.sol/RewardDistributor.json',
  ThorMigrationEscrow: 'out-deploy/ThorMigrationEscrow.sol/ThorMigrationEscrow.json',
  CommissionVault: 'out-fork-v2/CommissionVault.sol/CommissionVault.json'
};
const v2 = '0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24';
const v3 = '0x2626664c2603336E57B271c5C0b26F421741e481';
const oneInch = '0x111111125421ca6dc452d289314280a0f8842a65';
const zero = ethers.constants.AddressZero;
const qaConversionRatio = '0.3928569546';
const qaMigrationWindowSeconds = 30 * 24 * 60 * 60;
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
  const a = await readArtifact(artifacts[name]);
  return new ethers.Contract(address, a.abi, ctx.provider);
}
async function deploy(id, name, args) {
  const a = await readArtifact(artifacts[name]);
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
    chainId: 8453, blockNumber: block.number, blockHash: block.hash, blockTimestamp: block.timestamp, values
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
async function preparePlan() {
  if ((process.env.BASE_QA_MIGRATION_START_TIME && Number(process.env.BASE_QA_MIGRATION_START_TIME) !== 0) ||
      process.env.BASE_QA_DEADLINE_THOR || process.env.BASE_QA_DEADLINE_YTHOR ||
      (process.env.BASE_QA_RATIO_THOR && process.env.BASE_QA_RATIO_THOR !== qaConversionRatio) ||
      (process.env.BASE_QA_RATIO_YTHOR && process.env.BASE_QA_RATIO_YTHOR !== qaConversionRatio)) {
    throw new Error('Base QA starts at Escrow deployment; both deadlines are +30 days and both ratios are 0.3928569546');
  }
  if (!ctx.state.plan) {
    const forfeitureRecipient = process.env.BASE_QA_FORFEITURE_RECIPIENT || addr.deployer;
    const initialYThorRewardWeightBps = Number(process.env.BASE_QA_YTHOR_REWARD_WEIGHT_BPS || 20000);
    if (!Number.isSafeInteger(initialYThorRewardWeightBps) || initialYThorRewardWeightBps < 0 ||
        !ethers.utils.isAddress(forfeitureRecipient) || forfeitureRecipient === zero) {
      throw new Error('A valid initial reward weight and nonzero forfeiture recipient are required');
    }
    const parsedRatio = ethers.utils.parseEther(qaConversionRatio);
    ctx.state.plan = {
      migrationStartTime: 0,
      migrationStartMode: 'deployment_block',
      migrationWindowSeconds: qaMigrationWindowSeconds,
      deadlineThor: null,
      deadlineYThor: null,
      capThor: ethers.utils.parseEther('1000000').toString(),
      capYThor: ethers.utils.parseEther('1000000').toString(),
      ratioThor: parsedRatio.toString(),
      ratioYThor: parsedRatio.toString(),
      forfeitureRecipient: ethers.utils.getAddress(forfeitureRecipient),
      initialYThorRewardWeightBps
    };
    await ctx.persist();
  }
  const plan = ctx.state.plan;
  const expectedRatio = ethers.utils.parseEther(qaConversionRatio).toString();
  if (plan.migrationStartMode !== 'deployment_block' || plan.migrationWindowSeconds !== qaMigrationWindowSeconds ||
      plan.ratioThor !== expectedRatio || plan.ratioYThor !== expectedRatio ||
      (plan.deadlineThor !== null && plan.deadlineThor !== plan.migrationStartTime + qaMigrationWindowSeconds) ||
      (plan.deadlineYThor !== null && plan.deadlineYThor !== plan.migrationStartTime + qaMigrationWindowSeconds)) {
    throw new Error('Recorded Base QA migration plan does not match the approved 30-day specification');
  }
}
async function coreStage() {
  await deploy('METRO', 'MetroToken', ['METRO', 'METRO', addr.deployer]);
  await deploy('Core', 'xMETRO', [
    addr.deployer, c('METRO'), c('TestUSDC'), ctx.state.plan.forfeitureRecipient,
    ctx.state.plan.initialYThorRewardWeightBps
  ]);
  await deploy('AdapterImplementation', 'XMetroDeFiAdapter', []);
  const impl = await contract('XMetroDeFiAdapter', c('AdapterImplementation'));
  const initData = impl.interface.encodeFunctionData('initialize', [c('Core'), c('TestUSDC'), c('METRO')]);
  await deploy('AdapterProxy', 'ERC1967Proxy', [c('AdapterImplementation'), initData]);
  await deploy('Distributor', 'RewardDistributor', [c('Core'), addr.deployer]);
  await deploy('Escrow', 'ThorMigrationEscrow', [
    addr.deployer, c('Core'), c('TestTHOR'), c('TestYTHOR'),
    ctx.state.plan.migrationStartMode === 'deployment_block' ? 0 : ctx.state.plan.migrationStartTime
  ]);
  const escrow = await contract('ThorMigrationEscrow', c('Escrow'));
  const actualMigrationStartTime = Number(await escrow.migrationStartTime());
  if (ctx.state.plan.migrationStartMode === 'scheduled' && actualMigrationStartTime !== ctx.state.plan.migrationStartTime) {
    throw new Error('Escrow migration start mismatch');
  }
  if (ctx.state.plan.migrationStartMode === 'deployment_block') {
    if (actualMigrationStartTime !== ctx.state.steps.Escrow.blockTimestamp) {
      throw new Error('Escrow did not start at its deployment timestamp');
    }
    const actualDeadline = actualMigrationStartTime + ctx.state.plan.migrationWindowSeconds;
    if ((ctx.state.plan.deadlineThor !== null && ctx.state.plan.deadlineThor !== actualDeadline) ||
        (ctx.state.plan.deadlineYThor !== null && ctx.state.plan.deadlineYThor !== actualDeadline)) {
      throw new Error('Recorded migration deadlines do not match Escrow deployment time');
    }
    ctx.state.plan.migrationStartTime = actualMigrationStartTime;
    ctx.state.plan.deadlineThor = actualDeadline;
    ctx.state.plan.deadlineYThor = actualDeadline;
    await ctx.persist();
  }
  if (ctx.state.plan.deadlineThor <= actualMigrationStartTime ||
      ctx.state.plan.deadlineYThor <= actualMigrationStartTime) {
    throw new Error('Migration deadline elapsed before Escrow deployment');
  }
  await deploy('Vault', 'CommissionVault', [
    c('TestUSDC'), c('Distributor'), addr.rewardOperator, addr.owner,
    1000000000, 1000000000, false, 3600, 3600
  ]);
  const core = await contract('xMETRO', c('Core'));
  const vault = await contract('CommissionVault', c('Vault'));
  if (await core.paused()) throw new Error('Core must deploy unpaused');
  if ((await core.rewardToken()).toLowerCase() !== c('TestUSDC').toLowerCase()) throw new Error('Core rewardToken mismatch');
  if ((await core.forfeitureRecipient()).toLowerCase() !== ctx.state.plan.forfeitureRecipient.toLowerCase()) {
    throw new Error('Core forfeiture recipient mismatch');
  }
  if ((await vault.usdc()).toLowerCase() !== c('TestUSDC').toLowerCase()) throw new Error('Vault USDC mismatch');
  if ((await vault.distributor()).toLowerCase() !== c('Distributor').toLowerCase()) throw new Error('Vault Distributor mismatch');
  if (!(await vault.migrationFinalized())) throw new Error('Vault migration is not finalized');
  await recordReadbacks('core-deployed', {
    contracts: ctx.state.contracts,
    corePaused: await core.paused(), coreOwner: await core.owner(),
    rewardToken: await core.rewardToken(), metro: await core.METRO(),
    vaultUSDC: await vault.usdc(), vaultDistributor: await vault.distributor(),
    vaultMigrationFinalized: await vault.migrationFinalized(), plan: ctx.state.plan
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
  await call('distributor-operator', 'RewardDistributor', 'Distributor', 'setOperator', [addr.rewardOperator, true]);
  await call('distributor-vault', 'RewardDistributor', 'Distributor', 'setCommissionVault', [c('Vault')]);
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
  const distributor = await contract('RewardDistributor', c('Distributor'));
  const escrow = await contract('ThorMigrationEscrow', c('Escrow'));
  if (await core.paused()) throw new Error('Core unexpectedly paused during configuration');
  if ((await core.deFiAdapter()).toLowerCase() !== c('AdapterProxy').toLowerCase()) throw new Error('Core Adapter binding mismatch');
  if ((await core.rewardDistributor()).toLowerCase() !== c('Distributor').toLowerCase()) throw new Error('Core Distributor binding mismatch');
  if ((await distributor.commissionVault()).toLowerCase() !== c('Vault').toLowerCase() ||
      Number(await distributor.maxCommissionSplitBps()) !== 0) throw new Error('Initial commission routing mismatch');
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
  const metro = await contract('MetroToken', c('METRO'));
  if (!(await metro.totalSupply()).eq(ethers.utils.parseEther('10000'))) throw new Error('Initial METRO supply mismatch');
  await recordReadbacks('seed', { metroTotalSupply: await metro.totalSupply(),
    usdcDeployerBalance: await (await contract('ERC20Mintable', c('TestUSDC'))).balanceOf(addr.deployer) });
}
async function ownershipStage() {
  const core = await contract('xMETRO', c('Core'));
  const ownedContracts = [
    ['METRO', 'MetroToken'], ['Core', 'xMETRO'], ['Distributor', 'RewardDistributor'],
    ['Escrow', 'ThorMigrationEscrow'], ['TestSyrupUSDC', 'MockSyrupUSDC'],
    ['MockAaveV3Pool', 'MockAaveV3Pool'], ['MockAaveV4Spoke', 'MockAaveV4Spoke'],
    ['MockAaveV4Giver', 'MockAaveV4Giver'],
    ['MockPoolPermissionManager', 'MockPoolPermissionManager'], ['MockSyrupRouter', 'MockSyrupRouter'],
    ...['TestUSDC', 'TestTHOR', 'TestYTHOR', 'TestUSDT', 'TestWBTC', 'TestGHO', 'TestXAUT', 'TestExtraToken']
      .map(id => [id, 'ERC20Mintable'])
  ];
  for (const [id, artifact] of ownedContracts) {
    const owner = await (await contract(artifact, c(id))).owner();
    if (owner.toLowerCase() !== addr.deployer.toLowerCase()) throw new Error('Unexpected owner: ' + id);
  }
  const vault = await contract('CommissionVault', c('Vault'));
  if ((await vault.owner()).toLowerCase() !== addr.deployer.toLowerCase()) throw new Error('Unexpected Vault owner');
  if ((await vault.operator()).toLowerCase() !== addr.rewardOperator.toLowerCase()) throw new Error('Unexpected Vault operator');
  if ((await vault.guardian()).toLowerCase() !== addr.owner.toLowerCase()) throw new Error('Unexpected Vault guardian');
  if (await core.paused()) throw new Error('Core unexpectedly paused');
  await recordReadbacks('ownership', {
    pendingProjectHandover: true, coreOwner: await core.owner(), corePaused: await core.paused(),
    metroOwner: await (await contract('MetroToken', c('METRO'))).owner(),
    escrowOwner: await (await contract('ThorMigrationEscrow', c('Escrow'))).owner(),
    distributorOwner: await (await contract('RewardDistributor', c('Distributor'))).owner(),
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
