// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestThorVault} from "./TestThorVault.sol";

/// @notice Staging copy of THORSwap's vTHOR: staked THOR without a separate reward token.
contract TestVTHOR is TestThorVault {
    constructor(IERC20 thor) TestThorVault(thor, IERC20(address(0)), "Staked THOR", "vTHOR") {}
}
