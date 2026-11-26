// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20Mintable} from "xmetro-mocks/ERC20Mintable.sol";

/// @notice Staging stand-in for a token outside the swap allowlist, for negative tests. Only the owner can mint.
contract TestExtraToken is ERC20Mintable {
    constructor() ERC20Mintable("Test Extra Token", "TestExtraToken", 18) {}
}
