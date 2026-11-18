#!/usr/bin/env node

// Independent business transaction receipts on a local Anvil Ethereum fork.
// No transaction may be sent to a remote RPC or to canonical Ethereum.

import fs from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { ethers } = require("ethers");

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const EVIDENCE = path.join(ROOT, "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01");
const RPC = process.env.ANVIL_RPC_URL ?? "http://127.0.0.1:8546";
const SIZES = (process.argv.find((value) => value.startsWith("--sizes="))?.split("=")[1] ?? "1,10,50,100,200")
  .split(",").map(Number);
const PATHS = (process.argv.find((value) => value.startsWith("--paths="))?.split("=")[1] ?? "compound,syrup,v3,v4,maple")
  .split(",");
const OUT = process.argv.find((value) => value.startsWith("--output="))?.slice(9)
  ?? path.join(EVIDENCE, "G01-G09-anvil-receipts.json");

const FORK_BLOCK = 26_077_998;
const FORK_HASH = "0xb75cb3bedaa74adf79199d847c94bbca4724d092da355d3e13c354773e2eb2aa";
const TX_GAS_CAP = ethers.BigNumber.from(16_777_216);
const ZERO32 = ethers.constants.HashZero;
const ADDR = {
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  USDC_HOLDER: "0x28C6c06298d514Db089934071355E5743bf21d60",
  THOR: "0xa5f2211B9b8170F694421f2046281775E8468044",
  YTHOR: "0x8793CD69895C45b2d2474236b3Cb28FC5C764775",
  V2_ROUTER: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
  V3_ROUTER: "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",
  ONEINCH: "0x111111125421cA6dc452d289314280a0f8842A65",
  AAVE_V3_POOL: "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
  A_USDC: "0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c",
  V4_SPOKE: "0x94e7A5dCbE816e498b89aB752661904E2F56c485",
  V4_GIVER: "0x17A54b8d6D9C68e7fa1C7112AC998EA1BA51d11e",
  MAPLE_ROUTER: "0x134cCaaA4F1e4552eC8aEcb9E4A2360dDcF8df76",
  SYRUP_USDC: "0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b",
};
const PATH_TO_G = { compound: "G-01", syrup: "G-06", v3: "G-07", v4: "G-08", maple: "G-09" };
const ABI = ethers.utils.defaultAbiCoder;
const parseUnits = ethers.utils.parseUnits;
const oneEther = ethers.utils.parseEther("1");
const rewardTotal = parseUnits("100", 6);
const domain = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("XMETRO_DEFI_STRATEGY_V1"));
const provider = new ethers.providers.JsonRpcProvider(RPC);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
function same(a, b) { return a.toLowerCase() === b.toLowerCase(); }
function artifact(relative) { return fs.readFile(path.join(ROOT, relative), "utf8").then(JSON.parse); }
function hex(n) { return ethers.utils.hexValue(n); }
function strategyId(kind, output = ethers.constants.AddressZero) {
  return ethers.utils.keccak256(ABI.encode(["uint256", "bytes32", "uint8", "address"], [1, domain, kind, output]));
}
function userAddress(index) {
  const digest = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`xmetro-gas-fork-user-${index}`));
  return ethers.utils.getAddress(`0x${digest.slice(-40)}`);
}
async function sent(promise) {
  const tx = await promise;
  const receipt = await localReceipt(tx.hash);
  assert(receipt.status === "0x1", `setup transaction ${tx.hash} failed`);
  return receipt;
}
async function localReceipt(hash) {
  // ethers' polling cache can retain pre-revert block heights across Anvil snapshots.
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const receipt = await provider.send("eth_getTransactionReceipt", [hash]);
    if (receipt) return receipt;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`local Anvil receipt not found after 20s: ${hash}`);
}
async function insistLocalFork() {
  const url = new URL(RPC);
  assert(["127.0.0.1", "localhost", "::1"].includes(url.hostname), "ANVIL_RPC_URL must be loopback");
  const info = await provider.send("anvil_nodeInfo", []);
  const network = await provider.getNetwork();
  const fixed = await provider.getBlock(FORK_BLOCK);
  assert(network.chainId === 1, "expected Ethereum chainId 1");
  assert(info.forkConfig?.forkBlockNumber === FORK_BLOCK, "expected Anvil fork at the fixed block");
  assert(info.hardFork?.toLowerCase() === "osaka", "expected Osaka hardfork");
  assert(same(fixed.hash, FORK_HASH), "fixed fork hash mismatch");
  assert(info.forkConfig?.forkUrl, "Anvil is not running in fork mode");
  return { anvil: info, fixedBlock: { number: fixed.number, hash: fixed.hash, timestamp: fixed.timestamp } };
}
async function deploy(artifactName, signer, args) {
  const a = await artifact(artifactName);
  assert(a.bytecode?.linkReferences && Object.keys(a.bytecode.linkReferences).length === 0, `${artifactName} has links`);
  const factory = new ethers.ContractFactory(a.abi, a.bytecode.object, signer);
  const contract = await factory.deploy(...args);
  await sent(Promise.resolve(contract.deployTransaction));
  return contract;
}
async function prepareSystem() {
  const owner = provider.getSigner(0);
  const ownerAddress = await owner.getAddress();
  const erc20 = new ethers.Contract(ADDR.USDC, [
    "function transfer(address,uint256) returns(bool)", "function approve(address,uint256) returns(bool)",
    "function balanceOf(address) view returns(uint256)", "function allowance(address,address) view returns(uint256)",
  ], owner);
  await provider.send("anvil_setBalance", [ADDR.USDC_HOLDER, hex(ethers.utils.parseEther("10"))]);
  await provider.send("anvil_impersonateAccount", [ADDR.USDC_HOLDER]);
  const holder = provider.getSigner(ADDR.USDC_HOLDER);
  assert((await erc20.balanceOf(ADDR.USDC_HOLDER)).gte(parseUnits("30000", 6)), "real USDC holder lacks funding");
  const funding = await sent(erc20.connect(holder).transfer(ownerAddress, parseUnits("30000", 6)));

  const metro = await deploy("out-core/metro.sol/MetroToken.json", owner, ["Metro", "METRO", ownerAddress]);
  const core = await deploy("out-core/xMETRO.sol/xMETRO.json", owner,
    [ownerAddress, metro.address, ADDR.USDC, userAddress(999_999), 20_000]);
  const implementation = await deploy("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json", owner, []);
  const adapterArtifact = await artifact("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json");
  const initialize = new ethers.utils.Interface(adapterArtifact.abi)
    .encodeFunctionData("initialize", [core.address, ADDR.USDC, metro.address]);
  const proxy = await deploy("out-deploy/ERC1967Proxy.sol/ERC1967Proxy.json", owner,
    [implementation.address, initialize]);
  const adapter = new ethers.Contract(proxy.address, adapterArtifact.abi, owner);
  const distributor = await deploy("out-core/RewardDistributor.sol/RewardDistributor.json", owner,
    [core.address, ownerAddress]);
  await sent(metro.setMinter(core.address, true));
  await sent(metro.setMinter(ownerAddress, true));
  await sent(core.setDeFiAdapter(proxy.address));
  await sent(core.setRewardDistributor(distributor.address));
  await sent(distributor.setOperator(ownerAddress, true));
  await sent(core.setAutoCompoundOperator(ownerAddress, true));
  const block = await provider.getBlock("latest");
  const escrow = await deploy("out-core/ThorMigrationEscrow.sol/ThorMigrationEscrow.json", owner,
    [ownerAddress, core.address, ADDR.THOR, ADDR.YTHOR, block.timestamp + 3600]);
  await sent(escrow.setCaps(ethers.utils.parseEther("20000000"), ethers.utils.parseEther("20000000")));
  await sent(escrow.setRatios(oneEther, oneEther));
  await sent(escrow.setDeadlines(block.timestamp + 365 * 86400, block.timestamp + 365 * 86400));
  await sent(core.setMigrationEscrow(escrow.address));
  const vault = await deploy("out-fork-v2/CommissionVault.sol/CommissionVault.json", owner,
    [ADDR.USDC, distributor.address, ownerAddress, ownerAddress,
      parseUnits("1000000", 6), parseUnits("1000000", 6), false, 86400, 86400]);
  await sent(distributor.setCommissionVault(vault.address));
  await sent(adapter.setRouters(ADDR.V2_ROUTER, ADDR.V3_ROUTER, ADDR.ONEINCH));
  await sent(adapter.setSwapMetroConfig(true, true));
  await sent(adapter.setSwapTokenConfig(ADDR.SYRUP_USDC, true, true));
  await sent(adapter.setAaveV3Config(ADDR.AAVE_V3_POOL, ADDR.A_USDC, 37, true, true));
  await sent(adapter.setAaveV4Config(ADDR.V4_SPOKE, ADDR.V4_GIVER, 7, true, true));
  await sent(adapter.setMapleConfig(ADDR.MAPLE_ROUTER, ZERO32, true, true));
  await sent(core.unpause());
  await sent(erc20.approve(distributor.address, parseUnits("30000", 6)));

  // The METRO pool is a new legitimate Uniswap V2 pool on this fork.
  const v2 = new ethers.Contract(ADDR.V2_ROUTER, [
    "function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) returns(uint256,uint256,uint256)",
    "function getAmountsOut(uint256,address[]) view returns(uint256[])",
  ], owner);
  await sent(metro.mint(ownerAddress, ethers.utils.parseEther("10000")));
  await sent(metro.approve(ADDR.V2_ROUTER, ethers.utils.parseEther("10000")));
  await sent(erc20.approve(ADDR.V2_ROUTER, parseUnits("10000", 6)));
  const deadline = (await provider.getBlock("latest")).timestamp + 3600;
  await sent(v2.addLiquidity(metro.address, ADDR.USDC, ethers.utils.parseEther("10000"),
    parseUnits("10000", 6), ethers.utils.parseEther("10000"), parseUnits("10000", 6), ownerAddress, deadline));

  return { owner, ownerAddress, erc20, metro, core, implementation, proxy, adapter, distributor,
    escrow, vault, v2, fundingHash: funding.transactionHash };
}
async function mapleSignature(proxy) {
  const query = `query { getPoolSignature(lender: "${proxy.toLowerCase()}", poolId: "${ADDR.SYRUP_USDC.toLowerCase()}") { deadline bitmap r s v } }`;
  const response = await fetch("https://api.maple.finance/v2/graphql", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ query }),
    signal: AbortSignal.timeout(20_000),
  });
  const data = await response.json();
  assert(response.ok && !data.errors?.length && data.data?.getPoolSignature, `Maple API: ${JSON.stringify(data.errors ?? data)}`);
  const s = data.data.getPoolSignature;
  const vRaw = Number.parseInt(String(s.v), 16);
  const v = vRaw < 2 ? vRaw + 27 : vRaw;
  assert(v === 27 || v === 28, "Maple API returned invalid v");
  const signature = { bitmap: Number(s.bitmap), deadline: Number(s.deadline), v,
    r: s.r.startsWith("0x") ? s.r : `0x${s.r}`,
    s: s.s.startsWith("0x") ? s.s : `0x${s.s}` };
  assert(signature.deadline > (await provider.getBlock("latest")).timestamp, "Maple API signature expired at fork time");
  return signature;
}
async function oneInchSyrup(proxy) {
  const frontend = "https://proxy-app.1inch.com/v2.0";
  const authResponse = await fetch(`${frontend}/auth/token`, {
    headers: { Origin: "https://1inch.com", Referer: "https://1inch.com/" }, signal: AbortSignal.timeout(20_000),
  });
  const auth = await authResponse.json();
  assert(authResponse.ok && auth.access_token, `1inch frontend auth HTTP ${authResponse.status}`);
  const headers = { Authorization: `Bearer ${auth.access_token}`, "Content-Type": "application/json",
    Origin: "https://1inch.com", Referer: "https://1inch.com/" };
  const gasPrice = (await provider.getGasPrice()).toString();
  const quoteQuery = new URLSearchParams({ fromTokenAddress: ADDR.USDC, toTokenAddress: ADDR.SYRUP_USDC,
    amount: rewardTotal.toString(), gasPrice, preset: "maxReturnResult", walletAddress: ADDR.USDC_HOLDER });
  const quoteResponse = await fetch(`${frontend}/v2.2/chain/1/router/v6/quotesv2?${quoteQuery}`, {
    headers, signal: AbortSignal.timeout(20_000),
  });
  const quote = await quoteResponse.json();
  assert(quoteResponse.ok && quote.bestResult?.tokenAmount, `1inch syrup quote HTTP ${quoteResponse.status}`);
  const body = { id: `${globalThis.crypto.randomUUID()}:0`, fromTokenAddress: ADDR.USDC,
    toTokenAddress: ADDR.SYRUP_USDC, fromTokenAmount: rewardTotal.toString(),
    expectedReturnAmount: String(quote.bestResult.tokenAmount), slippage: 1,
    walletAddress: ADDR.USDC_HOLDER, gasPrice, enableEstimate: false, destReceiver: proxy };
  const buildResponse = await fetch(`${frontend}/bff/v1.0/v6.0/1/build?version=2`, {
    method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(20_000),
  });
  const built = await buildResponse.json();
  assert(buildResponse.ok && built.data?.startsWith("0x07ed2379"),
    `1inch syrup build HTTP ${buildResponse.status}, selector ${built.data?.slice(0, 10)}`);
  const iface = new ethers.utils.Interface([
    "function swap(address executor,(address srcToken,address dstToken,address srcReceiver,address dstReceiver,uint256 amount,uint256 minReturnAmount,uint256 flags) desc,bytes data)",
  ]);
  const decoded = iface.parseTransaction({ data: built.data });
  assert(same(decoded.args.desc.srcToken, ADDR.USDC), "1inch source token mismatch");
  assert(same(decoded.args.desc.dstToken, ADDR.SYRUP_USDC), "1inch destination token mismatch");
  assert(same(decoded.args.desc.dstReceiver, proxy), "1inch receiver does not bind this Proxy");
  assert(decoded.args.desc.amount.eq(rewardTotal), "1inch route input is not 100 USDC");
  return { calldata: built.data, minReturn: decoded.args.desc.minReturnAmount.toString(),
    sha256: createHash("sha256").update(built.data).digest("hex"), request: body };
}
async function makeUsers(system, count) {
  const users = [];
  for (let i = 0; i < count; i += 1) {
    const address = userAddress(i);
    await provider.send("anvil_setBalance", [address, hex(oneEther)]);
    await provider.send("anvil_impersonateAccount", [address]);
    const signer = provider.getSigner(address);
    await sent(system.metro.mint(address, oneEther));
    await sent(system.metro.connect(signer).approve(system.core.address, oneEther));
    await sent(system.core.connect(signer).stake(oneEther));
    users.push({ address, signer });
  }
  return users;
}
async function optIn(system, pathName, users, strategy) {
  const spoke = new ethers.Contract(ADDR.V4_SPOKE,
    ["function setUserPositionManager(address,bool)"], system.owner);
  for (const user of users) {
    if (pathName === "compound") await sent(system.core.connect(user.signer).enableAutocompound());
    else await sent(system.core.connect(user.signer).enableAutoStrategy(strategy));
    if (pathName === "v4") await sent(spoke.connect(user.signer).setUserPositionManager(ADDR.V4_GIVER, true));
  }
}
async function distribute(system) { await sent(system.distributor.distribute(rewardTotal)); }
function routeV2(metroAddress) {
  return ABI.encode(["uint8", "bytes"], [0, ABI.encode(["address[]"], [[ADDR.USDC, metroAddress]])]);
}
function authorization(signature) {
  return ABI.encode(["uint256", "uint256", "uint8", "bytes32", "bytes32"],
    [signature.bitmap, signature.deadline, signature.v, signature.r, signature.s]);
}
async function businessRequest(system, pathName, users, state, external) {
  const addresses = users.map((u) => u.address);
  const now = (await provider.getBlock("latest")).timestamp;
  const deadline = now + 3600;
  const strategy = pathName === "syrup" ? strategyId(2, ADDR.SYRUP_USDC)
    : pathName === "v3" ? strategyId(3, ADDR.A_USDC)
      : pathName === "v4" ? strategyId(4)
        : pathName === "maple" ? strategyId(5, ADDR.SYRUP_USDC) : null;
  if (pathName === "compound") {
    const quote = (await system.v2.getAmountsOut(rewardTotal, [ADDR.USDC, system.metro.address]))[1];
    return { strategy, tx: await system.core.populateTransaction.autocompoundBatch(
      addresses, quote.mul(95).div(100), deadline, routeV2(system.metro.address)) };
  }
  const minima = pathName === "v4" ? addresses.map(() => 1) : [];
  const executionData = pathName === "syrup"
    ? ABI.encode(["uint8", "bytes"], [2, external.syrup.calldata])
    : pathName === "maple" && state === "first" ? authorization(external.maple) : "0x";
  return { strategy, tx: await system.core.populateTransaction.executeAutoStrategyBatch(
    strategy, addresses, 1, minima, pathName === "syrup" ? deadline : 0, executionData) };
}
async function sendBusiness(system, pathName, users, state, external) {
  const { tx, strategy } = await businessRequest(system, pathName, users, state, external);
  tx.from = system.ownerAddress;
  const estimate = await provider.estimateGas(tx);
  if (estimate.gt(TX_GAS_CAP)) return { status: "single_tx_limit", estimatedGas: estimate.toString() };
  const block = await provider.getBlock("latest");
  let gasLimit = estimate.mul(120).div(100).add(30_000);
  if (gasLimit.gt(TX_GAS_CAP)) gasLimit = TX_GAS_CAP;
  assert(gasLimit.gte(estimate), "estimated gas exceeds selected gas limit");
  const gasPrice = await provider.getGasPrice();
  const sentTx = await system.owner.sendTransaction({ ...tx, gasLimit, gasPrice });
  const receipt = await localReceipt(sentTx.hash);
  assert(receipt.status === "0x1", `business transaction reverted: ${sentTx.hash}`);
  const after = await system.core.claimable(users[0].address);
  const last = await system.core.claimable(users.at(-1).address);
  const spender = pathName === "compound" ? ADDR.V2_ROUTER : pathName === "syrup" ? ADDR.ONEINCH
    : pathName === "v3" ? ADDR.AAVE_V3_POOL : pathName === "v4" ? ADDR.V4_GIVER : ADDR.MAPLE_ROUTER;
  const allowance = await system.erc20.allowance(system.proxy.address, spender);
  const accountingClean = after.eq(0) && last.eq(0) && allowance.eq(0);
  const effectiveGasPrice = receipt.effectiveGasPrice
    ? ethers.BigNumber.from(receipt.effectiveGasPrice) : gasPrice;
  const gasUsed = ethers.BigNumber.from(receipt.gasUsed);
  return { status: accountingClean ? "passed" : "executed_with_accounting_anomaly",
    strategy, transactionHash: receipt.transactionHash,
    receiptStatus: Number(BigInt(receipt.status)), blockNumber: Number(BigInt(receipt.blockNumber)),
    estimatedGas: estimate.toString(), gasLimit: gasLimit.toString(),
    gasUsed: gasUsed.toString(), gasPrice: gasPrice.toString(),
    effectiveGasPrice: effectiveGasPrice.toString(),
    costEth: ethers.utils.formatEther(gasUsed.mul(effectiveGasPrice)),
    blockGasLimit: block.gasLimit.toString(), singleTransactionGasLimit: TX_GAS_CAP.toString(),
    firstUserPendingAfter: after.toString(), lastUserPendingAfter: last.toString(),
    adapterSpenderAllowanceAfter: allowance.toString() };
}
async function main() {
  assert(SIZES.every((n) => [1, 10, 50, 100, 200].includes(n)) && new Set(SIZES).size === SIZES.length,
    "sizes must be distinct members of 1,10,50,100,200");
  assert(PATHS.every((name) => PATH_TO_G[name]) && new Set(PATHS).size === PATHS.length,
    "paths must be distinct members of compound,syrup,v3,v4,maple");
  const fork = await insistLocalFork();
  const system = await prepareSystem();
  const external = {};
  const blockers = {};
  if (PATHS.includes("maple")) {
    try { external.maple = await mapleSignature(system.proxy.address); }
    catch (error) { blockers.maple = String(error); }
  }
  if (PATHS.includes("syrup")) {
    try { external.syrup = await oneInchSyrup(system.proxy.address); }
    catch (error) { blockers.syrup = String(error); }
  }
  const output = { runId: `2026-09-29-eth26077998-gas-${Date.now()}`, generatedAtUtc: new Date().toISOString(),
    rpc: RPC, fork, deployment: { owner: system.ownerAddress, metro: system.metro.address,
      core: system.core.address, implementation: system.implementation.address,
      proxy: system.proxy.address, distributor: system.distributor.address,
      escrow: system.escrow.address, vault: system.vault.address,
      usdcFundingHolder: ADDR.USDC_HOLDER, usdcFundingTransaction: system.fundingHash },
    sources: {}, external: { maple: external.maple ?? null,
      oneInchSyrup: external.syrup ? { ...external.syrup, calldata: external.syrup.calldata } : null },
    blockedPaths: blockers, samples: [],
    unavailableOneInchAssets: {
      "G-02": "USDT: official frontend PMM signature binds quoted EOA; exclusion returns unsupported selector",
      "G-03": "WBTC: official frontend PMM signature binds quoted EOA; exclusion returns unsupported selector",
      "G-04": "GHO: official frontend returns unsupported selector",
      "G-05": "XAUT: official frontend returns unsupported selector",
      evidence: "oneinch-frontend-eoa-wallet-proxy-receiver.json; oneinch-frontend-excluding-pmm.json",
    } };
  for (const artifactPath of ["out-core/metro.sol/MetroToken.json", "out-core/xMETRO.sol/xMETRO.json",
    "out-core/RewardDistributor.sol/RewardDistributor.json", "out-core/ThorMigrationEscrow.sol/ThorMigrationEscrow.json",
    "out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json",
    "out-deploy/ERC1967Proxy.sol/ERC1967Proxy.json", "out-fork-v2/CommissionVault.sol/CommissionVault.json"]) {
    output.sources[artifactPath] = createHash("sha256").update(await fs.readFile(path.join(ROOT, artifactPath))).digest("hex");
  }
  await fs.mkdir(path.dirname(OUT), { recursive: true });
  await fs.writeFile(OUT, `${JSON.stringify(output, null, 2)}\n`);
  let baseSnapshot = await provider.send("evm_snapshot", []);
  for (const count of SIZES) {
    assert(await provider.send("evm_revert", [baseSnapshot]), "base snapshot could not be restored");
    baseSnapshot = await provider.send("evm_snapshot", []);
    const users = await makeUsers(system, count);
    let sizeSnapshot = await provider.send("evm_snapshot", []);
    for (const pathName of PATHS) {
      assert(await provider.send("evm_revert", [sizeSnapshot]), "size snapshot could not be restored");
      sizeSnapshot = await provider.send("evm_snapshot", []);
      const sample = { g: PATH_TO_G[pathName], path: pathName, users: count,
        rewardTotal: rewardTotal.toString(), perUserStakeMetro: oneEther.toString(),
        state: {} };
      try {
        if (blockers[pathName]) throw new Error(blockers[pathName]);
        const strategy = pathName === "syrup" ? strategyId(2, ADDR.SYRUP_USDC)
          : pathName === "v3" ? strategyId(3, ADDR.A_USDC)
            : pathName === "v4" ? strategyId(4)
              : pathName === "maple" ? strategyId(5, ADDR.SYRUP_USDC) : null;
        await optIn(system, pathName, users, strategy);
        await distribute(system);
        sample.state.first = await sendBusiness(system, pathName, users, "first", external);
        if (["passed", "executed_with_accounting_anomaly"].includes(sample.state.first.status)) {
          await distribute(system);
          sample.state.existing = await sendBusiness(system, pathName, users, "existing", external);
        }
      } catch (error) {
        sample.error = String(error?.reason ?? error?.message ?? error).slice(0, 600);
      }
      output.samples.push(sample);
      await fs.writeFile(OUT, `${JSON.stringify(output, null, 2)}\n`);
      process.stderr.write(`${sample.g} ${count} users: ${sample.error ?? `${sample.state.first?.status}/${sample.state.existing?.status ?? "none"}`}\n`);
    }
  }
  output.completedAtUtc = new Date().toISOString();
  await fs.writeFile(OUT, `${JSON.stringify(output, null, 2)}\n`);
  process.stdout.write(`${OUT}\n`);
}

main().catch((error) => {
  process.stderr.write(`${error.reason ?? error.message ?? String(error)}\n`);
  process.exitCode = 1;
});
