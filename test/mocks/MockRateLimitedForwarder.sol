// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockRateLimitedForwarder {
    IERC20 public immutable token;
    address public recipient;
    bool public paused;
    uint256 public releasable = type(uint256).max;

    constructor(address token_, address recipient_) {
        token = IERC20(token_);
        recipient = recipient_;
    }

    function setRecipient(address value) external {
        recipient = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setReleasable(uint256 value) external {
        releasable = value;
    }

    function tryForward() external returns (uint256 forwarded) {
        if (paused) return 0;
        forwarded = Math.min(releasable, token.balanceOf(address(this)));
        if (forwarded != 0) token.transfer(recipient, forwarded);
    }
}
