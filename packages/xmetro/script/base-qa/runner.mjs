import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const root = fileURLToPath(new URL('../../', import.meta.url));
export const { ethers } = createRequire(path.join(root, 'integration/examples/package.json'))('ethers');
export const qaConfig = JSON.parse(readFileSync(path.join(root, 'integration/config/base-qa.json')));
export const chainId = qaConfig.chainId;
export const artifactPaths = {
  ERC20Mintable: 'out-core/ERC20Mintable.sol/ERC20Mintable.json',
  MockSyrupUSDC: 'out-core/MockSyrupUSDC.sol/MockSyrupUSDC.json',
  MockAaveV3Pool: 'out-core/MockDepositProtocols.sol/MockAaveV3Pool.json',
  MockAaveV4Spoke: 'out-core/MockDepositProtocols.sol/MockAaveV4Spoke.json',
  MockAaveV4Giver: 'out-core/MockAaveV4Giver.sol/MockAaveV4Giver.json',
  MockPoolPermissionManager: 'out-core/MockDepositProtocols.sol/MockPoolPermissionManager.json',
  MockSyrupRouter: 'out-core/MockDepositProtocols.sol/MockSyrupRouter.json',
  MetroToken: 'out-testbed/metro.sol/MetroToken.json',
  xMETRO: 'out-testbed/xMETRO.sol/xMETRO.json',
  XMetroDeFiAdapter: 'out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json',
  ERC1967Proxy: 'out-testbed/ERC1967Proxy.sol/ERC1967Proxy.json',
  MetroDistributorV1: 'out-testbed/MetroDistributorV1.sol/MetroDistributorV1.json',
  ThorMigrationEscrow: 'out-testbed/ThorMigrationEscrow.sol/ThorMigrationEscrow.json',
  CommissionVault: '../commission/out/CommissionVault.sol/CommissionVault.json',
  RateLimitedForwarder: '../commission/out/RateLimitedForwarder.sol/RateLimitedForwarder.json'
};
export const testTokens = [
  ['TestUSDC', 'Test USDC', 6], ['TestTHOR', 'Test THOR', 18], ['TestYTHOR', 'Test yTHOR', 18],
  ['TestUSDT', 'Test USDT', 6], ['TestWBTC', 'Test WBTC', 8], ['TestGHO', 'Test GHO', 18],
  ['TestXAUT', 'Test XAUT', 6], ['TestExtraToken', 'Test Extra Token', 18]
];
export const v2Router = '0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24';
export const v2Factory = '0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6';
export const l1FeeOracle = '0x420000000000000000000000000000000000000F';
export const l1FeeOracleInterface = new ethers.utils.Interface(['function getL1Fee(bytes) view returns (uint256)']);
export const rpcUrl = process.env.BASE_RPC_URL || 'https://mainnet.base.org';
const localRehearsal = process.env.BASE_QA_LOCAL_REHEARSAL === '1';
const runId = process.env.BASE_QA_RUN_ID || qaConfig.deploymentRunId;
if (!/^[a-z0-9][a-z0-9-]{4,80}$/.test(runId)) throw new Error('Invalid BASE_QA_RUN_ID');
export const runDir = path.join(root, 'integration/testing/base/evidence',
  localRehearsal ? `local-${runId}` : runId);
export const preflightFile = path.join(runDir, 'preflight.json');
const signerFile = process.env.BASE_QA_SIGNERS_FILE;
const minReserve = ethers.utils.parseEther('0.00003');

