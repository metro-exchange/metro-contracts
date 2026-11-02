# xMETRO Integration Guide

Current swap and compound examples require Adapter implementation version 2 and the [new swap envelope](docs/new-features.md#swap-execution-data). Core, Escrow and Distributor now expose two-step ownership interfaces; regenerate clients from the corresponding ABI. MetroToken, Escrow and Distributor business failures use custom errors from their matching ABI. The four Core reward entrypoint signatures are unchanged. Use the ABI and examples matching the actual deployed revision; existing configuration JSON and historical addresses are not updated by this source change.

## October 24 source update

This source version changes yTHOR exits to 20%-100% of the converted METRO principal. Production opens exits after 120 days and reaches 100% over the following `4 * 365 days`; Base QA keeps its 4-hour delay and 12-hour ramp. Repeated migrations, independent position IDs, one complete exit per position, and `1e24` reward-debt precision are retained.

Only THOR/yTHOR migration positions owned by `migrationRewardExcludedAddress()` earn no USDC rewards and are excluded from the allocation denominator. Ordinary stakes, Contributor shares, received free xMETRO and migration payouts staked after exit retain normal prospective rewards. Existing earned rewards and fractional entitlements are preserved.

The existing Base QA deployment and its address/configuration records remain unchanged. Use the ABI and examples from that deployment's revision (QA baseline `60754e05436c6c8056b60eac481d0bdc96a89d4c`) with its existing addresses. This version's ABI/examples target newly created local instances or a future deployment requested by the project. Source changes do not update an immutable deployed Core or migrate its storage.

This directory is the entry point for frontend, backend, and operations integration. The documentation does not imply that every external-protocol scenario has passed; use the linked execution records for actual status.

Build with the pinned Solidity 0.8.38 / Osaka profiles; the target chain must support transient storage and all emitted instructions. [Build and validation notes](../README.md#october-30-audit-remediation) and [initial configuration events](docs/existing-features.md#events-and-indexing) describe the current source.

## Reading order

1. [Existing-feature migration](docs/existing-features.md): changed THOR/yTHOR entrypoints and preserved staking, rewards, Contributor, and Auto-Compound behavior.
2. [New features](docs/new-features.md): reward weight, supply cap, manual/automatic swaps and deposits, Keeper batches, commission routing, and emergency distribution.
3. [Contract API and roles](docs/contract-api.md): permissions, parameters, approvals, configuration calls, handover, and readbacks.
4. [Base QA template](testing/base/BASE_ONCHAIN_FUNCTIONAL_TEST_CHECKLIST.md) (actual Base hashes are in the QA branch) and [Ethereum mainnet fork checklist](testing/ethereum-fork/CHECKLIST.md), with [fork results](testing/ethereum-fork/RESULTS.md).

See the [project README](../README.md) for architecture and deployment, and the [contract function reference](../CONTRACT_FUNCTION_REFERENCE.md) for the full entrypoint index. Contract code remains in `src/`; tests remain in `test/`.

## Environments and evidence

This source handoff does not require the project-facing Base functional checklist to be completed by the deployment team. The receiving project may execute those on-chain scenarios after handover. The October 21 update includes the F-01 reward precision fix. See the latest results section for current local validation; previous fork results remain historical. Affiliate transactions and a new Base deployment are outside this update.

The Base checklist tracks the **new project-facing deployment** separately from a historical rapid-QA run. The older run checked 36 of 37 groups; N-04 was executed but did not pass its historical-pending assertion. Its transaction hashes and short time constants are historical evidence only, not passing results for the new deployment.

The recorded Base QA environment is an earlier deployment with the agreed longer QA periods and owner-controlled TestToken minting. The Base QA branch records its public addresses, mock protocol contracts, roles, and time settings in `config/base-qa.json`, and its deployment transaction hashes in the Base checklist. The production branch's local Base files are templates, not a second deployment or evidence that the production bytecode was deployed to Base. Ownership and role values are deployment-time snapshots; later handovers must be verified separately.

Ethereum fork tests use production time constants and real Ethereum protocols where available. Fork execution does not broadcast to Ethereum mainnet. See the checklist and results for which scenarios were actually run, skipped, or blocked.

## Handover material

```text
integration/
├── README.md
├── docs/
│   ├── existing-features.md
│   ├── new-features.md
│   └── contract-api.md
├── abi/                         # ABI files generated from the delivered artifacts
├── config/
│   ├── base-qa.json             # Base QA addresses/settings on the QA branch; template on production
│   └── ethereum.json            # Production addresses when deployed
├── examples/                    # User and backend call examples
└── testing/
    ├── base/
    │   └── BASE_ONCHAIN_FUNCTIONAL_TEST_CHECKLIST.md
    └── ethereum-fork/
        ├── CHECKLIST.md
        ├── RESULTS.md
        └── evidence/
```

No private keys, wallet seed phrases, unpublished API credentials, or local signer files belong in this directory. Base Mock contracts follow the integration-facing ABI/events for the tested paths, but they do not reproduce the complete Aave or Maple protocols.
