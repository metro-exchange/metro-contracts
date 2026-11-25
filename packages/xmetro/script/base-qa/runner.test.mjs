import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

process.env.BASE_QA_RUN_ID = 'runner-test-' + process.pid;
const { ethers, runDir, sendStep } = await import('./runner.mjs');

function fakeChain({ revertsOnChain }) {
  let nonce = 0;
  let sendFailures = 0;
  const receipts = {};
  const provider = {
    getTransactionCount: async () => nonce,
    estimateGas: async () => ethers.BigNumber.from(100000),
    getGasPrice: async () => ethers.BigNumber.from(1000000000),
    call: async () => ethers.utils.defaultAbiCoder.encode(['uint256'], [0]),
    getBalance: async () => ethers.utils.parseEther('1'),
    getCode: async () => '0x6080',
    async send(method, [arg]) {
      if (method === 'eth_getTransactionReceipt') return receipts[arg] ?? null;
      if (method === 'eth_getBlockByHash') return { timestamp: '0x1' };
      if (method === 'eth_getTransactionByHash') return { hash: arg };
      if (method !== 'eth_sendRawTransaction') throw new Error('Unexpected RPC ' + method);
      if (sendFailures++ === 0) throw new Error('socket hang up');
      const tx = ethers.utils.parseTransaction(arg);
      receipts[tx.hash] = {
        status: revertsOnChain(tx) ? '0x0' : '0x1', blockHash: '0x01', blockNumber: '0x1',
        gasUsed: '0x1', effectiveGasPrice: '0x1',
        contractAddress: ethers.utils.getContractAddress({ from: tx.from, nonce: tx.nonce })
      };
      nonce++;
    }
  };
  return provider;
}

test.after(() => rm(runDir, { recursive: true, force: true }));

test('a prepared step whose transaction expires before broadcast is archived and rebuilt on resume', async () => {
  const startTimes = [];
  const provider = fakeChain({ revertsOnChain: tx => tx.data === startTimes[0] });
  const ctx = {
    provider, wallets: { deployer: ethers.Wallet.createRandom() },
    state: { steps: {}, contracts: {} }, persist: async () => {}
  };
  const step = {
    id: 'Escrow', expectContract: true,
    buildTx: async () => {
      startTimes.push(ethers.utils.hexZeroPad(ethers.utils.hexlify(1000 + startTimes.length), 32));
      return { data: startTimes.at(-1) };
    }
  };

  await assert.rejects(sendStep(ctx, step), /socket hang up/);
  assert.equal(ctx.state.steps.Escrow.status, 'prepared');

  await assert.rejects(sendStep(ctx, step), /transaction reverted; archived/);
  assert.equal(ctx.state.steps.Escrow, undefined);
  assert.ok(existsSync(path.join(runDir, 'transactions', 'Escrow.reverted-0.json')));

  const confirmed = await sendStep(ctx, step);
  assert.equal(startTimes.length, 2);
  assert.equal(confirmed.status, 'confirmed');
  assert.equal(confirmed.nonce, 1);
  assert.equal(ctx.state.contracts.Escrow, confirmed.contractAddress);
});
