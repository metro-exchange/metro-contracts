// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";

import {xMETRO} from "../../src/xMETRO.sol";
import {MetroToken} from "../../src/metro.sol";
import {ERC20Mintable} from "./ERC20Mintable.sol";

abstract contract MetroDistributorFixture is Test {
    ERC20Mintable internal usdc;
    MetroToken internal metro;

    function _deployTokens() internal {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
    }

    function _deployCoreWithStaker(uint256 stakeAmount) internal returns (xMETRO core) {
        core = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);
        address staker = makeAddr("staker");
        metro.mint(staker, stakeAmount);
        vm.startPrank(staker);
        metro.approve(address(core), stakeAmount);
        core.stake(stakeAmount);
        vm.stopPrank();
    }
}
