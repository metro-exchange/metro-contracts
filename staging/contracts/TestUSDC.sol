// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20Mintable} from "xmetro-mocks/ERC20Mintable.sol";

/// @notice Staging stand-in for USDC, the reward token and the faucet payout. Only the owner can mint.
contract TestUSDC is ERC20Mintable {
    constructor() ERC20Mintable("Test USDC", "TestUSDC", 6) {}
}
