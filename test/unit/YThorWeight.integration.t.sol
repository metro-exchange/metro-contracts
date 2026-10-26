// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {MetroToken} from "../../src/metro.sol";
import {ThorMigrationEscrow} from "../../src/ThorMigrationEscrow.sol";
import {xMETRO as XMetroCore} from "../../src/xMETRO.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";

contract YThorWeightIntegrationTest is Test {
    ERC20Mintable internal usdc;
    ERC20Mintable internal thor;
    ERC20Mintable internal yThor;
    MetroToken internal metro;
    XMetroCore internal xmetro;
    ThorMigrationEscrow internal escrow;

    address internal userA = makeAddr("active-yThor-a");
    address internal userB = makeAddr("active-yThor-b");

    function xMETRO() external view returns (address) {
        return address(xmetro);
    }

    function rewardToken() external view returns (address) {
        return address(usdc);
    }

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        thor = new ERC20Mintable("THOR", "THOR", 18);
        yThor = new ERC20Mintable("yTHOR", "yTHOR", 18);
        metro = new MetroToken("METRO", "METRO", address(this));
        xmetro = new XMetroCore(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);
        escrow = new ThorMigrationEscrow(address(this), address(xmetro), address(thor), address(yThor), block.timestamp);

        escrow.setCaps(1_000_000 ether, 1_000_000 ether);
        escrow.setRatios(1e18, 1e18);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        xmetro.setMigrationEscrow(address(escrow));
        xmetro.setRewardDistributor(address(this));
        metro.setMinter(address(xmetro), true);
        usdc.approve(address(xmetro), type(uint256).max);

        _fundYThor(userA, 100 ether);
        _fundYThor(userB, 100 ether);
    }

    function test_WeightChangeAffectsEveryActivePositionProspectivelyAndExitStopsFutureRewards() public {
        vm.prank(userA);
        escrow.migrateYThor(100 ether);
        assertEq(xmetro.rewardWeightOf(userA), 200 ether);
        assertEq(_activeYThorPrincipal(userA), 100 ether);

        _depositRewards(200e6);
        assertEq(xmetro.claimable(userA), 200e6);
        int256 debtBefore = xmetro.rewardDebt(userA);
        uint256 baseAccBefore = xmetro.accRewardPerShare();

        _setWeight(15_000);
        assertEq(xmetro.rewardWeightOf(userA), 150 ether);
        assertEq(xmetro.claimable(userA), 200e6);
        assertEq(xmetro.rewardDebt(userA), debtBefore);
        assertEq(xmetro.accRewardPerShare(), baseAccBefore);

        vm.prank(userB);
        escrow.migrateYThor(100 ether);
        assertEq(xmetro.rewardWeightOf(userA), 150 ether);
        assertEq(xmetro.rewardWeightOf(userB), 150 ether);
        assertEq(xmetro.claimable(userB), 0);
        assertEq(_activeYThorPrincipal(userA) + _activeYThorPrincipal(userB), 200 ether);

        _depositRewards(300e6);
        assertEq(xmetro.claimable(userA), 350e6);
        assertEq(xmetro.claimable(userB), 150e6);

        _setWeight(5_000);
        assertEq(xmetro.claimable(userA), 350e6);
        assertEq(xmetro.claimable(userB), 150e6);
        assertEq(xmetro.rewardWeightOf(userA), 50 ether);
        assertEq(xmetro.rewardWeightOf(userB), 50 ether);

        _depositRewards(100e6);
        assertEq(xmetro.claimable(userA), 400e6);
        assertEq(xmetro.claimable(userB), 200e6);

        (, uint64 migratedAtA,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAtA) + 120 days);
        vm.prank(userA);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(_activeYThorPrincipal(userB), 100 ether);
        assertEq(xmetro.totalRewardWeight(), 50 ether);

        vm.prank(userB);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
        assertEq(_activeYThorPrincipal(userB), 0);
        assertEq(xmetro.totalRewardWeight(), 0);
        assertEq(xmetro.claimable(userA), 400e6);
        assertEq(xmetro.claimable(userB), 200e6);
    }

    function _fundYThor(address account, uint256 amount) private {
        yThor.mint(account, amount);
        vm.prank(account);
        yThor.approve(address(escrow), amount);
    }

    function _depositRewards(uint256 amount) private {
        usdc.mint(address(this), amount);
        xmetro.depositRewards(amount);
    }

    function _setWeight(uint256 newWeightBps) private {
        xmetro.setYThorRewardWeightBps(newWeightBps);
    }

    function _activeYThorPrincipal(address user) private view returns (uint256) {
        (uint128 principal,,, bool exited) = xmetro.yThorPositions(user, 0);
        return exited ? 0 : uint256(principal);
    }

    function test_TreasuryRemainsExcludedAcrossProspectiveMultiplierChanges() public {
        address treasury = xmetro.migrationRewardExcludedAddress();
        _fundYThor(treasury, 100 ether);
        vm.prank(treasury);
        escrow.migrateYThor(100 ether);
        vm.prank(userA);
        escrow.migrateYThor(100 ether);
        vm.prank(userB);
        escrow.migrateYThor(100 ether);
        metro.setMinter(address(this), true);
        metro.mint(treasury, 10 ether);
        vm.startPrank(treasury);
        metro.approve(address(xmetro), 10 ether);
        xmetro.stake(10 ether);
        vm.stopPrank();
        uint256[4] memory multipliers = [uint256(0), 5_000, 20_000, 3_333];
        uint256 expectedUser;
        uint256 expectedTreasury;
        for (uint256 i; i < multipliers.length; ++i) {
            _setWeight(multipliers[i]);
            assertEq(xmetro.claimable(userA), expectedUser);
            assertEq(xmetro.claimable(treasury), expectedTreasury);
            assertEq(xmetro.rewardWeightOf(treasury), 10 ether);
            uint256 userWeight = 100 ether * multipliers[i] / 10_000;
            assertEq(xmetro.totalRewardWeight(), 10 ether + 2 * userWeight);
            _depositRewards((10 ether + 2 * userWeight) / 1e12);
            expectedUser += userWeight / 1e12;
            expectedTreasury += 10e6;
            assertEq(xmetro.claimable(userA), expectedUser);
            assertEq(xmetro.claimable(userB), expectedUser);
            assertEq(xmetro.claimable(treasury), expectedTreasury);
        }
        assertEq(xmetro.lockedShares(treasury), 100 ether);
        assertEq(xmetro.totalShares(), 310 ether);
        assertEq(metro.balanceOf(address(xmetro)), 310 ether);
    }
}
