// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {MetroToken} from "../../src/metro.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {ThorMigrationEscrow} from "../../src/ThorMigrationEscrow.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";

contract CoreIntegrationTest is Test {
    MetroToken internal metro;
    xMETRO internal xmetro;
    ThorMigrationEscrow internal escrow;
    RewardDistributor internal distributor;
    ERC20Mintable internal thor;
    ERC20Mintable internal yThor;
    ERC20Mintable internal usdc;
    MockCommissionVault internal vault;

    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal forfeiture = makeAddr("forfeiture");

    function setUp() public {
        thor = new ERC20Mintable("THOR", "THOR", 18);
        yThor = new ERC20Mintable("yTHOR", "yTHOR", 18);
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        xmetro = new xMETRO(address(this), address(metro), address(usdc), forfeiture, 20_000);
        distributor = new RewardDistributor(address(xmetro), address(this));
        vault = new MockCommissionVault(address(usdc), 0, address(distributor));
        escrow = new ThorMigrationEscrow(address(this), address(xmetro), address(thor), address(yThor), block.timestamp);

        metro.setMinter(address(xmetro), true);
        xmetro.setMigrationEscrow(address(escrow));
        xmetro.setRewardDistributor(address(distributor));
        distributor.setOperator(address(this), true);
        escrow.setCaps(10_000_000 ether, 10_000_000 ether);
        escrow.setRatios(1e18, 1e18);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
    }

    function _migrate(address user, ERC20Mintable token, uint256 amount, bool isYThor) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(escrow), amount);
        vm.prank(user);
        if (isYThor) escrow.migrateYThor(amount);
        else escrow.migrateThor(amount);
    }

    function test_EndToEndMigrationsRewardsCommissionAndLiquidExits() public {
        _migrate(userA, thor, 100 ether, false);
        _migrate(userB, yThor, 100 ether, true);
        assertEq(xmetro.rewardWeightOf(userA), 100 ether);
        assertEq(xmetro.rewardWeightOf(userB), 200 ether);
        assertEq(metro.totalSupply(), 200 ether);

        vault.setTargetBalance(30e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(2_000);
        usdc.mint(address(this), 300e6);
        usdc.approve(address(distributor), 300e6);
        distributor.distribute(300e6);

        assertEq(usdc.balanceOf(address(vault)), 30e6);
        assertEq(xmetro.claimable(userA), 90e6);
        assertEq(xmetro.claimable(userB), 180e6);

        vm.warp(block.timestamp + 14400 seconds);
        vm.prank(userA);
        (uint256 thorPayout, uint256 thorForfeited) = xmetro.requestThorExit(0);
        vm.prank(userB);
        (uint256 yPayout, uint256 yForfeited) = xmetro.exitYThor(0, xMETRO.ExitMode.Liquid);

        assertEq(thorPayout, 100 ether);
        assertEq(thorForfeited, 0);
        assertEq(yPayout, 10 ether);
        assertEq(yForfeited, 90 ether);
        assertEq(metro.balanceOf(forfeiture), 90 ether);

        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY());
        vm.prank(userA);
        xmetro.withdrawThor(0);
        vm.prank(userB);
        xmetro.withdrawYThor(0);
        assertEq(metro.balanceOf(userA), 100 ether);
        assertEq(metro.balanceOf(userB), 10 ether);
    }

    function test_ContributorPathRemainsSixMonthCliffAndTwoPointFiveYears() public {
        metro.setMinter(address(this), true);
        metro.mint(address(this), 100 ether);
        metro.approve(address(xmetro), 100 ether);
        xmetro.setContributor(address(this), true);
        xmetro.stakeContributor(100 ether, userA);

        xMETRO.VestingSchedule memory schedule = xmetro.contributorVesting(userA, 0);
        assertEq(schedule.startTime, block.timestamp + xmetro.CONTRIBUTOR_CLIFF());
        assertEq(schedule.duration, xmetro.CONTRIBUTOR_DURATION());
    }

    function test_RepeatedMigrationAfterExitPreservesCapsAndRollback() public {
        _migrate(userA, thor, 100 ether, false);
        _migrate(userA, thor, 50 ether, false);
        _migrate(userA, yThor, 100 ether, true);
        _migrate(userA, yThor, 50 ether, true);
        assertEq(xmetro.thorPositionCount(userA), 2);
        assertEq(xmetro.yThorPositionCount(userA), 2);
        vm.warp(block.timestamp + 4 hours);
        vm.startPrank(userA);
        xmetro.exitAndStakeThor(1);
        xmetro.exitAndStakeThor(0);
        xmetro.exitYThor(1, xMETRO.ExitMode.Stake);
        xmetro.exitYThor(0, xMETRO.ExitMode.Stake);
        vm.stopPrank();
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(escrow.migratedThor(), 150 ether);
        assertEq(escrow.migratedYThor(), 150 ether);
        _migrate(userA, thor, 10 ether, false);
        _migrate(userA, yThor, 10 ether, true);
        assertEq(xmetro.thorPositionCount(userA), 3);
        assertEq(xmetro.yThorPositionCount(userA), 3);
        metro.setMinter(address(xmetro), false);
        thor.mint(userA, 5 ether);
        vm.startPrank(userA);
        thor.approve(address(escrow), 5 ether);
        vm.expectRevert(bytes("MetroToken: not minter"));
        escrow.migrateThor(5 ether);
        vm.stopPrank();
        assertEq(xmetro.thorPositionCount(userA), 3);
        assertEq(escrow.migratedThor(), 160 ether);
        assertEq(thor.balanceOf(userA), 5 ether);
        assertEq(xmetro.lockedShares(userA), 20 ether);
    }
}
