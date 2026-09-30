// Read-only Base QA preflight: no signer material is loaded and no transaction is broadcast.
import { createHash } from 'node:crypto';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { ethers } = require('ethers');
const root = fileURLToPath(new URL('../../', import.meta.url));
const rpc = process.env.BASE_RPC_URL || 'https://mainnet.base.org';
const provider = new ethers.providers.StaticJsonRpcProvider(rpc, 8453);
const publicWallets = JSON.parse(await readFile(path.join(root, 'integration/testing/base/wallets.json')));
const deployer = publicWallets.accounts.find(x => x.role === 'deployer')?.address;
if (!deployer) throw new Error('Missing deployer public address');
const router = '0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24';
const factory = '0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6';
const gasPriceOracle = '0x420000000000000000000000000000000000000F';
const placeholder = deployer;
const runId = process.env.BASE_QA_RUN_ID || 'base-qa-project-20260930';
if (!/^[a-z0-9][a-z0-9-]{4,80}$/.test(runId)) throw new Error('Invalid BASE_QA_RUN_ID');
const localRehearsal = process.env.BASE_QA_LOCAL_REHEARSAL === '1';
const runDir = path.join(root, 'integration/testing/base/evidence', localRehearsal ? `local-${runId}` : runId);
const gpoInterface = new ethers.utils.Interface(['function getL1Fee(bytes) view returns (uint256)']);
const routerInterface = new ethers.utils.Interface(['function factory() view returns (address)']);
const factoryInterface = new ethers.utils.Interface([
  'function getPair(address,address) view returns (address)',
  'function createPair(address,address) returns (address)'
]);
const ephemeral = ethers.Wallet.createRandom(); // Used only to serialize fee estimates, never on-chain.

