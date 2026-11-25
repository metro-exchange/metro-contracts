import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import {
  ethers, root, runDir, chainId, artifactPaths, preflightFile, readArtifact, verifyPreflight, sha256, readPublicWallets,
  testTokens, v2Router as router, v2Factory as factory, l1FeeOracle, l1FeeOracleInterface, rpcUrl
} from './runner.mjs';

const existing = await readFile(preflightFile).then(JSON.parse, error => {
  if (error.code === 'ENOENT') return null;
  throw error;
});
if (existing) {
  await verifyPreflight(existing);
  console.log('Reusing preflight of this run with unchanged sources and artifacts:', preflightFile);
  process.exit(0);
}
const provider = new ethers.providers.StaticJsonRpcProvider(rpcUrl, chainId);
const publicWallets = await readPublicWallets();
const deployer = publicWallets.accounts.find(x => x.role === 'deployer')?.address;
if (!deployer) throw new Error('Missing deployer public address');
const placeholder = deployer;
const routerInterface = new ethers.utils.Interface(['function factory() view returns (address)']);
const factoryInterface = new ethers.utils.Interface(['function createPair(address,address) returns (address)']);
const feeEstimateWallet = ethers.Wallet.createRandom();

const specs = [
  ...testTokens.map(([id, name, decimals]) => [id, 'ERC20Mintable', [name, id, decimals]]),
  ['TestSyrupUSDC', 'MockSyrupUSDC', [placeholder]],
  ['MockAaveV3Pool', 'MockAaveV3Pool', [placeholder, ethers.BigNumber.from(10).pow(27)]],
  ['MockAaveV4Spoke', 'MockAaveV4Spoke', [placeholder, 0]],
  ['MockAaveV4Giver', 'MockAaveV4Giver', [placeholder]],
  ['MockPoolPermissionManager', 'MockPoolPermissionManager', []],
  ['METRO', 'MetroToken', ['METRO', 'METRO', deployer]],
  ['QA Core', 'xMETRO', [deployer, placeholder, placeholder, placeholder, 10000]],
  ['Adapter Implementation', 'XMetroDeFiAdapter', []],
  ['MetroDistributorV1', 'MetroDistributorV1', [placeholder, placeholder, placeholder, deployer]],
  ['RateLimitedForwarder', 'RateLimitedForwarder', [placeholder, placeholder, deployer, 0, 0, 0]],
  ['ThorMigrationEscrow', 'ThorMigrationEscrow', [deployer, placeholder, placeholder, placeholder, Math.floor(Date.now() / 1000) + 3600]],
  ['CommissionVault', 'CommissionVault', [placeholder, placeholder, deployer, deployer, 1000000000, 1000000000, false, 3600, 3600]],
  ['Adapter Proxy', 'ERC1967Proxy', [placeholder, '0x']],
  ['MockSyrupRouter', 'MockSyrupRouter', [placeholder, placeholder, placeholder, deployer]]
];

function hexBig(value) { return BigInt(value).toString(); }
function feeEth(value) { return ethers.utils.formatEther(value.toString()); }
async function l1Fee(tx) {
  try {
    const signed = await feeEstimateWallet.signTransaction({
      chainId, nonce: 0, type: 2, gasLimit: 12000000,
      maxPriorityFeePerGas: 1000000, maxFeePerGas: 12000000,
      value: 0, ...tx
    });
    const result = await provider.call({
      to: l1FeeOracle,
      data: l1FeeOracleInterface.encodeFunctionData('getL1Fee', [signed])
    });
    return l1FeeOracleInterface.decodeFunctionResult('getL1Fee', result)[0].toString();
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

if (Number(await rpcCall('eth_chainId', [])) !== chainId) throw new Error('RPC chain ID differs from base-qa.json');
const [block, balanceHex, nonceHex, pendingNonceHex, gasPriceHex, routerCode, factoryCode, oracleCode] =
  await Promise.all([
    rpcCall('eth_getBlockByNumber', ['latest', false]),
    rpcCall('eth_getBalance', [deployer, 'latest']),
    rpcCall('eth_getTransactionCount', [deployer, 'latest']),
    rpcCall('eth_getTransactionCount', [deployer, 'pending']),
    rpcCall('eth_gasPrice', []),
    rpcCall('eth_getCode', [router, 'latest']),
    rpcCall('eth_getCode', [factory, 'latest']),
    rpcCall('eth_getCode', [l1FeeOracle, 'latest'])
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
    artifactSha256: sha256(bytes),
    initcodeKeccak256: ethers.utils.keccak256(artifact.bytecode.object),
    initcodeBytes: (artifact.bytecode.object.length - 2) / 2,
    runtimeBytes: (artifact.deployedBytecode.object.length - 2) / 2
  };
}
const sourceHashes = {};
for (const relative of [
  'src/metro.sol', 'src/xMETRO.sol', 'src/XMetroCoreLogic.sol', 'src/XMetroDeFiAdapter.sol',
  'src/MetroDistributorBase.sol', 'src/MetroDistributorV1.sol', 'src/ThorMigrationEscrow.sol',
  'script/base-qa/qa-timers.patch',
  'test/mocks/ERC20Mintable.sol', 'test/mocks/MockDepositProtocols.sol',
  'test/mocks/MockAaveV4Giver.sol', 'test/mocks/MockSyrupUSDC.sol',
  '../commission/contracts/CommissionVault.sol', '../commission/contracts/RateLimitedForwarder.sol'
]) {
  sourceHashes[relative] = sha256(await readFile(path.join(root, relative)));
}
const quotes = [];
for (const [label, name, args] of specs) {
  const artifact = await readArtifact(name);
  const factoryContract = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object);
  const tx = factoryContract.getDeployTransaction(...args);
  quotes.push({ label, contract: name, ...await quote(tx.data, null, gasPrice) });
}
const tokenA = ethers.Wallet.createRandom().address;
const tokenB = ethers.Wallet.createRandom().address;
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
await mkdir(runDir, { recursive: true });
await writeFile(preflightFile, JSON.stringify(report, null, 2) + '\n', { mode: 0o644 });
const estimableWei = quotes.reduce((sum, x) => sum + BigInt(x.totalWei || 0), 0n);
const sevenPairsWei = BigInt(pairCreationQuote.totalWei || 0) * 7n;
console.log(JSON.stringify({
  evidence: preflightFile, chainId, blockNumber: report.blockNumber, balanceEth: report.balanceEth,
  nonce: report.nonce, gasPriceGwei: report.gasPriceGwei,
  v2RelationValid: true, estimatedDeploymentsEth: feeEth(estimableWei),
  sevenPairCreationsEth: feeEth(sevenPairsWei),
  subtotalKnownEth: feeEth(estimableWei + sevenPairsWei),
  unestimated: quotes.filter(x => !x.gas).map(x => x.label),
  pairCreationGas: pairCreationQuote.gas
}, null, 2));
