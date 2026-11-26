// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20Mintable} from "xmetro-mocks/ERC20Mintable.sol";

/// @notice Staging stand-in for XAUT, a reward swap output. Only the owner can mint.
contract TestXAUT is ERC20Mintable {
    constructor() ERC20Mintable("Test XAUT", "TestXAUT", 6) {}
}
