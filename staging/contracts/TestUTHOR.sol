// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestThorVault} from "./TestThorVault.sol";

/// @notice Staging copy of THORSwap's uTHOR: THOR staked for USDC rewards, which the owner adds with addRewards.
contract TestUTHOR is TestThorVault {
    constructor(IERC20 thor, IERC20 usdc) TestThorVault(thor, usdc, "USDC-yield THOR", "uTHOR") {}
}
