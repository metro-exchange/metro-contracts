# Staging

Staging is the test copy of the Metro contracts on Base mainnet (chainId 8453). Production runs on Ethereum (chainId 1). The addresses for both live in [`deployments/`](../deployments): `staging.json` and `ethereum.json`.

Nothing in this folder changes the production contracts. Staging builds from the same `packages/` source and runs the same production deploy scripts, with the differences listed below applied to a temporary copy.

## What differs from production

| | Production (Ethereum) | Staging (Base) |
|---|---|---|
| Timers | Source values | Shortened by [`timers.patch`](timers.patch) at build time |
| Tokens | Real USDC, THOR, yTHOR, vTHOR, uTHOR | Owner-mintable test tokens, test uTHOR/vTHOR vaults, a faucet |
| Aave, Maple | Real protocols | Mocks from `packages/xmetro/test/mocks` |
| Uniswap V2/V3, 1inch | Real routers | Real Base routers; V2 pools seeded with test tokens |
| Owner | Safe | The "xMetro mgmt" wallet `0x0D5b2b90dc75D4c084590a24385EB2bAe714Dc4a` (seed in 1Password) |

Timer values in staging:

| Constant | Production | Staging |
|---|---|---|
| `UNSTAKE_DELAY` | 72 hours | 30 minutes |
| `THOR_EXIT_DELAY` / `THOR_EXIT_FULL_TIME` | 30 / 90 days | 1 / 3 hours |
| `YTHOR_EXIT_DELAY` / `YTHOR_EXIT_RAMP` | 120 days / 4 years | 4 / 12 hours |
| `CONTRIBUTOR_CLIFF` / `CONTRIBUTOR_DURATION` | 180 days / 2.5 years | 6 / 6 hours |

`0x19b293d784331f33a8043724862E6c78CE5800ce` is the staging operator: CommissionVault operator, MetroDistributor operator, auto-compound keeper and Maple mock permission admin. The Metro worker signs with it.

## Two layers

- **Fixtures**: test tokens, protocol mocks, uTHOR/vTHOR, the faucet and the USDC pools for the swap outputs. Testers hold balances in them, so they are rarely redeployed. Deployed by [`script/DeployFixtures.s.sol`](script/DeployFixtures.s.sol).
- **System**: METRO, xMETRO, ThorMigrationEscrow, the DeFi adapter, MetroDistributorV1, CommissionVault, RateLimitedForwarder and the METRO/USDC pool. Redeploy it when the contracts change. It reuses the fixtures recorded in `deployments/staging.json`.

`deployments/staging.json` records each layer, the source commit of the system, deploy blocks for indexers, and older addresses under `retired`.

## Test contracts

Each staging-only contract has its own file in [`contracts/`](contracts):

| Contract | Stands in for |
|---|---|
| `TestUSDC`, `TestTHOR`, `TestYTHOR` | USDC, THOR, yTHOR |
| `TestUSDT`, `TestWBTC`, `TestGHO`, `TestXAUT` | Reward swap outputs |
| `TestExtraToken` | A token outside the swap allowlist |
| `TestUTHOR` | uTHOR: staked THOR paying USDC (`addRewards`) |
| `TestVTHOR` | vTHOR: staked THOR |
| `TestTokenFaucet` | Hands out THOR, yTHOR, USDC, uTHOR and vTHOR to testers |

The tokens extend `ERC20Mintable` (owner-only mint) and the vaults extend `TestThorVault` (ERC-4626 over TestTHOR). The Aave, Maple and syrupUSDC mocks are the ones the xmetro tests use, imported from `packages/xmetro/test/mocks`. The contracts on Base today were deployed before this split, from the same code without the per-token wrappers.


## Deploying

Requirements: Foundry 1.7.1, `jq`, and for live deploys the 1Password CLI (`op`) signed in to the Thorswap vault. Install the package dependencies once:

```bash
(cd packages/xmetro && forge install foundry-rs/forge-std@v1.12.0 OpenZeppelin/openzeppelin-contracts@v5.5.0 --no-git)
(cd packages/commission && forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.6.1 --no-git)
```

