// Base QA transaction recorder: read signer data locally, persist each step, and resume the same nonce if needed.
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
export const { ethers } = require('ethers');
export const root = fileURLToPath(new URL('../../', import.meta.url));
const localRehearsal = process.env.BASE_QA_LOCAL_REHEARSAL === '1';
const runId = process.env.BASE_QA_RUN_ID || 'base-qa-project-20260930';
if (!/^[a-z0-9][a-z0-9-]{4,80}$/.test(runId)) throw new Error('Invalid BASE_QA_RUN_ID');
export const runDir = path.join(root, 'integration/testing/base/evidence',
  localRehearsal ? `local-${runId}` : runId);
const preflightFile = path.join(runDir, 'preflight.json');
const signerFile = process.env.BASE_QA_SIGNERS_FILE;
const oracle = '0x420000000000000000000000000000000000000F';
const oracleAbi = new ethers.utils.Interface(['function getL1Fee(bytes) view returns (uint256)']);
const minReserve = ethers.utils.parseEther('0.00003');

async function saveJson(file, value, mode = 0o644) {
  await mkdir(path.dirname(file), { recursive: true });
  const temp = file + '.tmp';
  await writeFile(temp, JSON.stringify(value, null, 2) + '\n', { mode });
  await rename(temp, file);
}
export async function readArtifact(relative) {
  return JSON.parse(await readFile(path.join(root, relative)));
}
export async function openRun() {
  if (!signerFile) throw new Error('Set BASE_QA_SIGNERS_FILE to a private local signer file');
  const rpc = process.env.BASE_RPC_URL || 'https://mainnet.base.org';
  if (localRehearsal && !/^http:\/\/(127\.0\.0\.1|localhost)(:|\/)/.test(rpc)) {
    throw new Error('Local rehearsal requires a loopback RPC');
  }
  if (!localRehearsal && /^http:\/\/(127\.0\.0\.1|localhost)(:|\/)/.test(rpc)) {
    throw new Error('On-chain mode cannot use a loopback RPC');
  }
  if (!localRehearsal && process.env.BASE_QA_BROADCAST !== 'YES') {
    throw new Error('Set BASE_QA_BROADCAST=YES to broadcast on Base');
  }
  const provider = new ethers.providers.StaticJsonRpcProvider(rpc, 8453);
  const chainId = Number(await provider.send('eth_chainId', []));
  if (chainId !== 8453) throw new Error('Refusing a non-Base-mainnet chain ID');
  const publicWallets = JSON.parse(await readFile(path.join(root, 'integration/testing/base/wallets.json')));
  const privateWallets = JSON.parse(await readFile(signerFile));
  const publicByRole = Object.fromEntries(publicWallets.accounts.map(x => [x.role, x.address.toLowerCase()]));
  const wallets = {};
  for (const account of privateWallets.accounts) {
    const wallet = new ethers.Wallet(account.privateKey, provider);
    if (wallet.address.toLowerCase() !== publicByRole[account.role]) throw new Error('Signer does not match the public wallet list');
    wallets[account.role] = wallet;
  }
  if (privateWallets.chainId !== 8453 || wallets.deployer.address.toLowerCase() !== publicByRole.deployer) {
    throw new Error('Wallet or chain ID mismatch');
  }
  const preflight = JSON.parse(await readFile(preflightFile));
  for (const [relative, expected] of Object.entries(preflight.sourceHashes)) {
    const actual = createHash('sha256').update(await readFile(path.join(root, relative))).digest('hex');
    if (actual !== expected) throw new Error('Source changed after preflight: ' + relative);
  }
  for (const { path: relative, artifactSha256 } of Object.values(preflight.artifacts)) {
    const actual = createHash('sha256').update(await readFile(path.join(root, relative))).digest('hex');
    if (actual !== artifactSha256) throw new Error('Artifact changed after preflight: ' + relative);
  }
  const stateFile = path.join(runDir, 'state.json');
  let state;
  try { state = JSON.parse(await readFile(stateFile)); }
  catch (error) { if (error.code !== 'ENOENT') throw error; state = { runId: path.basename(runDir), chainId, steps: {}, contracts: {}, plan: null }; }
  async function persist() { await saveJson(stateFile, state, 0o600); }
  return { provider, wallets, state, persist, stateFile, preflight };
}
export async function sendStep(ctx, { id, role = 'deployer', tx, expectContract = false, reserveWei, explicitGasLimit, expectFailure = false }) {
  const { provider, wallets, state, persist } = ctx;
  const wallet = wallets[role];
  if (!wallet) throw new Error('Unknown wallet role: ' + role);
  const reserve = reserveWei ?? (role === 'deployer' ? minReserve : ethers.utils.parseEther('0.000002'));
  const evidenceFile = path.join(runDir, 'transactions', id + '.json');
  let step = state.steps[id];
  if (step?.status === 'confirmed' || step?.status === 'expected_revert') {
    const receipt = await provider.send('eth_getTransactionReceipt', [step.hash]);
    if (!receipt || Number(receipt.status) !== (expectFailure ? 0 : 1)) throw new Error('Recorded step receipt changed: ' + id);
    if (expectContract && (await provider.getCode(step.contractAddress)) === '0x') throw new Error('Recorded deployment has no code: ' + id);
    return step;
  }
  if (!step) {
    const latest = await provider.getTransactionCount(wallet.address, 'latest');
    const pending = await provider.getTransactionCount(wallet.address, 'pending');
    if (pending !== latest) throw new Error('Wallet has an unrecorded pending nonce: ' + role);
    const estimate = explicitGasLimit ? ethers.BigNumber.from(explicitGasLimit) :
      await provider.estimateGas({ ...tx, from: wallet.address });
    const gasLimit = explicitGasLimit ? estimate : estimate.mul(120).div(100).add(10000);
    const gasPrice = await provider.getGasPrice();
    // Base QA uses the 1,000,000 wei priority fee verified against the Base RPC;
    // some public RPCs leave eth_maxPriorityFeePerGas unanswered for minutes.
    const priority = ethers.BigNumber.from(1000000);
    const maxFee = gasPrice.mul(3).div(2);
    if (maxFee.lte(priority)) throw new Error('Invalid fee configuration');
    const unsigned = {
      chainId: 8453, type: 2, nonce: latest, gasLimit,
      maxFeePerGas: maxFee, maxPriorityFeePerGas: priority,
      value: tx.value || 0, data: tx.data || '0x',
      ...(tx.to ? { to: tx.to } : {})
    };
    const raw = await wallet.signTransaction(unsigned);
    const hash = ethers.utils.keccak256(raw);
    const l1Raw = await provider.call({ to: oracle, data: oracleAbi.encodeFunctionData('getL1Fee', [raw]) });
    const l1Fee = oracleAbi.decodeFunctionResult('getL1Fee', l1Raw)[0];
    const balance = await provider.getBalance(wallet.address);
    const maxCost = gasLimit.mul(maxFee).add(l1Fee).add(unsigned.value);
    if (balance.lt(maxCost.add(reserve))) {
      throw new Error('BUDGET_STOP ' + id + ': balance=' + balance.toString() + ', requiredWithReserve=' + maxCost.add(reserve).toString());
    }
    const contractAddress = expectContract ? ethers.utils.getContractAddress({ from: wallet.address, nonce: latest }) : null;
    step = {
      id, role, from: wallet.address, to: tx.to || null, nonce: latest,
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
  step.status = Number(receipt.status) === 1 ? 'confirmed' : (expectFailure ? 'expected_revert' : 'failed');
  step.confirmedAt = new Date().toISOString();
  step.blockNumber = Number(receipt.blockNumber);
  step.blockHash = receipt.blockHash;
  step.blockTimestamp = Number(block.timestamp);
  step.gasUsed = BigInt(receipt.gasUsed).toString();
  step.actualFeeWei = fee.toString();
  if (expectContract) {
    if (receipt.contractAddress?.toLowerCase() !== step.contractAddress.toLowerCase()) throw new Error('Deployment address differs from nonce prediction: ' + id);
    const code = await provider.getCode(step.contractAddress, receipt.blockNumber);
    step.runtimeCodeHash = ethers.utils.keccak256(code);
    step.runtimeCodeBytes = (code.length - 2) / 2;
    state.contracts[id] = step.contractAddress;
  }
  step.balanceAfterWei = (await provider.getBalance(wallet.address)).toString();
  await saveJson(evidenceFile, { step, rawSignedTransaction: saved.rawSignedTransaction, transaction: chainTx, receipt, block }, 0o600);
  await persist();
  if (expectFailure && step.status !== 'expected_revert') throw new Error('Expected revert succeeded; inspect manually: ' + id + ' ' + step.hash);
  if (!expectFailure && step.status !== 'confirmed') throw new Error('On-chain transaction reverted; receipt retained: ' + id + ' ' + step.hash);
  if (expectContract && step.runtimeCodeBytes === 0) throw new Error('Deployment succeeded but no runtime code exists: ' + id);
  console.log(id, step.hash, step.contractAddress || '', 'feeWei=' + step.actualFeeWei);
  return step;
}
