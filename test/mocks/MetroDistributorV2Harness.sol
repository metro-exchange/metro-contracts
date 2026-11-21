// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MetroDistributorV2} from "../../src/MetroDistributorV2.sol";

contract MetroDistributorV2Harness is MetroDistributorV2 {
    using SafeERC20 for IERC20;

    address private immutable swapSink;
    uint256 private metroOut;

    constructor(address xMetro_, address treasury_, address owner_, address swapSink_)
        MetroDistributorV2(xMetro_, treasury_, owner_)
    {
        swapSink = swapSink_;
    }

    function setMetroOut(uint256 value) external {
        metroOut = value;
    }

    function _buyMetro(uint256 usdcIn) internal override returns (uint256) {
        rewardToken.safeTransfer(swapSink, usdcIn);
        return metroOut;
    }
}
