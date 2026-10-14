// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {xMETRO} from "../../../src/xMETRO.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

contract ContributorVestingMainnetTest is MainnetForkBase {
    address private contributor;
    address private receiver;
    address private other;

    event ContributorStaked(address indexed contributor, address indexed receiver, uint256 amount, uint64 startTime, uint64 duration);
    event UnstakeRequested(address indexed user, xMETRO.UnstakeSource indexed source, uint256 amount, uint64 unlockTime);
    event Withdrawn(address indexed user, xMETRO.UnstakeSource indexed source, uint256 amount);
    event UnlockedClaimedAsShares(address indexed user, xMETRO.UnstakeSource indexed source, uint256 amount);

    function setUp() public {
        _fork();
        _deploySystem();
        core.unpause();
        metro.setMinter(address(this), true);
        contributor = makeAddr("contributor");
        receiver = makeAddr("receiver");
        other = makeAddr("other");
    }

    function _contribute(address payer, address beneficiary, uint256 amount) internal {
        metro.mint(payer, amount);
        vm.startPrank(payer);
        metro.approve(address(core), amount);
        core.stakeContributor(amount, beneficiary);
        vm.stopPrank();
    }

    /// E-06.01: Tests whitelist own and other receiver.
    function test_E06_WhitelistOwnAndOtherReceiver() public {
        metro.mint(contributor, 100 ether);
        vm.startPrank(contributor);
        metro.approve(address(core), 100 ether);
        vm.expectRevert();
        core.stakeContributor(10 ether, receiver);
        vm.stopPrank();
        core.setContributor(contributor, true);
        vm.expectEmit(true, true, false, true, address(core));
        emit ContributorStaked(contributor, contributor, 40 ether, uint64(block.timestamp + 180 days), uint64((5 * 365 days) / 2));
        vm.startPrank(contributor);
        core.stakeContributor(40 ether, contributor);
        core.stakeContributor(60 ether, receiver);
        vm.stopPrank();
        assertEq(metro.balanceOf(contributor), 0);
        assertEq(metro.balanceOf(address(core)), 100 ether);
        assertEq(core.lockedShares(contributor), 40 ether);
        assertEq(core.lockedShares(receiver), 60 ether);
        assertEq(core.balanceOf(receiver), 0);
    }

    /// E-06.02: Tests revocation does not freeze existing receiver.
    function test_E06_RevocationDoesNotFreezeExistingReceiver() public {
        core.setContributor(contributor, true);
        _contribute(contributor, receiver, 100 ether);
        _distribute(100e6);
        core.setContributor(contributor, false);
        assertFalse(core.contributorWhitelist(contributor));
        vm.startPrank(contributor);
        vm.expectRevert();
        core.stakeContributor(1, receiver);
        vm.stopPrank();
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(receiver, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration);
        vm.prank(receiver);
        assertEq(core.claimAndStakeUnlockedContributor(0), 100 ether);
        vm.prank(receiver);
        assertEq(core.claimRewards(), 100e6);
        assertEq(IERC20(USDC).balanceOf(receiver), 100e6);
        assertEq(core.balanceOf(receiver), 100 ether);
    }

    /// E-06.03: Tests multiple schedules and locked rewards.
    function test_E06_MultipleSchedulesAndLockedRewards() public {
        core.setContributor(contributor, true);
        _contribute(contributor, receiver, 100 ether);
        vm.warp(block.timestamp + 1 days);
        _contribute(contributor, receiver, 200 ether);
        assertEq(core.contributorVestingCount(receiver), 2);
        xMETRO.VestingSchedule memory first = core.contributorVesting(receiver, 0);
        xMETRO.VestingSchedule memory second = core.contributorVesting(receiver, 1);
        assertEq(first.totalAmount, 100 ether);
        assertEq(second.totalAmount, 200 ether);
        assertEq(first.claimed, 0);
        assertEq(second.claimed, 0);
        assertEq(second.startTime - first.startTime, 1 days);
        assertEq(first.duration, uint64((5 * 365 days) / 2));
        assertEq(core.lockedShares(receiver), 300 ether);
        assertEq(core.totalSharesOf(receiver), 300 ether);
        assertEq(core.totalRewardWeight(), 300 ether);
        assertEq(core.totalSupply(), 0);
        assertEq(metro.balanceOf(address(core)), 300 ether);
        _distribute(90e6);
        assertEq(core.claimable(receiver), 90e6);
    }

    /// E-06.04: Tests production cliff linear midpoint and end.
    function test_E06_ProductionCliffLinearMidpointAndEnd() public {
        core.setContributor(contributor, true);
        _contribute(contributor, receiver, 100 ether);
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(receiver, 0);
        vm.warp(uint256(schedule.startTime) - 1);
        (,, uint256 unlocked,) = core.previewWithdrawableNow(receiver);
        assertEq(unlocked, 0);
        vm.warp(schedule.startTime);
        (,, unlocked,) = core.previewWithdrawableNow(receiver);
        assertEq(unlocked, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration / 2);
        (,, unlocked,) = core.previewWithdrawableNow(receiver);
        assertEq(unlocked, 50 ether);
        vm.warp(uint256(schedule.startTime) + schedule.duration);
        (,, unlocked,) = core.previewWithdrawableNow(receiver);
        assertEq(unlocked, 100 ether);
        vm.warp(uint256(schedule.startTime) + schedule.duration + 1);
        (,, unlocked,) = core.previewWithdrawableNow(receiver);
        assertEq(unlocked, 100 ether);
    }

    /// E-06.05: Tests request and withdraw contributor queue.
    function test_E06_RequestAndWithdrawContributorQueue() public {
        core.setContributor(contributor, true);
        _contribute(contributor, receiver, 100 ether);
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(receiver, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration);
        vm.expectEmit(true, true, false, true, address(core));
        emit UnstakeRequested(receiver, xMETRO.UnstakeSource.Contributor, 100 ether, uint64(block.timestamp + 72 hours));
        vm.prank(receiver);
        assertEq(core.requestWithdrawUnlockedContributor(0), 100 ether);
        assertEq(core.unstakeRequestCountContributor(receiver), 1);
        assertEq(core.unstakeRequestCountFree(receiver), 0);
        assertEq(core.unstakeRequestCountThor(receiver), 0);
        assertEq(core.unstakeRequestCountYThor(receiver), 0);
        assertEq(core.totalSharesOf(receiver), 0);
        assertEq(core.lockedShares(receiver), 0);
        xMETRO.UnstakeRequest memory request = core.unstakeRequestContributor(receiver, 0);
        assertEq(request.amount, 100 ether);
        vm.warp(uint256(request.unlockTime) - 1);
        vm.prank(receiver);
        vm.expectRevert(xMETRO.NothingToWithdraw.selector);
        core.withdrawContributor(0);
        vm.warp(request.unlockTime);
        vm.expectEmit(true, true, false, true, address(core));
        emit Withdrawn(receiver, xMETRO.UnstakeSource.Contributor, 100 ether);
        vm.prank(receiver);
        assertEq(core.withdrawContributor(0), 100 ether);
        assertEq(metro.balanceOf(receiver), 100 ether);
        assertEq(core.unstakeCursorContributor(receiver), 1);
        vm.prank(receiver);
        assertEq(core.withdrawContributor(0), 0);
    }

    /// E-06.06: Tests claim and stake partial then full.
    function test_E06_ClaimAndStakePartialThenFull() public {
        core.setContributor(contributor, true);
        _contribute(contributor, receiver, 100 ether);
        _distribute(100e6);
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(receiver, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration / 2);
        vm.expectEmit(true, true, false, true, address(core));
        emit UnlockedClaimedAsShares(receiver, xMETRO.UnstakeSource.Contributor, 50 ether);
        vm.prank(receiver);
        assertEq(core.claimAndStakeUnlockedContributor(0), 50 ether);
        assertEq(core.balanceOf(receiver), 50 ether);
        assertEq(core.lockedShares(receiver), 50 ether);
        assertEq(core.totalShares(), 100 ether);
        assertEq(metro.balanceOf(address(core)), 100 ether);
        assertEq(core.claimable(receiver), 100e6);
        vm.prank(receiver);
        vm.expectRevert();
        core.claimAndStakeUnlockedContributor(0);
        vm.warp(uint256(schedule.startTime) + schedule.duration);
        vm.prank(receiver);
        assertEq(core.claimAndStakeUnlockedContributor(0), 50 ether);
        assertEq(core.balanceOf(receiver), 100 ether);
        assertEq(core.lockedShares(receiver), 0);
        assertEq(core.contributorVesting(receiver, 0).claimed, 100 ether);
        assertEq(core.totalShares(), 100 ether);
        vm.prank(receiver);
        assertTrue(core.transfer(other, 20 ether));
    }

    /// E-06.07: Tests default explicit scan and independent cursors.
    function test_E06_DefaultExplicitScanAndIndependentCursors() public {
        assertEq(core.defaultMaxVestingSchedules(), 50);
        core.setDefaultMaxVestingSchedules(1);
        assertEq(core.defaultMaxVestingSchedules(), 1);
        core.setContributor(contributor, true);
        _contribute(contributor, receiver, 10 ether);
        _contribute(contributor, receiver, 20 ether);
        _contribute(contributor, receiver, 30 ether);
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(receiver, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration);
        vm.prank(receiver);
        assertEq(core.requestWithdrawUnlockedContributor(0), 10 ether);
        assertEq(core.contributorVestCursor(receiver), 1);
        assertEq(core.unstakeCursorContributor(receiver), 0);
        vm.prank(receiver);
        assertEq(core.claimAndStakeUnlockedContributor(2), 50 ether);
        assertEq(core.contributorVestCursor(receiver), 0);
        assertEq(core.unstakeCursorContributor(receiver), 0);
        vm.warp(core.unstakeRequestContributor(receiver, 0).unlockTime);
        vm.prank(receiver);
        assertEq(core.withdrawContributor(0), 10 ether);
        assertEq(core.unstakeCursorContributor(receiver), 1);
        assertEq(core.contributorVestCursor(receiver), 0);
    }

    /// E-06.08: Tests claimed prefix zero scan rollback and recovery.
    function test_E06_ClaimedPrefixZeroScanRollbackAndRecovery() public {
        core.setContributor(contributor, true);
        _contribute(contributor, receiver, 1 ether);
        _contribute(contributor, receiver, 2 ether);
        _contribute(contributor, receiver, 3 ether);
        xMETRO.VestingSchedule memory first = core.contributorVesting(receiver, 0);
        vm.warp(uint256(first.startTime) + first.duration);
        vm.prank(receiver);
        assertEq(core.claimAndStakeUnlockedContributor(0), 6 ether);
        assertEq(core.contributorVestCursor(receiver), 0);
        _contribute(contributor, receiver, 4 ether);
        xMETRO.VestingSchedule memory fourth = core.contributorVesting(receiver, 3);
        vm.warp(uint256(fourth.startTime) + fourth.duration);
        vm.prank(receiver);
        vm.expectRevert();
        core.claimAndStakeUnlockedContributor(3);
        assertEq(core.contributorVestCursor(receiver), 0);
        assertEq(core.contributorVesting(receiver, 3).claimed, 0);
        vm.prank(receiver);
        assertEq(core.claimAndStakeUnlockedContributor(4), 4 ether);
        assertEq(core.contributorVestCursor(receiver), 0);
        assertEq(core.contributorVesting(receiver, 3).claimed, 4 ether);
        vm.prank(receiver);
        vm.expectRevert();
        core.claimAndStakeUnlockedContributor(4);
    }
}
