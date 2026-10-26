// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockOneInchExecutor {}

/// @notice Test-only Router with the 1inch AggregationRouterV6 `swap` ABI.
contract MockOneInchRouter {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    bool public misreport;

    function setMisreport(bool value) external {
        misreport = value;
    }

    function swap(address executor, SwapDescription calldata desc, bytes calldata data)
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount)
    {
        require(msg.value == 0 && executor.code.length != 0 && data.length != 0, "Mock1inch: bad route");
        require(desc.srcToken.transferFrom(msg.sender, address(this), desc.amount), "Mock1inch: pull failed");
        require(desc.dstToken.transfer(desc.dstReceiver, desc.amount), "Mock1inch: output failed");
        return (desc.amount + (misreport ? 1 : 0), desc.amount);
    }
}
