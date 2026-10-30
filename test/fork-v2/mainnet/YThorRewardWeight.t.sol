// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {xMETRO} from "../../../src/xMETRO.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

contract YThorRewardWeightMainnetTest is MainnetForkBase {
    address private alice;
    address private bob;
    address private carol;

    function setUp() public {
        _fork();
        _deploySystem();
        core.unpause();
        alice = makeAddr("weight-alice");
        bob = makeAddr("weight-bob");
        carol = makeAddr("weight-carol");
    }

    function _migrateY(address user, uint256 amount) internal {
        _fundMigrationToken(YTHOR, YTHOR_HOLDER, user, amount);
        vm.startPrank(user);
        IERC20(YTHOR).approve(address(escrow), amount);
        escrow.migrateYThor(amount);
        vm.stopPrank();
    }

    function _migrateThor(address user, uint256 amount) internal {
        _fundMigrationToken(THOR, THOR_HOLDER, user, amount);
        vm.startPrank(user);
        IERC20(THOR).approve(address(escrow), amount);
        escrow.migrateThor(amount);
        vm.stopPrank();
    }

    function _yAccumulator() internal view returns (uint256) {
        // After restoring Ownable, compiler storage layout confirms the independent yTHOR accumulator in slot 8.
        return uint256(vm.load(address(core), bytes32(uint256(8))));
    }

    /// E-14.01: Tests initial owner and upper bound.
    function test_E14_InitialOwnerAndUpperBound() public {
        assertEq(core.yThorRewardWeightBps(), 20_000);
        assertFalse(core.paused());
        vm.prank(alice);
        vm.expectRevert();
        core.setYThorRewardWeightBps(5_000);
        vm.expectRevert(xMETRO.InvalidConfiguration.selector);
        core.setYThorRewardWeightBps(uint256(type(uint128).max) + 1);
        core.setYThorRewardWeightBps(5_000);
        assertEq(core.yThorRewardWeightBps(), 5_000);
        core.transferOwnership(alice);
        assertEq(core.owner(), alice);
        vm.expectRevert();
        core.setYThorRewardWeightBps(10_000);
        vm.prank(alice);
        core.setYThorRewardWeightBps(10_000);
        assertEq(core.yThorRewardWeightBps(), 10_000);
    }

    /// E-14.02: Tests all existing yTHOR users change together.
    function test_E14_AllExistingYThorUsersChangeTogether() public {
        _migrateY(alice, 100 ether);
        _migrateY(bob, 100 ether);
        assertEq(core.rewardWeightOf(alice), 200 ether);
        assertEq(core.rewardWeightOf(bob), 200 ether);
        core.setYThorRewardWeightBps(5_000);
        assertEq(core.rewardWeightOf(alice), 50 ether);
        assertEq(core.rewardWeightOf(bob), 50 ether);
        assertEq(core.totalRewardWeight(), 100 ether);
        _distribute(100e6);
        assertEq(core.claimable(alice), 50e6);
        assertEq(core.claimable(bob), 50e6);
    }

    /// E-14.03: Tests weights do not rewrite historical rewards.
    function test_E14_WeightsDoNotRewriteHistoricalRewards() public {
        _migrateY(alice, 100 ether);
        _mintAndStake(bob, 100 ether);
        _distribute(300e6);
        assertEq(core.claimable(alice), 200e6);
        assertEq(core.claimable(bob), 100e6);
        core.setYThorRewardWeightBps(10_000);
        assertEq(core.claimable(alice), 200e6);
        assertEq(core.claimable(bob), 100e6);
        _distribute(200e6);
        assertEq(core.claimable(alice), 300e6);
        assertEq(core.claimable(bob), 200e6);
    }

    /// E-14.04: Tests above below zero and restored weights.
    function test_E14_AboveBelowZeroAndRestoredWeights() public {
        _migrateY(alice, 100 ether);
        _mintAndStake(bob, 100 ether);
        _distribute(300e6);
        assertEq(core.claimable(alice), 200e6);
        core.setYThorRewardWeightBps(5_000);
        _distribute(300e6);
        assertEq(core.claimable(alice), 300e6);
        assertEq(core.claimable(bob), 300e6);
        core.setYThorRewardWeightBps(0);
        assertEq(core.rewardWeightOf(alice), 0);
        _distribute(100e6);
        assertEq(core.claimable(alice), 300e6);
        assertEq(core.claimable(bob), 400e6);
        core.setYThorRewardWeightBps(10_000);
        _distribute(200e6);
        assertEq(core.claimable(alice), 400e6);
        assertEq(core.claimable(bob), 500e6);
        core.setYThorRewardWeightBps(20_000);
        _distribute(300e6);
        assertEq(core.claimable(alice), 600e6);
        assertEq(core.claimable(bob), 600e6);
    }

    /// E-14.05: Tests only zero weight yTHOR rejects then mixed shares earn.
    function test_E14_OnlyZeroWeightYThorRejectsThenMixedSharesEarn() public {
        _migrateY(alice, 100 ether);
        core.setYThorRewardWeightBps(0);
        _fundUSDC(address(this), 300e6);
        IERC20(USDC).approve(address(distributor), 300e6);
        vm.expectRevert(xMETRO.InvalidConfiguration.selector);
        distributor.distribute(300e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        _mintAndStake(bob, 100 ether);
        _migrateThor(carol, 100 ether);
        address contributor = makeAddr("weight-contributor");
        metro.mint(contributor, 100 ether);
        core.setContributor(contributor, true);
        vm.startPrank(contributor);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, contributor);
        vm.stopPrank();
        assertEq(core.totalRewardWeight(), 300 ether);
        distributor.distribute(300e6);
        assertEq(core.claimable(alice), 0);
        assertEq(core.claimable(bob), 100e6);
        assertEq(core.claimable(carol), 100e6);
        assertEq(core.claimable(contributor), 100e6);
    }

    /// E-14.06: Tests migration exit claim two accumulators and debt.
    function test_E14_MigrationExitClaimTwoAccumulatorsAndDebt() public {
        _migrateY(alice, 100 ether);
        _distribute(200e6);
        assertEq(core.accRewardPerShare(), 1e12);
        assertEq(_yAccumulator(), 2e12);
        assertEq(core.claimable(alice), 200e6);
        core.setYThorRewardWeightBps(10_000);
        _migrateY(bob, 100 ether);
        assertEq(core.rewardDebt(bob), 200e6);
        assertEq(core.totalRewardWeight(), 200 ether);
        _distribute(200e6);
        assertEq(core.accRewardPerShare(), 2e12);
        assertEq(_yAccumulator(), 3e12);
        assertEq(core.claimable(alice), 300e6);
        assertEq(core.claimable(bob), 100e6);
        vm.warp(block.timestamp + 120 days);
        vm.prank(alice);
        (uint256 payout,) = core.exitYThor(0, xMETRO.ExitMode.Stake);
        assertEq(payout, 20 ether);
        assertEq(core.rewardWeightOf(alice), 20 ether);
        assertEq(core.totalRewardWeight(), 120 ether);
        assertEq(core.rewardDebt(alice), -260e6);
        assertEq(core.claimable(alice), 300e6);
        _distribute(120e6);
        assertEq(core.accRewardPerShare(), 3e12);
        assertEq(_yAccumulator(), 4e12);
        assertEq(core.claimable(alice), 320e6);
        assertEq(core.claimable(bob), 200e6);
        vm.prank(alice);
        assertEq(core.claimRewards(), 320e6);
        vm.prank(bob);
        assertEq(core.claimRewards(), 200e6);
        assertEq(core.claimable(alice), 0);
        assertEq(core.claimable(bob), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
    }

    /// E-14.07: Tests small principal fractional bps and dust.
    function test_E14_SmallPrincipalFractionalBpsAndDust() public {
        _migrateY(alice, 5e11);
        _migrateY(alice, 5e11);
        assertEq(core.yThorPositionCount(alice), 2);
        _mintAndStake(bob, 1e12);
        core.setYThorRewardWeightBps(3_333);
        assertEq(core.rewardWeightOf(alice), 333_300_000_000);
        assertEq(core.totalRewardWeight(), 1_333_300_000_000);
        _distribute(1);
        vm.prank(alice);
        assertEq(core.claimRewards(), 0);
        uint256 beforeWeightChange = core.claimable(alice);
        core.setYThorRewardWeightBps(0);
        assertEq(core.claimable(alice), beforeWeightChange);
        core.setYThorRewardWeightBps(3_333);
        _distribute(1);
        _distribute(1);
        _distribute(1);
        uint256 quotedAlice = core.claimable(alice);
        uint256 quotedBob = core.claimable(bob);
        assertLe(quotedAlice + quotedBob, 4);
        vm.prank(alice);
        uint256 claimedAlice = core.claimRewards();
        vm.prank(bob);
        uint256 claimedBob = core.claimRewards();
        assertEq(claimedAlice, quotedAlice);
        assertEq(claimedBob, quotedBob);
        assertEq(IERC20(USDC).balanceOf(address(core)), 4 - claimedAlice - claimedBob);
        emit log_named_uint("E14 tiny reward claim sum raw", claimedAlice + claimedBob);
        emit log_named_uint("E14 tiny reward unallocated tail raw", IERC20(USDC).balanceOf(address(core)));
    }

    function test_E14_TreasuryRealMigrationsExcludeOnlyMigrationRewards() public {
        address treasury = forfeitureRecipient;
        assertEq(core.migrationRewardExcludedAddress(), treasury);
        _migrateThor(treasury, 100 ether);
        _migrateY(treasury, 100 ether);
        _mintAndStake(treasury, 20 ether);
        _mintAndStake(alice, 100 ether);
        assertEq(core.totalShares(), 320 ether);
        assertEq(core.totalRewardWeight(), 120 ether);
        assertEq(core.rewardWeightOf(treasury), 20 ether);
        _distribute(120e6);
        assertEq(core.claimable(treasury), 20e6);
        assertEq(core.claimable(alice), 100e6);
        vm.warp(vm.getBlockTimestamp() + 120 days);
        vm.startPrank(treasury);
        (uint256 yPayout, uint256 forfeited) = core.exitYThor(0, xMETRO.ExitMode.Stake);
        (uint256 thorPayout, uint256 thorForfeited) = core.requestThorExit(0);
        vm.stopPrank();
        assertEq(yPayout, 20 ether);
        assertEq(forfeited, 80 ether);
        assertEq(thorPayout, 100 ether);
        assertEq(thorForfeited, 0);
        assertEq(metro.balanceOf(treasury), 80 ether);
        assertEq(core.lockedShares(treasury), 0);
        assertEq(core.balanceOf(treasury), 40 ether);
        assertEq(core.totalRewardWeight(), 140 ether);
        assertEq(core.claimable(treasury), 20e6);
        _distribute(140e6);
        assertEq(core.claimable(treasury), 60e6);
        assertEq(core.claimable(alice), 200e6);
        vm.warp(core.unstakeRequestThor(treasury, 0).unlockTime);
        vm.startPrank(treasury);
        assertEq(core.withdrawThor(0), 100 ether);
        assertEq(core.claimRewards(), 60e6);
        vm.stopPrank();
        assertEq(metro.balanceOf(treasury), 180 ether);
        assertEq(metro.balanceOf(address(core)), 140 ether);
        assertEq(metro.totalSupply(), 320 ether);
        assertEq(IERC20(USDC).balanceOf(treasury), 60e6);
    }
}
