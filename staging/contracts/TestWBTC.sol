// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20Mintable} from "xmetro-mocks/ERC20Mintable.sol";

/// @notice Staging stand-in for WBTC, a reward swap output. Only the owner can mint.
contract TestWBTC is ERC20Mintable {
    constructor() ERC20Mintable("Test WBTC", "TestWBTC", 8) {}
}