async function saveJson(file, value, mode = 0o644) {
  await mkdir(path.dirname(file), { recursive: true });
  const temp = file + '.tmp';
  await writeFile(temp, JSON.stringify(value, null, 2) + '\n', { mode });
  await rename(temp, file);
}
export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}
export async function readPublicWallets() {
  return JSON.parse(await readFile(path.join(root, 'integration/testing/base/wallets.json')));
}
export async function readArtifact(name) {
  return JSON.parse(await readFile(path.join(root, artifactPaths[name])));
}
export async function verifyPreflight(preflight) {
  for (const [relative, expected] of Object.entries(preflight.sourceHashes)) {
    const actual = sha256(await readFile(path.join(root, relative)));
    if (actual !== expected) throw new Error('Source changed after preflight: ' + relative);
  }
  for (const { path: relative, artifactSha256 } of Object.values(preflight.artifacts)) {
    const actual = sha256(await readFile(path.join(root, relative)));
    if (actual !== artifactSha256) throw new Error('Artifact changed after preflight: ' + relative);
  }
}
export async function openRun() {
  if (!signerFile) throw new Error('Set BASE_QA_SIGNERS_FILE to a private local signer file');
  const loopback = /^http:\/\/(127\.0\.0\.1|localhost)(:|\/)/.test(rpcUrl);
  if (localRehearsal && !loopback) throw new Error('Local rehearsal requires a loopback RPC');
  if (!localRehearsal && loopback) throw new Error('On-chain mode cannot use a loopback RPC');
  if (!localRehearsal && process.env.BASE_QA_BROADCAST !== 'YES') {
    throw new Error('Set BASE_QA_BROADCAST=YES to broadcast');
  }
  const provider = new ethers.providers.StaticJsonRpcProvider(rpcUrl, chainId);
  if (Number(await provider.send('eth_chainId', [])) !== chainId) throw new Error('RPC chain ID differs from base-qa.json');
  const publicWallets = await readPublicWallets();
  const privateWallets = JSON.parse(await readFile(signerFile));
  const publicByRole = Object.fromEntries(publicWallets.accounts.map(x => [x.role, x.address.toLowerCase()]));
  const wallets = {};
  for (const account of privateWallets.accounts) {
    const wallet = new ethers.Wallet(account.privateKey, provider);
    if (wallet.address.toLowerCase() !== publicByRole[account.role]) throw new Error('Signer does not match the public wallet list');
    wallets[account.role] = wallet;
  }
  if (privateWallets.chainId !== chainId || !wallets.deployer) {
    throw new Error('Wallet or chain ID mismatch');
  }
  const preflight = JSON.parse(await readFile(preflightFile));
  await verifyPreflight(preflight);
  const stateFile = path.join(runDir, 'state.json');
  let state;
  try { state = JSON.parse(await readFile(stateFile)); }
  catch (error) { if (error.code !== 'ENOENT') throw error; state = { runId: path.basename(runDir), chainId, steps: {}, contracts: {}, plan: null }; }
  async function persist() { await saveJson(stateFile, state, 0o600); }
  return { provider, wallets, state, persist };
}
export async function sendStep(ctx, { id, buildTx, expectContract = false }) {
  const { provider, wallets, state, persist } = ctx;
  const wallet = wallets.deployer;
  const transactionsDir = path.join(runDir, 'transactions');
  const evidenceFile = path.join(transactionsDir, id + '.json');
  let step = state.steps[id];
  if (step?.status === 'confirmed') {
    const receipt = await provider.send('eth_getTransactionReceipt', [step.hash]);
    if (!receipt || Number(receipt.status) !== 1) throw new Error('Recorded step receipt changed: ' + id);
    if (expectContract && (await provider.getCode(step.contractAddress)) === '0x') throw new Error('Recorded deployment has no code: ' + id);
    return step;
  }
  if (!step) {
    const latest = await provider.getTransactionCount(wallet.address, 'latest');
    const pending = await provider.getTransactionCount(wallet.address, 'pending');
    if (pending !== latest) throw new Error('Wallet has an unrecorded pending nonce: deployer');
    const tx = await buildTx();
    const estimate = await provider.estimateGas({ ...tx, from: wallet.address });
    const gasLimit = estimate.mul(120).div(100).add(10000);
    const gasPrice = await provider.getGasPrice();
    // Base QA uses the 1,000,000 wei priority fee verified against the Base RPC;
    // some public RPCs leave eth_maxPriorityFeePerGas unanswered for minutes.
    const priority = ethers.BigNumber.from(1000000);
    const maxFee = gasPrice.mul(3).div(2);
    if (maxFee.lte(priority)) throw new Error('Invalid fee configuration');
    const unsigned = {
      chainId, type: 2, nonce: latest, gasLimit,
      maxFeePerGas: maxFee, maxPriorityFeePerGas: priority,
      value: tx.value || 0, data: tx.data || '0x',
      ...(tx.to ? { to: tx.to } : {})
    };
    const raw = await wallet.signTransaction(unsigned);
    const hash = ethers.utils.keccak256(raw);
    const l1Raw = await provider.call({ to: l1FeeOracle, data: l1FeeOracleInterface.encodeFunctionData('getL1Fee', [raw]) });
    const l1Fee = l1FeeOracleInterface.decodeFunctionResult('getL1Fee', l1Raw)[0];
    const balance = await provider.getBalance(wallet.address);
    const maxCost = gasLimit.mul(maxFee).add(l1Fee).add(unsigned.value);
    if (balance.lt(maxCost.add(minReserve))) {
      throw new Error('BUDGET_STOP ' + id + ': balance=' + balance.toString() + ', requiredWithReserve=' + maxCost.add(minReserve).toString());
    }
    const contractAddress = expectContract ? ethers.utils.getContractAddress({ from: wallet.address, nonce: latest }) : null;
    step = {
      id, role: 'deployer', from: wallet.address, to: tx.to || null, nonce: latest,
      hash, contractAddress, status: 'prepared',
      gasEstimate: estimate.toString(), gasLimit: gasLimit.toString(),
      maxFeePerGas: maxFee.toString(), maxPriorityFeePerGas: priority.toString(),
      l1FeeQuote: l1Fee.toString(), balanceBeforeWei: balance.toString(),
      preparedAt: new Date().toISOString()
    };
    state.steps[id] = step;
    await saveJson(evidenceFile, { step, rawSignedTransaction: raw }, 0o600);
    await persist();
  }
  const saved = JSON.parse(await readFile(evidenceFile));
  let receipt = await provider.send('eth_getTransactionReceipt', [step.hash]);
  if (!receipt) {
    try { await provider.send('eth_sendRawTransaction', [saved.rawSignedTransaction]); }
    catch (error) {
      const message = String(error.message || '');
      if (!/already known|known transaction|already imported|nonce too low/i.test(message)) throw error;
    }
    step.status = 'broadcast';
    step.broadcastAt = new Date().toISOString();
    await persist();
    for (let i = 0; i < 40 && !receipt; i++) {
      await new Promise(resolve => setTimeout(resolve, 2000));
      receipt = await provider.send('eth_getTransactionReceipt', [step.hash]);
    }
  }
  if (!receipt) throw new Error('Transaction is unconfirmed; resume the recorded nonce: ' + id + ' ' + step.hash);
  // Public RPCs can expose a receipt before indexing the block; keep the nonce and resume later.
  let block = null;
  for (let i = 0; i < 12 && !block; i++) {
    block = await provider.send('eth_getBlockByHash', [receipt.blockHash, false]);
    if (!block) block = await provider.send('eth_getBlockByNumber', [receipt.blockNumber, false]);
    if (!block) await new Promise(resolve => setTimeout(resolve, 1000));
  }
  if (!block) throw new Error('Receipt exists but its block is not indexed yet; resume later: ' + id + ' ' + step.hash);
  const chainTx = await provider.send('eth_getTransactionByHash', [step.hash]);
  const fee = BigInt(receipt.gasUsed) * BigInt(receipt.effectiveGasPrice) + BigInt(receipt.l1Fee || 0);
  step.status = Number(receipt.status) === 1 ? 'confirmed' : 'reverted';
  step.confirmedAt = new Date().toISOString();
  step.blockNumber = Number(receipt.blockNumber);
  step.blockHash = receipt.blockHash;
  step.blockTimestamp = Number(block.timestamp);
  step.gasUsed = BigInt(receipt.gasUsed).toString();
  step.actualFeeWei = fee.toString();
  step.balanceAfterWei = (await provider.getBalance(wallet.address)).toString();
  const evidence = { step, rawSignedTransaction: saved.rawSignedTransaction, transaction: chainTx, receipt, block };
  if (step.status === 'reverted') {
    const archiveFile = path.join(transactionsDir, `${id}.reverted-${step.nonce}.json`);
    await saveJson(archiveFile, evidence, 0o600);
    delete state.steps[id];
    await persist();
    throw new Error('On-chain transaction reverted; archived to ' + archiveFile + ', rerun to prepare a fresh one: ' + id);
  }
  if (expectContract) {
    if (receipt.contractAddress?.toLowerCase() !== step.contractAddress.toLowerCase()) throw new Error('Deployment address differs from nonce prediction: ' + id);
    const code = await provider.getCode(step.contractAddress, receipt.blockNumber);
    if (code === '0x') throw new Error('Deployment succeeded but no runtime code exists: ' + id);
    step.runtimeCodeHash = ethers.utils.keccak256(code);
    step.runtimeCodeBytes = (code.length - 2) / 2;
    state.contracts[id] = step.contractAddress;
  }
  await saveJson(evidenceFile, evidence, 0o600);
  await persist();
  console.log(id, step.hash, step.contractAddress || '', 'feeWei=' + step.actualFeeWei);
  return step;
}
