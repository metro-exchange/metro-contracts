// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20Mintable} from "xmetro-mocks/ERC20Mintable.sol";

/// @notice Staging stand-in for THOR, migrated to METRO and staked into uTHOR/vTHOR. Only the owner can mint.
contract TestTHOR is ERC20Mintable {
    constructor() ERC20Mintable("Test THOR", "TestTHOR", 18) {}
}
