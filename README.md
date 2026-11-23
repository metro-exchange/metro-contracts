# Metro Contracts

Smart contracts for Metro Exchange. Each system lives in its own Foundry project under `packages/`, with its own compiler settings, dependencies, tests and deployment scripts. Build and test each package from its own directory.

| Package | Contents | Toolchain |
|---|---|---|
| [`packages/xmetro`](packages/xmetro) | METRO token, xMETRO staking core, DeFi adapter, THOR/yTHOR migration escrow, reward distributor | solc 0.8.38, Osaka, OpenZeppelin v5.5.0 |

## Working with a package

```bash
cd packages/xmetro
forge install foundry-rs/forge-std@v1.12.0
forge install OpenZeppelin/openzeppelin-contracts@v5.5.0
forge build
forge test
```

See each package's README for profiles, deployment and integration details.