Then, from the repo root:

```bash
staging/script/deploy.sh system            # rehearsal on a local fork of Base: no keys, nothing sent on-chain
staging/script/deploy.sh system --live     # deploy to Base
staging/script/deploy.sh fixtures          # rehearse a fixtures rebuild
staging/script/deploy.sh fixtures --live
```

Always run the rehearsal first. It starts `anvil` on a fork of Base, deploys as the staging owner and writes the result to `staging/output/<layer>-rehearsal.json`. Set `BASE_RPC_URL` to a private RPC; the public one rate-limits.

A live deploy:

1. Refuses to run with uncommitted changes under `packages/` or `staging/`, so the recorded source commit is exact.
2. Reads the seed phrase from 1Password (`STAGING_SIGNER_OP_REF` in [`staging.env`](staging.env)) into a private temp file that is deleted on exit, and checks that it derives the staging owner.
3. Asks you to type `deploy`.
4. Writes the new layer into `deployments/staging.json`, moves the previous addresses to `retired.<layer>-<date>`, and saves the receipts in `staging/runs/`. Commit both.

All deploy parameters are in [`staging.env`](staging.env); fixture addresses come from `deployments/staging.json`.

### What a system deploy does

1. Copies `packages/xmetro` and `packages/commission` to a temp folder and applies `timers.patch`.
2. Runs the production scripts: `packages/xmetro/script/Deploy.s.sol`, `packages/commission/script/Deploy.s.sol`, then `packages/xmetro/script/DeployMetroDistributor.s.sol` (V1).
3. Deploys RateLimitedForwarder with `cast send --create`. The production script `DeployRateLimitedForwarder.s.sol` requires a Safe owner, and the staging owner is a plain wallet.
4. Sends the owner batch that `DeployMetroDistributor` prints: binds the vault, the distributor, the forwarder and xMETRO, then unpauses the forwarder.
5. Staging-only steps: grants the new adapter the Maple mock lender permission, seeds the METRO/USDC pool (the owner is a METRO minter only for that mint), and funds the forwarder with TestUSDC.
6. Checks every binding and that xMETRO's runtime code matches the short-timer build.

### After a system deploy

The Metro app does not read `deployments/staging.json` yet. Its staging addresses are copied by hand into `apps/dex-ui/src/config/metro-deployments.ts`, `packages/core/src/metro-staking.ts`, `packages/core/src/thor-migration.ts` and `packages/contracts/src/testbed-config.ts` in the metro repo. Update them, including the deploy blocks. The migration window starts again, and positions on the old contracts stay on the retired addresses.

## When `timers.patch` stops applying

`deploy.sh` stops if a change to `packages/xmetro/src/xMETRO.sol` or `XMetroCoreLogic.sol` moves the lines around the timers. Regenerate the patch from the current source:

```bash
tmp=$(mktemp -d) && mkdir "$tmp/src"
cp packages/xmetro/src/xMETRO.sol packages/xmetro/src/XMetroCoreLogic.sol "$tmp/src/"
(cd "$tmp" && git init -q && git add -A && git -c commit.gpgsign=false commit -qm base)
# edit the constants in $tmp/src to the staging values in the table above
(cd "$tmp" && git diff) > staging/timers.patch
```

Then run the rehearsal. It compares the deployed xMETRO code with the patched build, so a wrong patch fails there.

## Faucet and test vaults

The faucet never mints: the owner tops it up by minting test tokens straight to it, and can tune or drain it.

```bash
cast send <token> "mint(address,uint256)" <faucet> <amount> --rpc-url base --mnemonic <file>
cast send <faucet> "setBaseAmounts(uint256[5])" "[1000e18,1000e18,500e18,500e18,100e6]"   # THOR, yTHOR, uTHOR, vTHOR, USDC
cast send <faucet> "setSpread(uint16)" 2000
cast send <faucet> "setCooldown(uint32)" 300
cast send <faucet> "withdraw(address,address,uint256)" <token> <to> <amount>
```

uTHOR pays TestUSDC to its holders when the owner calls `addRewards(amount)`; vTHOR pays nothing.
