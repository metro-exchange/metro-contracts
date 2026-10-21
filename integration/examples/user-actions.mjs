import { readFile } from 'node:fs/promises';
import ethersPackage from 'ethers';

const { ethers } = ethersPackage;
const tokenAbi = [
  'function allowance(address owner,address spender) view returns (uint256)',
  'function approve(address spender,uint256 amount) returns (bool)'
];
const spokeAbi = [
  'function setUserPositionManager(address manager,bool approved)'
];
const coreAbi = JSON.parse(await readFile(new URL('../abi/xMETRO.json', import.meta.url)));
const escrowAbi = JSON.parse(await readFile(new URL('../abi/ThorMigrationEscrow.json', import.meta.url)));

export async function loadConfig(file) {
  const config = JSON.parse(await readFile(file, 'utf8'));
  if (!['deployed_pending_handover', 'deployed'].includes(config.status)) {
    throw new Error(`Environment is not deployed: ${config.status}`);
  }
  return config;
}

export function address(value, label) {
  if (!ethers.utils.isAddress(value) || value === ethers.constants.AddressZero) {
    throw new Error(`Missing or invalid ${label}`);
  }
  return ethers.utils.getAddress(value);
}

export async function assertChain(signer, config) {
  const network = await signer.provider.getNetwork();
  if (network.chainId !== config.chainId) throw new Error(`Expected chain ${config.chainId}, got ${network.chainId}`);
}

async function approveAtLeast(signer, tokenAddress, spender, amount) {
  const token = new ethers.Contract(address(tokenAddress, 'token'), tokenAbi, signer);
  const allowance = await token.allowance(await signer.getAddress(), spender);
  if (allowance.gte(amount)) return null;
  const tx = await token.approve(spender, amount);
  await tx.wait();
  return tx.hash;
}

export async function approveAndStake(signer, config, metroBaseUnits) {
  await assertChain(signer, config);
  const coreAddress = address(config.contracts.xMETRO, 'xMETRO');
  await approveAtLeast(signer, config.contracts.METRO, coreAddress, metroBaseUnits);
  return (await new ethers.Contract(coreAddress, coreAbi, signer).stake(metroBaseUnits)).wait();
}

export async function migrate(signer, config, kind, tokenBaseUnits) {
  await assertChain(signer, config);
  if (kind !== 'THOR' && kind !== 'yTHOR') throw new Error('kind must be THOR or yTHOR');
  const escrowAddress = address(config.contracts.ThorMigrationEscrow, 'ThorMigrationEscrow');
  const tokenAddress = kind === 'THOR' ? config.tokens.TestTHOR ?? config.tokens.THOR : config.tokens.TestYTHOR ?? config.tokens.yTHOR;
  await approveAtLeast(signer, tokenAddress, escrowAddress, tokenBaseUnits);
  const escrow = new ethers.Contract(escrowAddress, escrowAbi, signer);
  return (await (kind === 'THOR' ? escrow.migrateThor(tokenBaseUnits) : escrow.migrateYThor(tokenBaseUnits))).wait();
}

export async function claimRewards(signer, config) {
  await assertChain(signer, config);
  return (await new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer).claimRewards()).wait();
}

export function buildV2ExecutionData(path) {
  if (!Array.isArray(path) || path.length < 2) throw new Error('A V2 path needs at least two token addresses');
  const tokens = path.map((token, index) => address(token, `path[${index}]`));
  return ethers.utils.defaultAbiCoder.encode(
    ['uint8', 'bytes'],
    [0, ethers.utils.defaultAbiCoder.encode(['address[]'], [tokens])]
  );
}

export async function manualAction(signer, config, { strategyId, minAmountOut, deadline = 0, executionData = '0x' }) {
  await assertChain(signer, config);
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer);
  return (await core.claimAndExecute(strategyId, minAmountOut, deadline, executionData)).wait();
}

export async function chooseAutoStrategy(signer, config, strategyId) {
  await assertChain(signer, config);
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer);
  return (await core.enableAutoStrategy(strategyId)).wait();
}

export async function disableAutoStrategy(signer, config) {
  await assertChain(signer, config);
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer);
  return (await core.disableAutoStrategy()).wait();
}

export async function requestAndWithdrawFree(signer, config, metroBaseUnits, maxRequests = 0) {
  await assertChain(signer, config);
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer);
  const request = await core.requestUnstake(metroBaseUnits);
  await request.wait();
  // Call withdrawFree only after the corresponding on-chain unlock time.
  return { requestHash: request.hash, withdraw: () => core.withdrawFree(maxRequests) };
}

export async function exitYThor(signer, config, positionId, mode) {
  await assertChain(signer, config);
  if (mode !== 'liquid' && mode !== 'stake') throw new Error('mode must be liquid or stake');
  const core = new ethers.Contract(address(config.contracts.xMETRO, 'xMETRO'), coreAbi, signer);
  return (await core.exitYThor(ethers.BigNumber.from(positionId), mode === 'liquid' ? 0 : 1)).wait();
}

export async function authorizeAaveV4Giver(signer, config) {
  await assertChain(signer, config);
  const spoke = address(config.protocolMocks?.MockAaveV4Spoke ?? config.protocols?.aaveV4Spoke, 'Aave V4 Spoke');
  const giver = address(config.protocolMocks?.MockAaveV4Giver ?? config.protocols?.aaveV4Giver, 'Aave V4 Giver');
  return (await new ethers.Contract(spoke, spokeAbi, signer).setUserPositionManager(giver, true)).wait();
}
