# xMETRO Integration Guide

This directory is the entry point for frontend, backend, and operations integration. The documentation does not imply that every external-protocol scenario has passed; use the linked execution records for actual status.

## Reading order

1. [Existing-feature migration](docs/existing-features.md): changed THOR/yTHOR entrypoints and preserved staking, rewards, Contributor, and Auto-Compound behavior.
2. [New features](docs/new-features.md): reward weight, supply cap, manual/automatic swaps and deposits, Keeper batches, commission routing, and emergency distribution.
3. [Contract API and roles](docs/contract-api.md): permissions, parameters, approvals, configuration calls, handover, and readbacks.
4. [Base QA template](testing/base/BASE_ONCHAIN_FUNCTIONAL_TEST_CHECKLIST.md) (actual Base hashes are in the QA branch) and [Ethereum mainnet fork checklist](testing/ethereum-fork/CHECKLIST.md), with [fork results](testing/ethereum-fork/RESULTS.md).

See the [project README](../README.md) for architecture and deployment, and the [contract function reference](../CONTRACT_FUNCTION_REFERENCE.md) for the full entrypoint index. Contract code remains in `src/`; tests remain in `test/`.

## Environments and evidence

This source handoff does not require the project-facing Base functional checklist to be completed by the deployment team. The receiving project may execute those on-chain scenarios after handover. The previously reviewed F-01 behavior, a fee-bearing 1inch Affiliate transaction, and a new full-fork evidence package are not prerequisites for uploading these sources; the linked test records still show exactly what did and did not pass.

The Base checklist tracks the **new project-facing deployment** separately from a historical rapid-QA run. The older run checked 36 of 37 groups; N-04 was executed but did not pass its historical-pending assertion. Its transaction hashes and short time constants are historical evidence only, not passing results for the new deployment.

The new Base QA environment is a fresh deployment with the agreed longer QA periods and owner-controlled TestToken minting. The Base QA branch records its public addresses, mock protocol contracts, roles, and time settings in `config/base-qa.json`, and its deployment transaction hashes in the Base checklist. The production branch's local Base files are templates, not a second deployment or evidence that the production bytecode was deployed to Base. Until project management and backend addresses are supplied, QA deployment ownership remains with the deployment team; a later handover is a separate set of transactions.

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
