# xMETRO Integration Guide

This directory is the entry point for frontend, backend, and operations integration. The documentation does not imply that every external-protocol scenario has passed; use the linked execution records for actual status.

This Base QA branch changes seven waiting periods. The linked Ethereum fork results were recorded on the production-time build and must not be presented as test results for this QA bytecode.

## Reading order

1. [Existing-feature migration](docs/existing-features.md): changed THOR/yTHOR entrypoints and preserved staking, rewards, Contributor, and Auto-Compound behavior.
2. [New features](docs/new-features.md): reward weight, supply cap, manual/automatic swaps and deposits, Keeper batches, commission routing, and emergency distribution.
3. [Contract API and roles](docs/contract-api.md): permissions, parameters, approvals, configuration calls, handover, and readbacks.
4. [Base on-chain QA](testing/base/BASE_ONCHAIN_FUNCTIONAL_TEST_CHECKLIST.md) and [Ethereum mainnet fork checklist](testing/ethereum-fork/CHECKLIST.md), with [fork results](testing/ethereum-fork/RESULTS.md).

See the [project README](../README.md) for architecture and deployment, and the [contract function reference](../CONTRACT_FUNCTION_REFERENCE.md) for the full entrypoint index. Contract code remains in `src/`; tests remain in `test/`.

## Environments and evidence

This Base deployment is intended for the receiving project to run the O/N functional scenarios after handover; unchecked scenarios are not prerequisites for uploading the source and deployment information. The previously reviewed F-01 behavior, a fee-bearing 1inch Affiliate transaction, and a new full-fork evidence package are outside this upload scope. The recorded results remain unchanged and must not be represented as passes.

The Base checklist tracks the **new project-facing deployment** separately from a historical rapid-QA run. The older run checked 36 of 37 groups; N-04 was executed but did not pass its historical-pending assertion. Its transaction hashes and short time constants are historical evidence only, not passing results for the new deployment.

The new Base QA environment is a fresh deployment with the agreed longer QA periods and owner-controlled TestToken minting. Public addresses, mock protocol contracts, roles, and time settings are in `config/base-qa.json`; the on-chain transaction hashes are in the Base checklist. Raw receipt files stay local and are not part of the upload. Until project management and backend addresses are supplied, local deployment ownership remains with the deployment team; a later handover is a separate set of transactions.

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
│   ├── base-qa.json             # Fresh Base QA addresses and public settings only
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