const artifactPaths = {
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
const specs = [
  ['TestUSDC', 'ERC20Mintable', ['Test USDC', 'TestUSDC', 6]],
  ['TestTHOR', 'ERC20Mintable', ['Test THOR', 'TestTHOR', 18]],
  ['TestYTHOR', 'ERC20Mintable', ['Test yTHOR', 'TestYTHOR', 18]],
  ['TestUSDT', 'ERC20Mintable', ['Test USDT', 'TestUSDT', 6]],
  ['TestWBTC', 'ERC20Mintable', ['Test WBTC', 'TestWBTC', 8]],
  ['TestGHO', 'ERC20Mintable', ['Test GHO', 'TestGHO', 18]],
  ['TestXAUT', 'ERC20Mintable', ['Test XAUT', 'TestXAUT', 6]],
  ['TestExtraToken', 'ERC20Mintable', ['Test Extra Token', 'TestExtraToken', 18]],
  ['TestSyrupUSDC', 'MockSyrupUSDC', [placeholder]],
  ['MockAaveV3Pool', 'MockAaveV3Pool', [placeholder, ethers.BigNumber.from(10).pow(27)]],
  ['MockAaveV4Spoke', 'MockAaveV4Spoke', [placeholder, 0]],
  ['MockAaveV4Giver', 'MockAaveV4Giver', [placeholder]],
  ['MockPoolPermissionManager', 'MockPoolPermissionManager', []],
  ['METRO', 'MetroToken', ['METRO', 'METRO', deployer]],
  ['QA Core', 'xMETRO', [deployer, placeholder, placeholder, placeholder, 10000]],
  ['Adapter Implementation', 'XMetroDeFiAdapter', []],
  ['RewardDistributor', 'RewardDistributor', [placeholder, deployer]],
  ['ThorMigrationEscrow', 'ThorMigrationEscrow', [deployer, placeholder, placeholder, placeholder, Math.floor(Date.now() / 1000) + 3600]],
  ['CommissionVault', 'CommissionVault', [placeholder, placeholder, deployer, deployer, 1000000000, 1000000000, false, 3600, 3600]],
  ['Adapter Proxy', 'ERC1967Proxy', [placeholder, '0x']],
  ['MockSyrupRouter', 'MockSyrupRouter', [placeholder, placeholder, placeholder, deployer]]
];

function hexBig(value) { return BigInt(value).toString(); }
function feeEth(value) { return ethers.utils.formatEther(value.toString()); }
async function l1Fee(tx) {
  try {
    const signed = await ephemeral.signTransaction({
      chainId: 8453, nonce: 0, type: 2, gasLimit: 12000000,
      maxPriorityFeePerGas: 1000000, maxFeePerGas: 12000000,
      value: 0, ...tx
    });
    const result = await provider.call({
      to: gasPriceOracle,
      data: gpoInterface.encodeFunctionData('getL1Fee', [signed])
    });
    return gpoInterface.decodeFunctionResult('getL1Fee', result)[0].toString();
  } catch (error) {
    return null;
  }
}
async function rpcCall(method, params) { return provider.send(method, params); }
async function quote(data, to, gasPrice) {
  const tx = { from: deployer, data, ...(to ? { to } : {}) };
  const l1Wei = await l1Fee({ data, ...(to ? { to } : {}) });
  try {
    const gas = BigInt(await rpcCall('eth_estimateGas', [tx]));
    const executionWei = gas * gasPrice;
    return {
      gas: gas.toString(), executionWei: executionWei.toString(), l1Wei,
      totalWei: l1Wei === null ? null : (executionWei + BigInt(l1Wei)).toString()
    };
  } catch (error) {
    return { gas: null, l1Wei, status: 'dependency_or_rpc_error', errorCode: error.code || 'unknown' };
  }
}

await mkdir(runDir, { recursive: true });
const chainId = Number(await rpcCall('eth_chainId', []));
if (chainId !== 8453) throw new Error('RPC is not Base mainnet');
const [block, balanceHex, nonceHex, pendingNonceHex, gasPriceHex, routerCode, factoryCode, oracleCode] =
  await Promise.all([
    rpcCall('eth_getBlockByNumber', ['latest', false]),
    rpcCall('eth_getBalance', [deployer, 'latest']),
    rpcCall('eth_getTransactionCount', [deployer, 'latest']),
    rpcCall('eth_getTransactionCount', [deployer, 'pending']),
    rpcCall('eth_gasPrice', []),
    rpcCall('eth_getCode', [router, 'latest']),
    rpcCall('eth_getCode', [factory, 'latest']),
    rpcCall('eth_getCode', [gasPriceOracle, 'latest'])
  ]);
const gasPrice = BigInt(gasPriceHex);
const routerFactoryRaw = await provider.call({ to: router, data: routerInterface.encodeFunctionData('factory') });
const routerFactory = routerInterface.decodeFunctionResult('factory', routerFactoryRaw)[0];
if (routerFactory.toLowerCase() !== factory.toLowerCase() || routerCode === '0x' || factoryCode === '0x') {
  throw new Error('V2 Router/Factory relationship or code mismatch');
}
const artifacts = {};
for (const [name, relative] of Object.entries(artifactPaths)) {
  const bytes = await readFile(path.join(root, relative));
  const artifact = JSON.parse(bytes);
  artifacts[name] = {
    path: relative,
    artifactSha256: createHash('sha256').update(bytes).digest('hex'),
    initcodeKeccak256: ethers.utils.keccak256(artifact.bytecode.object),
    initcodeBytes: (artifact.bytecode.object.length - 2) / 2,
    runtimeBytes: (artifact.deployedBytecode.object.length - 2) / 2
  };
}
const sourceHashes = {};
for (const relative of [
  'src/metro.sol', 'src/xMETRO.sol', 'src/XMetroCoreLogic.sol', 'src/XMetroDeFiAdapter.sol',
  'src/RewardDistributor.sol', 'src/ThorMigrationEscrow.sol',
  'test/mocks/ERC20Mintable.sol', 'test/mocks/MockDepositProtocols.sol',
  'test/mocks/MockAaveV4Giver.sol', 'test/mocks/MockSyrupUSDC.sol',
  'test/fork-v2/mainnet/vendor/CommissionVault.sol',
  'test/fork-v2/mainnet/vendor/interfaces/ICommissionVault.sol'
]) {
  sourceHashes[relative] = createHash('sha256').update(await readFile(path.join(root, relative))).digest('hex');
}
const quotes = [];
for (const [label, name, args] of specs) {
  const artifact = JSON.parse(await readFile(path.join(root, artifactPaths[name])));
  const factoryContract = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object);
  const tx = factoryContract.getDeployTransaction(...args);
  quotes.push({ label, contract: name, ...await quote(tx.data, null, gasPrice) });
}
const tokenA = ethers.Wallet.createRandom().address;
const tokenB = ethers.Wallet.createRandom().address;
const pairRaw = await provider.call({ to: factory, data: factoryInterface.encodeFunctionData('getPair', [tokenA, tokenB]) });
const existingPair = factoryInterface.decodeFunctionResult('getPair', pairRaw)[0];
if (existingPair !== ethers.constants.AddressZero) throw new Error('Random estimation pair already exists');
const pairCreationQuote = await quote(factoryInterface.encodeFunctionData('createPair', [tokenA, tokenB]), factory, gasPrice);
const report = {
  recordedAt: new Date().toISOString(),
  rpcLabel: process.env.BASE_RPC_URL ? 'custom Base RPC (URL hidden)' : 'Base public RPC',
  chainId, blockNumber: Number(block.number), blockHash: block.hash, blockTimestamp: Number(block.timestamp),
  deployer, balanceWei: hexBig(balanceHex), balanceEth: feeEth(hexBig(balanceHex)),
  nonce: Number(nonceHex), pendingNonce: Number(pendingNonceHex),
  gasPriceWei: gasPrice.toString(), gasPriceGwei: ethers.utils.formatUnits(gasPrice.toString(), 'gwei'),
  v2: {
    router, factory, routerFactory,
    routerCodeHash: ethers.utils.keccak256(routerCode),
    factoryCodeHash: ethers.utils.keccak256(factoryCode),
    oracleCodeHash: ethers.utils.keccak256(oracleCode),
    pairCreationQuote
  },
  artifacts, sourceHashes, quotes
};
const file = path.join(runDir, 'preflight.json');
await writeFile(file, JSON.stringify(report, null, 2) + '\n', { mode: 0o644 });
const estimableWei = quotes.reduce((sum, x) => sum + BigInt(x.totalWei || 0), 0n);
const sevenPairsWei = BigInt(pairCreationQuote.totalWei || 0) * 7n;
console.log(JSON.stringify({
  evidence: file, chainId, blockNumber: report.blockNumber, balanceEth: report.balanceEth,
  nonce: report.nonce, gasPriceGwei: report.gasPriceGwei,
  v2RelationValid: true, estimatedDeploymentsEth: feeEth(estimableWei),
  sevenPairCreationsEth: feeEth(sevenPairsWei),
  subtotalKnownEth: feeEth(estimableWei + sevenPairsWei),
  unestimated: quotes.filter(x => !x.gas).map(x => x.label),
  pairCreationGas: pairCreationQuote.gas
}, null, 2));
