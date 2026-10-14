// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {XMetroDeFiAdapter} from "../../src/XMetroDeFiAdapter.sol";

/// @notice Storage-compatible test release used by deployment/upgrade/Fork runbooks.
contract XMetroDeFiAdapterV2 is XMetroDeFiAdapter {
    function implementationVersion() external pure override returns (uint64) {
        return 2;
    }
}
