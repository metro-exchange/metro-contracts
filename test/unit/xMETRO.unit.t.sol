// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {xMETRO as XMetroCore} from "../../src/xMETRO.sol";
import {MetroToken} from "../../src/metro.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockXMetroDeFiAdapter} from "../mocks/MockXMetroDeFiAdapter.sol";

contract BoundMigrationEscrowProbe {
    address public immutable xMETRO;

    constructor(address xMetro_) {
        xMETRO = xMetro_;
    }
}

contract BoundRewardDistributorProbe {
    address public immutable xMETRO;
    address public immutable rewardToken;

    constructor(address xMetro_, address rewardToken_) {
        xMETRO = xMetro_;
        rewardToken = rewardToken_;
    }
}

contract xMETROUnitTest is Test {
    ERC20Mintable internal usdc;
    MetroToken internal metro;
    XMetroCore internal xmetro;

    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal outsider = makeAddr("outsider");
    address internal forfeitureRecipient = makeAddr("forfeitureMultisig");

    uint256 internal constant METRO_CAP = 1_000_000_000 ether;

    function xMETRO() external view returns (address) {
        return address(xmetro);
    }

    function rewardToken() external view returns (address) {
        return address(usdc);
    }

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);

        xmetro = new XMetroCore(address(this), address(metro), address(usdc), forfeitureRecipient, 20_000);
        metro.setMinter(address(xmetro), true);
        xmetro.setMigrationEscrow(address(this));
        xmetro.setRewardDistributor(address(this));
        usdc.approve(address(xmetro), type(uint256).max);
    }

    function _stake(address user, uint256 amount) internal {
        metro.mint(user, amount);
        vm.prank(user);
        metro.approve(address(xmetro), amount);
        vm.prank(user);
        xmetro.stake(amount);
    }

    /// @notice The constructor leaves Core usable without a separate unpause transaction.
    function test_DefaultUnpausedAllowsStakeAndClaim() public {
        assertFalse(xmetro.paused());
        _stake(userA, 100 ether);
        _depositRewards(25e6);
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), 25e6);
        assertEq(usdc.balanceOf(userA), 25e6);
    }

    /// @notice One-step ownership takes effect immediately; zero address and former Owner calls fail.
    function test_SingleStepOwnershipRejectsZeroAndRevokesOldOwner() public {
        vm.prank(outsider);
        vm.expectRevert();
        xmetro.transferOwnership(userA);
        vm.expectRevert();
        xmetro.transferOwnership(address(0));
        assertEq(xmetro.owner(), address(this));

        xmetro.transferOwnership(userA);
        assertEq(xmetro.owner(), userA);
        vm.expectRevert();
        xmetro.setYThorRewardWeightBps(10_000);
        vm.prank(userA);
        xmetro.setYThorRewardWeightBps(10_000);
        assertEq(xmetro.yThorRewardWeightBps(), 10_000);
    }

    /// @notice Only the current Owner may renounce, and ownership cannot be recovered afterward.
    function test_OnlyOwnerCanRenounceAndCannotRecoverOwnership() public {
        vm.prank(outsider);
        vm.expectRevert();
        xmetro.renounceOwnership();
        assertEq(xmetro.owner(), address(this));
        xmetro.renounceOwnership();
        assertEq(xmetro.owner(), address(0));
        vm.expectRevert();
        xmetro.transferOwnership(userA);
        vm.expectRevert();
        xmetro.setYThorRewardWeightBps(10_000);
        vm.expectRevert();
        xmetro.pause();
    }

    /// @notice Renouncing while unpaused does not erase accrued rewards or block ordinary withdrawal.
    function test_RenouncePreservesPendingAndUserWithdrawal() public {
        _stake(userA, 100 ether);
        _depositRewards(25e6);
        xmetro.renounceOwnership();
        assertEq(xmetro.claimable(userA), 25e6);
        vm.startPrank(userA);
        assertEq(xmetro.claimRewards(), 25e6);
        xmetro.requestUnstake(100 ether);
        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY());
        assertEq(xmetro.withdrawFree(0), 100 ether);
        vm.stopPrank();
        assertEq(usdc.balanceOf(userA), 25e6);
        assertEq(metro.balanceOf(userA), 100 ether);
    }

    /// @notice Renouncing while paused permanently removes the ability to unpause; test this explicitly.
    function test_RenounceWhilePausedCannotBeUnpausedByFormerOwner() public {
        xmetro.pause();
        xmetro.renounceOwnership();
        assertTrue(xmetro.paused());
        assertEq(xmetro.owner(), address(0));
        vm.expectRevert();
        xmetro.unpause();
    }

    function _depositRewards(uint256 amount) internal {
        usdc.mint(address(this), amount);
        xmetro.depositRewards(amount);
    }

    function _stakeContributor(address funder, address receiver, uint256 amount) internal {
        xmetro.setContributor(funder, true);
        metro.mint(funder, amount);
        vm.prank(funder);
        metro.approve(address(xmetro), amount);
        vm.prank(funder);
        xmetro.stakeContributor(amount, receiver);
    }

    function _setMockAdapter(uint256 mul, uint256 div) internal returns (MockXMetroDeFiAdapter adapter) {
        adapter = new MockXMetroDeFiAdapter(address(xmetro), address(usdc), address(metro), mul, div);
        xmetro.setDeFiAdapter(address(adapter));
    }

    function test_ConstructorAndConfigurationValidation() public {
        assertEq(xmetro.forfeitureRecipient(), forfeitureRecipient);
        assertEq(xmetro.UNSTAKE_DELAY(), 1800 seconds);
        assertEq(xmetro.CONTRIBUTOR_CLIFF(), 21600 seconds);
        assertEq(xmetro.yThorRewardWeightBps(), 20_000);

        XMetroCore fresh = new XMetroCore(address(this), address(metro), address(usdc), forfeitureRecipient, 20_000);
        assertFalse(fresh.paused());
        XMetroCore zeroWeight = new XMetroCore(address(this), address(metro), address(usdc), forfeitureRecipient, 0);
        assertEq(zeroWeight.yThorRewardWeightBps(), 0);

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        new XMetroCore(address(this), address(metro), address(usdc), address(0), 20_000);

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        new XMetroCore(address(this), address(0), address(usdc), forfeitureRecipient, 20_000);

        vm.prank(outsider);
        vm.expectRevert();
        xmetro.setMigrationEscrow(outsider);

        xmetro.setMigrationEscrow(address(this));
        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setMigrationEscrow(address(0));

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setMigrationEscrow(userA);
        xmetro.setMigrationEscrow(address(this));
        assertEq(xmetro.migrationEscrow(), address(this));
        assertFalse(xmetro.paused());
    }

    function test_BaseQaForfeitureRecipientCanFollowOwnerHandover() public {
        address newRecipient = makeAddr("projectTreasury");

        vm.prank(outsider);
        vm.expectRevert();
        xmetro.setForfeitureRecipient(newRecipient);

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setForfeitureRecipient(address(0));

        vm.expectEmit(true, true, false, false);
        emit XMetroCore.ForfeitureRecipientUpdated(forfeitureRecipient, newRecipient);
        xmetro.setForfeitureRecipient(newRecipient);
        assertEq(xmetro.forfeitureRecipient(), newRecipient);

        xmetro.creditThorFromMigration(userA, 100 ether);
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 3600 seconds);
        vm.prank(userA);
        (uint256 payout, uint256 forfeited) = xmetro.requestThorExit(0);
        assertEq(payout, 50 ether);
        assertEq(forfeited, 50 ether);
        assertEq(metro.balanceOf(newRecipient), forfeited);
        assertEq(metro.balanceOf(forfeitureRecipient), 0);

        xmetro.transferOwnership(userB);
        vm.expectRevert();
        xmetro.setForfeitureRecipient(forfeitureRecipient);
        vm.prank(userB);
        xmetro.setForfeitureRecipient(forfeitureRecipient);
        assertEq(xmetro.forfeitureRecipient(), forfeitureRecipient);

        xmetro.creditYThorFromMigration(userB, 100 ether);
        (, uint64 yThorMigratedAt,,) = xmetro.yThorPositions(userB, 0);
        vm.warp(uint256(yThorMigratedAt) + 14400 seconds);
        vm.prank(userB);
        (, uint256 yThorForfeited) = xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
        assertEq(yThorForfeited, 90 ether);
        assertEq(metro.balanceOf(forfeitureRecipient), yThorForfeited);
        assertEq(metro.balanceOf(newRecipient), forfeited);
    }

    function test_YThorRewardWeightSupportsSubOneXAndZeroWithoutPause() public {
        vm.prank(outsider);
        vm.expectRevert();
        xmetro.setYThorRewardWeightBps(5_000);

        vm.expectEmit(false, false, false, true);
        emit XMetroCore.YThorRewardWeightBpsUpdated(20_000, 5_000);
        xmetro.setYThorRewardWeightBps(5_000);
        assertFalse(xmetro.paused());
        assertEq(xmetro.yThorRewardWeightBps(), 5_000);

        vm.expectEmit(false, false, false, true);
        emit XMetroCore.YThorRewardWeightBpsUpdated(5_000, 5_000);
        xmetro.setYThorRewardWeightBps(5_000);
        (bool oversizedOk,) = address(xmetro)
            .call(abi.encodeWithSelector(XMetroCore.setYThorRewardWeightBps.selector, uint256(type(uint128).max) + 1));
        assertFalse(oversizedOk);

        vm.expectEmit(false, false, false, true);
        emit XMetroCore.YThorRewardWeightBpsUpdated(5_000, 0);
        xmetro.setYThorRewardWeightBps(0);
        assertEq(xmetro.yThorRewardWeightBps(), 0);
    }

    function test_ZeroAndSubOneXWeightsUseIndependentYThorAccumulator() public {
        _stake(userA, 100 ether);
        xmetro.creditYThorFromMigration(userB, 100 ether);

        xmetro.setYThorRewardWeightBps(0);
        _depositRewards(100e6);
        assertEq(xmetro.claimable(userA), 100e6);
        assertEq(xmetro.claimable(userB), 0);

        xmetro.setYThorRewardWeightBps(5_000);
        _depositRewards(150e6);
        assertEq(xmetro.claimable(userA), 200e6);
        assertEq(xmetro.claimable(userB), 50e6);
    }

    function test_FractionalYThorWeightRoundingCannotCreateUnbackedRewards() public {
        xmetro.creditYThorFromMigration(userA, 1);
        xmetro.setYThorRewardWeightBps(15_000);

        _depositRewards(2e6);

        assertEq(xmetro.totalRewardWeight(), 1);
        assertEq(xmetro.claimable(userA), 2e6);
        assertEq(usdc.balanceOf(address(xmetro)), 2e6);
    }

    function test_GlobalFractionalWeightRoundingAcrossMultipleYThorUsersCannotOverclaim() public {
        _stake(outsider, 1);
        xmetro.creditYThorFromMigration(userA, 1);
        xmetro.creditYThorFromMigration(userB, 1);
        xmetro.setYThorRewardWeightBps(5_000);

        _depositRewards(2e6);

        uint256 totalClaimable = xmetro.claimable(userA) + xmetro.claimable(userB) + xmetro.claimable(outsider);
        assertEq(xmetro.claimable(userA), 500_000);
        assertEq(xmetro.claimable(userB), 500_000);
        assertEq(xmetro.claimable(outsider), 1e6);
        assertEq(totalClaimable, usdc.balanceOf(address(xmetro)));
    }

    function test_DepositRevertsInsteadOfTrappingRewardsWhenConfiguredWeightRoundsDeltaToZero() public {
        xmetro.creditYThorFromMigration(userA, metro.MAX_SUPPLY());
        xmetro.setYThorRewardWeightBps(type(uint128).max);
        usdc.mint(address(this), 1);

        vm.expectRevert(XMetroCore.InvalidAmount.selector);
        xmetro.depositRewards(1);

        assertEq(usdc.balanceOf(address(xmetro)), 0);
        assertEq(xmetro.claimable(userA), 0);
    }

    function test_ZeroWeightWithOnlyYThorRejectsRewardDepositAtomically() public {
        xmetro.creditYThorFromMigration(userA, 100 ether);
        xmetro.setYThorRewardWeightBps(0);
        usdc.mint(address(this), 1e6);

        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.depositRewards(1e6);

        assertEq(usdc.balanceOf(address(xmetro)), 0);
        assertEq(xmetro.claimable(userA), 0);
    }

    function test_StakeRewardContributorAndOwnerConfigurationGuards() public {
        vm.prank(userA);
        vm.expectRevert();
        xmetro.setRewardDistributor(userA);

        xmetro.setRewardDistributor(address(this));
        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setRewardDistributor(address(0));

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setRewardDistributor(userA);
        xmetro.setRewardDistributor(address(this));
        assertEq(xmetro.rewardDistributor(), address(this));

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setDeFiAdapter(address(0));

        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.setDeFiAdapter(userA);

        MockXMetroDeFiAdapter adapter = new MockXMetroDeFiAdapter(address(xmetro), address(usdc), address(metro), 1, 1);
        xmetro.setDeFiAdapter(address(adapter));
        assertEq(xmetro.deFiAdapter(), address(adapter));

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setAutoCompoundOperator(address(0), true);
        assertFalse(xmetro.paused());

        vm.startPrank(userA);
        vm.expectRevert();
        xmetro.setContributor(userA, true);
        vm.expectRevert();
        xmetro.setDefaultMaxVestingSchedules(1);
        vm.stopPrank();

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.setContributor(address(0), true);
        vm.expectRevert(XMetroCore.InvalidAmount.selector);
        xmetro.setDefaultMaxVestingSchedules(0);

        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidAmount.selector);
        xmetro.stake(0);
        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidAmount.selector);
        xmetro.requestUnstake(0);

        vm.prank(userA);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        xmetro.depositRewards(1);
        vm.expectRevert(XMetroCore.InvalidAmount.selector);
        xmetro.depositRewards(0);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.depositRewards(1);

        metro.mint(userA, 1 ether);
        vm.prank(userA);
        metro.approve(address(xmetro), 1 ether);
        vm.prank(userA);
        vm.expectRevert(bytes4(keccak256("UserNotAuthorized()")));
        xmetro.stakeContributor(1 ether, userA);
    }

    function test_CoreCriticalSettingsCanBeChangedWhileUnpaused() public {
        BoundMigrationEscrowProbe nextEscrow = new BoundMigrationEscrowProbe(address(xmetro));
        BoundRewardDistributorProbe nextDistributor = new BoundRewardDistributorProbe(address(xmetro), address(usdc));
        MockXMetroDeFiAdapter nextAdapter =
            new MockXMetroDeFiAdapter(address(xmetro), address(usdc), address(metro), 1, 1);
        uint64 epochBefore = xmetro.deFiAdapterEpoch();

        assertFalse(xmetro.paused());
        xmetro.setMigrationEscrow(address(nextEscrow));
        xmetro.setRewardDistributor(address(nextDistributor));
        xmetro.setAutoCompoundOperator(outsider, true);
        xmetro.setDeFiAdapter(address(nextAdapter));

        assertFalse(xmetro.paused());
        assertEq(xmetro.migrationEscrow(), address(nextEscrow));
        assertEq(xmetro.rewardDistributor(), address(nextDistributor));
        assertTrue(xmetro.autoCompoundOperators(outsider));
        assertEq(xmetro.deFiAdapter(), address(nextAdapter));
        assertEq(xmetro.deFiAdapterEpoch(), epochBefore + 1);
    }

    function test_StakeAndFreeUnstakeUseExact72HourQueue() public {
        _stake(userA, 10 ether);
        assertEq(xmetro.balanceOf(userA), 10 ether);
        assertEq(xmetro.totalSharesOf(userA), 10 ether);
        assertEq(xmetro.rewardWeightOf(userA), 10 ether);

        vm.prank(userA);
        xmetro.requestUnstake(4 ether);
        assertEq(xmetro.balanceOf(userA), 6 ether);
        assertEq(xmetro.unstakeRequestCountFree(userA), 1);
        XMetroCore.UnstakeRequest memory request = xmetro.unstakeRequestFree(userA, 0);
        assertEq(request.amount, 4 ether);
        assertEq(request.unlockTime, block.timestamp + xmetro.UNSTAKE_DELAY());

        vm.warp(uint256(request.unlockTime) - 1);
        vm.prank(userA);
        vm.expectRevert(bytes4(keccak256("NothingToWithdraw()")));
        xmetro.withdrawFree(0);

        vm.warp(request.unlockTime);
        uint256 before = metro.balanceOf(userA);
        vm.prank(userA);
        assertEq(xmetro.withdrawFree(0), 4 ether);
        assertEq(metro.balanceOf(userA) - before, 4 ether);
        assertEq(xmetro.unstakeCursorFree(userA), 1);

        vm.prank(userA);
        assertEq(xmetro.withdrawFree(0), 0);
    }

    function test_FreeQueueBatchStopsAtMaxRequests() public {
        _stake(userA, 6 ether);
        vm.startPrank(userA);
        xmetro.requestUnstake(1 ether);
        xmetro.requestUnstake(2 ether);
        xmetro.requestUnstake(3 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY());
        vm.prank(userA);
        assertEq(xmetro.withdrawFree(2), 3 ether);
        assertEq(xmetro.unstakeCursorFree(userA), 2);
        vm.prank(userA);
        assertEq(xmetro.withdrawFree(2), 3 ether);
    }

    function test_MigrationCreditsMultiplePositionsAndTracksActiveYThorPrincipalWithoutVirtualMint() public {
        xmetro.creditThorFromMigration(userA, 100 ether);
        xmetro.creditYThorFromMigration(userB, 100 ether);

        assertEq(xmetro.lockedShares(userA), 100 ether);
        assertEq(xmetro.rewardWeightOf(userA), 100 ether);
        assertEq(xmetro.lockedShares(userB), 100 ether);
        assertEq(_activeYThorPrincipal(userB), 100 ether);
        assertEq(xmetro.rewardWeightOf(userB), 200 ether);
        assertEq(xmetro.totalShares(), 200 ether);
        assertEq(xmetro.totalRewardWeight(), 300 ether);
        assertEq(xmetro.totalRewardWeight(), 300 ether);

        assertEq(metro.totalSupply(), 200 ether);
        assertEq(metro.balanceOf(address(xmetro)), 200 ether);

        xmetro.creditThorFromMigration(userA, 1 ether);
        xmetro.creditYThorFromMigration(userB, 1 ether);
        assertEq(xmetro.thorPositionCount(userA), 2);
        assertEq(xmetro.yThorPositionCount(userB), 2);
        assertEq(_activeYThorPrincipal(userB), 101 ether);
        assertEq(xmetro.totalShares(), 202 ether);
        assertEq(xmetro.totalRewardWeight(), 303 ether);
    }

    function test_MigrationCreditOnlyEscrowAndAmountBounds() public {
        vm.prank(userA);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        xmetro.creditThorFromMigration(userA, 1 ether);

        vm.expectRevert(XMetroCore.InvalidAddress.selector);
        xmetro.creditThorFromMigration(address(0), 1 ether);

        vm.expectRevert(XMetroCore.InvalidAmount.selector);
        xmetro.creditYThorFromMigration(userA, uint256(type(uint128).max) + 1);
    }

    function test_ThorExitPreviewBoundariesAreLinearFromDay30ToDay90() public {
        xmetro.creditThorFromMigration(userA, 100 ether);
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA, 0);

        vm.warp(uint256(migratedAt) + 3600 seconds - 1);
        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited, uint256 eligibleAt) =
            xmetro.previewThorExit(userA, 0);
        assertFalse(eligible);
        assertEq(rate, 0);
        assertEq(payout, 0);
        assertEq(forfeited, 0);
        assertEq(eligibleAt, uint256(migratedAt) + 3600 seconds);

        vm.warp(uint256(migratedAt) + 3600 seconds);
        (eligible, rate, payout, forfeited,) = xmetro.previewThorExit(userA, 0);
        assertTrue(eligible);
        assertEq(rate, 5_000);
        assertEq(payout, 50 ether);
        assertEq(forfeited, 50 ether);

        vm.warp(uint256(migratedAt) + 7200 seconds);
        (, rate, payout, forfeited,) = xmetro.previewThorExit(userA, 0);
        assertEq(rate, 7_500);
        assertEq(payout, 75 ether);
        assertEq(payout + forfeited, 100 ether);

        vm.warp(uint256(migratedAt) + 10800 seconds);
        (, rate, payout, forfeited,) = xmetro.previewThorExit(userA, 0);
        assertEq(rate, 10_000);
        assertEq(payout, 100 ether);
        assertEq(forfeited, 0);

        vm.warp(uint256(migratedAt) + 10800 seconds + 1);
        (, rate, payout, forfeited,) = xmetro.previewThorExit(userA, 0);
        assertEq(rate, 10_000);
        assertEq(payout, 100 ether);
        assertEq(forfeited, 0);
    }

    function test_ThorLiquidExitClosesPositionPreservesPendingAndUsesQueue() public {
        xmetro.creditThorFromMigration(userA, 100 ether);
        _depositRewards(30e6);
        uint256 pendingBefore = xmetro.claimable(userA);
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 7200 seconds);

        vm.prank(userA);
        (uint256 payout, uint256 forfeited) = xmetro.requestThorExit(0);
        assertEq(payout, 75 ether);
        assertEq(forfeited, 25 ether);
        assertEq(metro.balanceOf(forfeitureRecipient), 25 ether);
        assertEq(metro.balanceOf(userA), 0);
        assertEq(metro.balanceOf(address(xmetro)), 75 ether);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(xmetro.rewardWeightOf(userA), 0);
        assertApproxEqAbs(xmetro.claimable(userA), pendingBefore, 1);

        (,,, bool exited) = xmetro.thorPositions(userA, 0);
        assertTrue(exited);
        assertEq(xmetro.unstakeRequestCountThor(userA), 1);
        XMetroCore.UnstakeRequest memory request = xmetro.unstakeRequestThor(userA, 0);
        assertEq(request.amount, payout);
        assertEq(request.unlockTime, block.timestamp + xmetro.UNSTAKE_DELAY());

        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.requestThorExit(0);

        vm.warp(request.unlockTime);
        vm.prank(userA);
        assertEq(xmetro.withdrawThor(0), payout);
        assertEq(metro.balanceOf(userA), payout);
        assertEq(metro.balanceOf(address(xmetro)), 0);

        uint256 rewardsBefore = usdc.balanceOf(userA);
        vm.prank(userA);
        xmetro.claimRewards();
        assertApproxEqAbs(usdc.balanceOf(userA) - rewardsBefore, pendingBefore, 1);
    }

    function test_ThorClaimAndStakeAtDay30HasNoLiquidQueue() public {
        xmetro.creditThorFromMigration(userA, 100 ether);
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 3600 seconds);

        vm.prank(userA);
        (uint256 payout, uint256 forfeited) = xmetro.exitAndStakeThor(0);
        assertEq(payout, 50 ether);
        assertEq(forfeited, 50 ether);
        assertEq(xmetro.balanceOf(userA), payout);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(xmetro.unstakeRequestCountThor(userA), 0);
        assertEq(metro.balanceOf(forfeitureRecipient), forfeited);
        assertEq(metro.balanceOf(address(xmetro)), payout);
        assertEq(xmetro.totalSharesOf(userA), payout);
    }

    function test_ThorCannotExitBeforeDay30OrWhenNoPosition() public {
        vm.prank(userA);
        vm.expectRevert(stdError.indexOOBError);
        xmetro.requestThorExit(0);

        xmetro.creditThorFromMigration(userA, 1 ether);
        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.requestThorExit(0);
    }

    function test_YThorExitPreviewStartsDay120ThenRunsQATwelveHours() public {
        xmetro.creditYThorFromMigration(userA, 100 ether);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        uint256 eligibleAt = uint256(migratedAt) + 14400 seconds;
        uint256 ramp = 12 hours;
        assertEq(xmetro.YTHOR_EXIT_RAMP(), ramp);

        vm.warp(eligibleAt - 1);
        (bool eligible, uint256 rate,,,) = xmetro.previewYThorExit(userA, 0);
        assertFalse(eligible);
        assertEq(rate, 0);

        vm.warp(eligibleAt);
        (bool eligibleAtStart, uint256 rateAtStart, uint256 payout, uint256 forfeited,) =
            xmetro.previewYThorExit(userA, 0);
        eligible = eligibleAtStart;
        rate = rateAtStart;
        assertTrue(eligible);
        assertEq(rate, 1_000);
        assertEq(payout, 10 ether);
        assertEq(forfeited, 90 ether);

        vm.warp(eligibleAt + ramp / 2);
        (, rate, payout, forfeited,) = xmetro.previewYThorExit(userA, 0);
        assertEq(rate, 3_000);
        assertEq(payout, 30 ether);
        assertEq(payout + forfeited, 100 ether);

        vm.warp(eligibleAt + ramp - 1);
        (, uint256 beforeEndRate,,,) = xmetro.previewYThorExit(userA, 0);
        assertLt(beforeEndRate, 5_000);

        vm.warp(eligibleAt + ramp);
        (, rate, payout, forfeited,) = xmetro.previewYThorExit(userA, 0);
        assertEq(rate, 5_000);
        assertEq(payout, 50 ether);
        assertEq(forfeited, 50 ether);

        vm.warp(eligibleAt + ramp + 2 * 43200 seconds);
        (, rate, payout, forfeited,) = xmetro.previewYThorExit(userA, 0);
        assertEq(rate, 5_000);
        assertEq(payout, 50 ether);
        assertEq(forfeited, 50 ether);
    }

    function test_PreviewWithdrawableNowTracksThorAndYThorSchedules() public {
        xmetro.creditThorFromMigration(userA, 100 ether);
        xmetro.creditYThorFromMigration(userA, 100 ether);
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA, 0);

        vm.warp(uint256(migratedAt) + 7200 seconds);
        (uint256 thorAtDay60, uint256 yThorAtDay60, uint256 contributorAtDay60, uint256 totalAtDay60) =
            xmetro.previewWithdrawableNow(userA);
        assertEq(thorAtDay60, 75 ether);
        assertEq(yThorAtDay60, 0);
        assertEq(contributorAtDay60, 0);
        assertEq(totalAtDay60, 75 ether);

        vm.warp(uint256(migratedAt) + 14400 seconds);
        (uint256 thorAtDay120, uint256 yThorAtDay120, uint256 contributorAtDay120, uint256 totalAtDay120) =
            xmetro.previewWithdrawableNow(userA);
        assertEq(thorAtDay120, 100 ether);
        assertEq(yThorAtDay120, 10 ether);
        assertEq(contributorAtDay120, 0);
        assertEq(totalAtDay120, 110 ether);
    }

    function test_YThorLiquidExitRemovesPrincipalAndBonusAndPreservesPending() public {
        xmetro.creditYThorFromMigration(userA, 100 ether);
        _stake(userB, 100 ether);
        _depositRewards(300e6);
        uint256 pendingBefore = xmetro.claimable(userA);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 14400 seconds);

        vm.prank(userA);
        (uint256 payout, uint256 forfeited) = xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
        assertEq(payout, 10 ether);
        assertEq(forfeited, 90 ether);
        assertEq(metro.balanceOf(forfeitureRecipient), 90 ether);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(xmetro.totalRewardWeight(), xmetro.totalShares());
        assertEq(xmetro.rewardWeightOf(userA), 0);
        assertEq(xmetro.unstakeRequestCountYThor(userA), 1);
        assertApproxEqAbs(xmetro.claimable(userA), pendingBefore, 1);

        uint256 beforeFuture = xmetro.claimable(userA);
        _depositRewards(100e6);
        assertApproxEqAbs(xmetro.claimable(userA), beforeFuture, 1);
        assertEq(xmetro.claimable(userB), 200e6);

        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);

        XMetroCore.UnstakeRequest memory request = xmetro.unstakeRequestYThor(userA, 0);
        vm.warp(request.unlockTime);
        vm.prank(userA);
        assertEq(xmetro.withdrawYThor(0), payout);
    }

    function test_YThorExitRemovesActivePrincipalAfterWeightChange() public {
        uint256 principal = 100 ether;
        xmetro.creditYThorFromMigration(userA, principal);

        assertEq(xmetro.lockedShares(userA), principal);
        assertEq(_activeYThorPrincipal(userA), principal);
        assertEq(xmetro.totalRewardWeight(), principal * 2);
        xmetro.setYThorRewardWeightBps(5_000);
        assertEq(xmetro.rewardWeightOf(userA), principal / 2);

        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 14400 seconds);
        vm.prank(userA);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);

        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(xmetro.totalRewardWeight(), 0);
        assertEq(xmetro.rewardWeightOf(userA), 0);
    }

    function test_YThorClaimAndStakeClosesPositionAndHasNoQueue() public {
        xmetro.creditYThorFromMigration(userA, 100 ether);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 14400 seconds + xmetro.YTHOR_EXIT_RAMP());

        vm.prank(userA);
        (uint256 payout, uint256 forfeited) = xmetro.exitYThor(0, XMetroCore.ExitMode.Stake);
        assertEq(payout, 50 ether);
        assertEq(forfeited, 50 ether);
        assertEq(xmetro.balanceOf(userA), payout);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(xmetro.unstakeRequestCountYThor(userA), 0);
        assertEq(xmetro.rewardWeightOf(userA), payout);
        assertEq(metro.balanceOf(forfeitureRecipient), forfeited);
    }

    function test_YThorClaimAndStakePreservesEarnedRewardsAndUsesOnlyPayoutAsFutureWeight() public {
        xmetro.creditYThorFromMigration(userA, 100 ether);
        _stake(userB, 100 ether);
        _depositRewards(300e6);
        assertEq(xmetro.claimable(userA), 200e6);
        assertEq(xmetro.claimable(userB), 100e6);

        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 14400 seconds + xmetro.YTHOR_EXIT_RAMP() / 2);

        vm.prank(userA);
        (uint256 payout, uint256 forfeited) = xmetro.exitYThor(0, XMetroCore.ExitMode.Stake);
        assertEq(payout, 30 ether);
        assertEq(forfeited, 70 ether);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(xmetro.balanceOf(userA), 30 ether);
        assertEq(xmetro.rewardWeightOf(userA), 30 ether);
        assertEq(xmetro.claimable(userA), 200e6);

        // Only the 30 METRO payout remains reward-bearing after the one-time exit.
        _depositRewards(130e6);
        assertEq(xmetro.claimable(userA), 230e6);
        assertEq(xmetro.claimable(userB), 200e6);

        vm.prank(userA);
        assertEq(xmetro.claimRewards(), 230e6);
        assertEq(usdc.balanceOf(userA), 230e6);
    }

    function test_ThorAndYThorLiquidQueuesEnforceExact72HourBoundaryForSameUser() public {
        xmetro.creditThorFromMigration(userA, 100 ether);
        xmetro.creditYThorFromMigration(userA, 100 ether);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 14400 seconds);

        vm.startPrank(userA);
        (uint256 thorPayout,) = xmetro.requestThorExit(0);
        (uint256 yThorPayout,) = xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
        vm.stopPrank();
        assertEq(thorPayout, 100 ether);
        assertEq(yThorPayout, 10 ether);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);

        XMetroCore.UnstakeRequest memory thorRequest = xmetro.unstakeRequestThor(userA, 0);
        XMetroCore.UnstakeRequest memory yThorRequest = xmetro.unstakeRequestYThor(userA, 0);
        assertEq(thorRequest.unlockTime, block.timestamp + xmetro.UNSTAKE_DELAY());
        assertEq(yThorRequest.unlockTime, block.timestamp + xmetro.UNSTAKE_DELAY());

        vm.warp(uint256(thorRequest.unlockTime) - 1);
        vm.startPrank(userA);
        vm.expectRevert(bytes4(keccak256("NothingToWithdraw()")));
        xmetro.withdrawThor(0);
        vm.expectRevert(bytes4(keccak256("NothingToWithdraw()")));
        xmetro.withdrawYThor(0);
        vm.stopPrank();

        vm.warp(thorRequest.unlockTime);
        vm.startPrank(userA);
        assertEq(xmetro.withdrawThor(0), thorPayout);
        assertEq(xmetro.withdrawYThor(0), yThorPayout);
        vm.stopPrank();
        assertEq(metro.balanceOf(userA), thorPayout + yThorPayout);
    }

    function test_YThorCannotExitBeforeDay120OrWithoutPosition() public {
        vm.prank(userA);
        vm.expectRevert(stdError.indexOOBError);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);

        xmetro.creditYThorFromMigration(userA, 100 ether);
        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
    }

    function test_YThorGetsTwoThirdsOfRewardsAgainstEqualNormalPrincipal() public {
        _stake(userA, 100 ether);
        xmetro.creditYThorFromMigration(userB, 100 ether);
        _depositRewards(300e6);

        assertEq(xmetro.rewardWeightOf(userA), 100 ether);
        assertEq(xmetro.rewardWeightOf(userB), 200 ether);
        assertEq(xmetro.claimable(userA), 100e6);
        assertEq(xmetro.claimable(userB), 200e6);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;
        (uint256 total, uint256[] memory amounts) = xmetro.claimableMany(users);
        assertEq(total, 300e6);
        assertEq(amounts[0], 100e6);
        assertEq(amounts[1], 200e6);
    }

    function test_AddingYThorWeightCannotClaimHistoricalRewards() public {
        _stake(userA, 100 ether);
        _depositRewards(100e6);
        assertEq(xmetro.claimable(userA), 100e6);

        xmetro.creditYThorFromMigration(userB, 100 ether);
        assertEq(xmetro.claimable(userB), 0);
        assertEq(xmetro.claimable(userA), 100e6);

        _depositRewards(300e6);
        assertEq(xmetro.claimable(userA), 200e6);
        assertEq(xmetro.claimable(userB), 200e6);
    }

    function test_YThorAutocompoundUsesTwoXPendingAndKeepsLockedPosition() public {
        _stake(userA, 100 ether);
        xmetro.creditYThorFromMigration(userB, 100 ether);
        _depositRewards(300e6);
        assertEq(xmetro.claimable(userB), 200e6);

        MockXMetroDeFiAdapter adapter = _setMockAdapter(1e12, 1);
        metro.mint(address(adapter), 200 ether);
        vm.prank(userB);
        uint256 received = xmetro.autocompound(200 ether, block.timestamp + 1 days, "");

        assertEq(received, 200 ether);
        assertEq(xmetro.balanceOf(userB), 200 ether);
        assertEq(xmetro.lockedShares(userB), 100 ether);
        assertEq(_activeYThorPrincipal(userB), 100 ether);
        assertEq(xmetro.rewardWeightOf(userB), 400 ether);
        assertEq(xmetro.claimable(userB), 0);
    }

    function test_BatchAutocompoundUsesYThorTwoXPendingAndMintsProRata() public {
        _stake(userA, 100 ether);
        xmetro.creditYThorFromMigration(userB, 100 ether);
        _depositRewards(300e6);

        MockXMetroDeFiAdapter adapter = _setMockAdapter(1e12, 3);
        metro.mint(address(adapter), 100 ether);
        xmetro.setAutoCompoundOperator(outsider, true);

        vm.prank(userA);
        xmetro.enableAutocompound();
        vm.prank(userB);
        xmetro.enableAutocompound();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        vm.prank(outsider);
        uint256 received = xmetro.autocompoundBatch(users, 100 ether, block.timestamp + 1 days, "");

        uint256 userACompound = uint256(100 ether) / 3;
        uint256 userBCompound = 100 ether - userACompound;
        assertEq(received, 100 ether);
        assertEq(xmetro.balanceOf(userA), 100 ether + userACompound);
        assertEq(xmetro.balanceOf(userB), userBCompound);
        assertEq(xmetro.rewardWeightOf(userA), 100 ether + userACompound);
        assertEq(xmetro.rewardWeightOf(userB), 200 ether + userBCompound);
        assertEq(xmetro.claimable(userA), 0);
        assertEq(xmetro.claimable(userB), 0);
        assertEq(usdc.balanceOf(address(adapter)), 300e6);
    }

    function test_BatchAutocompoundRequiresOperatorAndSkipsDisabledUsers() public {
        _stake(userA, 100 ether);
        xmetro.creditYThorFromMigration(userB, 100 ether);
        _depositRewards(300e6);

        MockXMetroDeFiAdapter adapter = _setMockAdapter(1e12, 1);
        metro.mint(address(adapter), 100 ether);
        xmetro.setAutoCompoundOperator(outsider, true);
        vm.prank(userA);
        xmetro.enableAutocompound();

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        vm.prank(userA);
        vm.expectRevert(XMetroCore.UnauthorizedOperator.selector);
        xmetro.autocompoundBatch(users, 1, block.timestamp + 1 days, "");

        vm.prank(outsider);
        assertEq(xmetro.autocompoundBatch(users, 100 ether, block.timestamp + 1 days, ""), 100 ether);
        assertEq(xmetro.balanceOf(userA), 200 ether);
        assertEq(xmetro.balanceOf(userB), 0);
        assertEq(xmetro.claimable(userA), 0);
        assertEq(xmetro.claimable(userB), 200e6);
        assertEq(usdc.balanceOf(address(adapter)), 100e6);
    }

    function test_MixedSourcesRemainIsolatedWhenYThorExits() public {
        _stake(userA, 10 ether);
        xmetro.creditThorFromMigration(userA, 100 ether);
        xmetro.creditYThorFromMigration(userA, 100 ether);
        _stakeContributor(userB, userA, 20 ether);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);

        assertEq(xmetro.balanceOf(userA), 10 ether);
        assertEq(xmetro.lockedShares(userA), 220 ether);
        assertEq(xmetro.rewardWeightOf(userA), 330 ether);

        vm.warp(uint256(migratedAt) + 14400 seconds);
        vm.prank(userA);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);

        assertEq(xmetro.balanceOf(userA), 10 ether);
        assertEq(xmetro.lockedShares(userA), 120 ether);
        assertEq(xmetro.rewardWeightOf(userA), 130 ether);
        assertEq(xmetro.contributorVestingCount(userA), 1);
        (uint128 thorPrincipal,,, bool thorExited) = xmetro.thorPositions(userA, 0);
        assertEq(thorPrincipal, 100 ether);
        assertFalse(thorExited);
    }

    function test_ContributorSixMonthCliffTwoPointFiveYearLinearAndBothExitModes() public {
        _stakeContributor(userB, userA, 100 ether);
        XMetroCore.VestingSchedule memory schedule = xmetro.contributorVesting(userA, 0);
        assertEq(schedule.startTime, block.timestamp + xmetro.CONTRIBUTOR_CLIFF());
        assertEq(schedule.duration, xmetro.CONTRIBUTOR_DURATION());

        vm.warp(uint256(schedule.startTime) - 1);
        vm.prank(userA);
        vm.expectRevert(XMetroCore.NoRewards.selector);
        xmetro.claimAndStakeUnlockedContributor(0);

        vm.warp(uint256(schedule.startTime) + uint256(schedule.duration) / 2);
        uint256 totalSharesBefore = xmetro.totalShares();
        vm.prank(userA);
        uint256 staked = xmetro.claimAndStakeUnlockedContributor(0);
        assertEq(staked, 50 ether);
        assertEq(xmetro.balanceOf(userA), 50 ether);
        assertEq(xmetro.lockedShares(userA), 50 ether);
        assertEq(xmetro.totalShares(), totalSharesBefore);

        vm.warp(uint256(schedule.startTime) + uint256(schedule.duration));
        vm.prank(userA);
        uint256 queued = xmetro.requestWithdrawUnlockedContributor(0);
        assertEq(queued, 50 ether);
        assertEq(xmetro.unstakeRequestCountContributor(userA), 1);
        XMetroCore.UnstakeRequest memory request = xmetro.unstakeRequestContributor(userA, 0);
        assertEq(request.unlockTime, block.timestamp + xmetro.UNSTAKE_DELAY());
        vm.warp(request.unlockTime);
        vm.prank(userA);
        assertEq(xmetro.withdrawContributor(0), 50 ether);
    }

    function test_RewardDebtFollowsFreeShareTransfers() public {
        _stake(userA, 100 ether);
        _depositRewards(100e6);

        vm.prank(userA);
        xmetro.transfer(userB, 25 ether);
        vm.prank(userA);
        xmetro.approve(outsider, 25 ether);
        vm.prank(outsider);
        xmetro.transferFrom(userA, userB, 25 ether);
        assertEq(xmetro.claimable(userA), 100e6);
        assertEq(xmetro.claimable(userB), 0);

        _depositRewards(100e6);
        assertEq(xmetro.claimable(userA), 150e6);
        assertEq(xmetro.claimable(userB), 50e6);
    }

    function test_YThorPrincipalUsesIndependentAccumulator() public {
        _stake(userA, 2);
        _depositRewards(2);

        xmetro.creditYThorFromMigration(userB, 1);
        assertEq(xmetro.rewardWeightOf(userB), 2);
        assertEq(xmetro.rewardDebt(userB), 0);
        assertEq(xmetro.claimable(userB), 0);

        _depositRewards(4);
        assertEq(xmetro.claimable(userB), 2);
    }

    function test_PauseCoversCreditsExitsRewardsWithdrawalsAndAutocompound() public {
        _stake(userA, 10 ether);
        xmetro.creditThorFromMigration(userA, 10 ether);
        _depositRewards(1e6);
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 10800 seconds);
        xmetro.pause();

        vm.expectRevert();
        xmetro.creditYThorFromMigration(userB, 1 ether);
        vm.prank(userA);
        vm.expectRevert();
        xmetro.requestThorExit(0);
        vm.prank(userA);
        vm.expectRevert();
        xmetro.claimRewards();
        vm.prank(userA);
        vm.expectRevert();
        xmetro.requestUnstake(1 ether);
        vm.prank(userA);
        vm.expectRevert();
        xmetro.autocompound(1, block.timestamp + 1, "");

        xmetro.unpause();
        vm.prank(userA);
        xmetro.requestThorExit(0);
    }

    function test_EmergencyDistributeCalculatesOnchainSkipsInvalidAndPaysDuplicateOnce() public {
        _stake(userA, 100 ether);
        _stake(userB, 300 ether);
        _depositRewards(400e6);
        xmetro.pause();

        address[] memory users = new address[](5);
        users[0] = address(0);
        users[1] = userA;
        users[2] = userA;
        users[3] = userB;
        users[4] = address(0);

        uint256 distributed = xmetro.emergencyDistribute(users);

        assertEq(distributed, 400e6);
        assertEq(usdc.balanceOf(userA), 100e6);
        assertEq(usdc.balanceOf(userB), 300e6);
        assertEq(xmetro.claimable(userA), 0);
        assertEq(xmetro.claimable(userB), 0);
        assertEq(usdc.balanceOf(address(xmetro)), 0);
    }

    function test_EmergencyDistributeGuardsAndTransferFailureAreAtomic() public {
        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;

        vm.expectRevert();
        xmetro.emergencyDistribute(users);

        _stake(userA, 100 ether);
        _stake(userB, 200 ether);
        _depositRewards(300e6);
        xmetro.pause();

        vm.prank(outsider);
        vm.expectRevert();
        xmetro.emergencyDistribute(users);

        vm.expectRevert(XMetroCore.InvalidArrayLength.selector);
        xmetro.emergencyDistribute(new address[](0));

        vm.mockCallRevert(
            address(usdc), abi.encodeWithSignature("transfer(address,uint256)", userB, 200e6), bytes("blocked")
        );
        vm.expectRevert();
        xmetro.emergencyDistribute(users);

        assertEq(usdc.balanceOf(userA), 0);
        assertEq(usdc.balanceOf(userB), 0);
        assertEq(xmetro.claimable(userA), 100e6);
        assertEq(xmetro.claimable(userB), 200e6);

        vm.clearMockedCalls();
        address[] memory noRewards = new address[](1);
        noRewards[0] = address(0);
        vm.expectRevert(XMetroCore.NoRewards.selector);
        xmetro.emergencyDistribute(noRewards);

        assertEq(xmetro.emergencyDistribute(users), 300e6);
        assertEq(usdc.balanceOf(userA), 100e6);
        assertEq(usdc.balanceOf(userB), 200e6);
    }

    function test_EmergencyDistributeHasNoFixedCandidateLimit() public {
        _stake(userA, 100 ether);
        _depositRewards(100e6);
        xmetro.pause();

        address[] memory users = new address[](101);
        users[100] = userA;

        assertEq(xmetro.emergencyDistribute(users), 100e6);
        assertEq(usdc.balanceOf(userA), 100e6);
        assertEq(xmetro.claimable(userA), 0);
    }

    function test_RescueCannotRemoveBackingMETRO() public {
        _stake(userA, 10 ether);
        vm.expectRevert(bytes4(keccak256("ProtectedToken()")));
        xmetro.rescueERC20(address(metro), userB, 1 ether);

        ERC20Mintable other = new ERC20Mintable("OTHER", "OTHER", 18);
        other.mint(address(xmetro), 5 ether);
        xmetro.rescueERC20(address(other), userB, 5 ether);
        assertEq(other.balanceOf(userB), 5 ether);
    }

    function _activeYThorPrincipal(address user) private view returns (uint256 total) {
        for (uint256 id; id < xmetro.yThorPositionCount(user); ++id) {
            (uint128 principal,,, bool exited) = xmetro.yThorPositions(user, id);
            if (!exited) total += principal;
        }
    }

    function test_EmptyAndOutOfRangePositionQueries() public {
        assertEq(xmetro.thorPositionCount(userA), 0);
        assertEq(xmetro.yThorPositionCount(userA), 0);
        (,,, uint256 total) = xmetro.previewWithdrawableNow(userA);
        assertEq(total, 0);
        vm.expectRevert(stdError.indexOOBError);
        xmetro.thorPositions(userA, 0);
        vm.expectRevert(stdError.indexOOBError);
        xmetro.previewYThorExit(userA, 0);
        xmetro.creditThorFromMigration(userA, 1 ether);
        vm.expectRevert(stdError.indexOOBError);
        xmetro.previewThorExit(userA, 1);
        vm.prank(userB);
        vm.expectRevert(stdError.indexOOBError);
        xmetro.requestThorExit(0);
    }

    function test_MultiplePositionsUseIndependentClocksAndStableIds() public {
        uint256 first = block.timestamp;
        xmetro.creditThorFromMigration(userA, 100 ether);
        xmetro.creditYThorFromMigration(userA, 200 ether);
        vm.warp(first + 1 hours);
        vm.expectEmit(true, true, false, true);
        emit XMetroCore.ThorPositionCreated(userA, 1, 300 ether, uint64(block.timestamp));
        xmetro.creditThorFromMigration(userA, 300 ether);
        vm.expectEmit(true, true, false, true);
        emit XMetroCore.YThorPositionCreated(userA, 1, 400 ether, uint64(block.timestamp));
        xmetro.creditYThorFromMigration(userA, 400 ether);
        (,, uint256 firstThor,, uint256 thorAt) = xmetro.previewThorExit(userA, 0);
        (,,,, uint256 laterThorAt) = xmetro.previewThorExit(userA, 1);
        assertEq(laterThorAt, thorAt + 1 hours);
        assertEq(firstThor, 50 ether);
        (,,,, uint256 firstYAt) = xmetro.previewYThorExit(userA, 0);
        (,,,, uint256 laterYAt) = xmetro.previewYThorExit(userA, 1);
        assertEq(laterYAt, firstYAt + 1 hours);
        vm.warp(firstYAt);
        (bool earlyEligible,,,,) = xmetro.previewYThorExit(userA, 0);
        (bool laterEligible,,,,) = xmetro.previewYThorExit(userA, 1);
        assertTrue(earlyEligible);
        assertFalse(laterEligible);
        vm.warp(laterYAt);
        (,, uint256 y0,,) = xmetro.previewYThorExit(userA, 0);
        (,, uint256 y1,,) = xmetro.previewYThorExit(userA, 1);
        (uint256 thorTotal, uint256 yTotal,, uint256 total) = xmetro.previewWithdrawableNow(userA);
        assertEq(yTotal, y0 + y1);
        assertEq(thorTotal, 400 ether);
        assertEq(total, thorTotal + yTotal);
        vm.prank(userA);
        xmetro.exitYThor(1, XMetroCore.ExitMode.Liquid);
        assertEq(_activeYThorPrincipal(userA), 200 ether);
        assertEq(xmetro.rewardWeightOf(userA), 800 ether);
        vm.prank(userA);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Stake);
        assertEq(_activeYThorPrincipal(userA), 0);
        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.exitYThor(1, XMetroCore.ExitMode.Stake);
        xmetro.creditYThorFromMigration(userA, 50 ether);
        assertEq(xmetro.yThorPositionCount(userA), 3);
        (uint128 retained,,, bool exited) = xmetro.yThorPositions(userA, 1);
        assertEq(retained, 400 ether);
        assertTrue(exited);
        (uint128 newest,,, bool newExited) = xmetro.yThorPositions(userA, 2);
        assertEq(newest, 50 ether);
        assertFalse(newExited);
        // Queue indices follow exit order, independently of position IDs.
        vm.prank(userA);
        xmetro.requestThorExit(1);
        vm.warp(block.timestamp + 1);
        vm.prank(userA);
        xmetro.requestThorExit(0);
        assertEq(xmetro.unstakeRequestThor(userA, 0).amount, 300 ether);
        assertEq(xmetro.unstakeRequestThor(userA, 1).amount, 100 ether);
        uint256 firstUnlock = xmetro.unstakeRequestThor(userA, 0).unlockTime;
        vm.warp(firstUnlock);
        vm.prank(userA);
        assertEq(xmetro.withdrawThor(0), 300 ether);
        vm.warp(firstUnlock + 1);
        vm.prank(userA);
        assertEq(xmetro.withdrawThor(0), 100 ether);
        assertEq(xmetro.thorPositionCount(userA), 2);
        xmetro.creditThorFromMigration(userA, 1 ether);
        assertEq(xmetro.thorPositionCount(userA), 3);
    }

    function test_YThorQuarterBoundariesAndActualOneTimePayouts() public {
        uint256 start = block.timestamp;
        uint256 delay = 4 hours;
        uint256 quarter = 3 hours;
        uint256 expectedForfeiture;
        for (uint256 i; i < 5; ++i) {
            xmetro.creditYThorFromMigration(userA, 100 ether);
        }
        for (uint256 i; i < 5; ++i) {
            uint256 point = start + delay + i * quarter;
            vm.warp(point - 1);
            (bool eligible, uint256 beforeRate,,,) = xmetro.previewYThorExit(userA, i);
            assertEq(eligible, i != 0);
            assertEq(beforeRate, i == 0 ? 0 : 999 + i * 1_000);
            vm.warp(point);
            (bool atPoint, uint256 rate, uint256 payout, uint256 forfeited,) = xmetro.previewYThorExit(userA, i);
            assertTrue(atPoint);
            assertEq(rate, 1_000 + i * 1_000);
            assertEq(payout, (10 + i * 10) * 1 ether);
            assertEq(forfeited + payout, 100 ether);
            vm.warp(point + 1);
            (, uint256 nextRate,,,) = xmetro.previewYThorExit(userA, i);
            assertEq(nextRate, rate);
            vm.prank(userA);
            xmetro.exitYThor(i, XMetroCore.ExitMode.Stake);
            expectedForfeiture += forfeited;
        }
        assertEq(xmetro.balanceOf(userA), 150 ether);
        assertEq(metro.balanceOf(forfeitureRecipient), expectedForfeiture);
        assertEq(xmetro.lockedShares(userA), 0);
        vm.warp(start + delay + 5 * quarter);
        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Stake);
    }

    function testFuzz_RepeatedCreditsCannotClaimHistoricalRewards(bool yThor) public {
        if (yThor) xmetro.creditYThorFromMigration(userA, 3 ether);
        else xmetro.creditThorFromMigration(userA, 3 ether);
        _depositRewards(1e6);
        uint256 prior = xmetro.claimable(userA);
        for (uint256 i; i < 10; ++i) {
            if (yThor) xmetro.creditYThorFromMigration(userB, 1 ether);
            else xmetro.creditThorFromMigration(userB, 1 ether);
        }
        assertEq(xmetro.claimable(userB), 0);
        assertEq(xmetro.claimable(userA), prior);
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), prior);
        vm.prank(userB);
        assertEq(xmetro.claimRewards(), 0);
        assertEq(usdc.balanceOf(address(xmetro)) + prior, 1e6);
    }

    function test_ZeroClaimsAndTransfersPreserveFractionsAndNegativeDebt() public {
        _stake(userA, 2);
        _stake(userB, 2);
        _depositRewards(1);
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), 0);
        vm.startPrank(userA);
        xmetro.transfer(userA, 1);
        xmetro.transfer(userB, 0);
        xmetro.approve(outsider, 2);
        vm.stopPrank();
        vm.prank(outsider);
        xmetro.transferFrom(userA, userB, 2);
        assertEq(xmetro.balanceOf(userA), 0);
        assertEq(xmetro.rewardDebt(userA), 0); // -0.5 truncates toward zero for display.
        vm.prank(userB);
        xmetro.transfer(userA, 2);
        _depositRewards(2);
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), 1);
        vm.prank(userB);
        xmetro.requestUnstake(2);
        assertEq(xmetro.rewardDebt(userB), -1);
        vm.prank(userB);
        assertEq(xmetro.claimRewards(), 1);
        _stake(userB, 2);
        _depositRewards(1);
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), 1);
        vm.prank(userB);
        assertEq(xmetro.claimRewards(), 1);
        assertEq(usdc.balanceOf(address(xmetro)), 0);
    }

    function test_MixedAccumulatorsCombineFractionsAndEmergencyPreservesRemainder() public {
        _stake(userA, 1);
        xmetro.creditYThorFromMigration(userA, 1);
        _stake(userB, 1);
        _depositRewards(2);
        assertEq(xmetro.claimable(userA), 1); // 0.5 normal + 1.0 yTHOR.
        address[] memory candidates = new address[](3);
        candidates[0] = userA;
        candidates[1] = userA;
        candidates[2] = address(0);
        xmetro.pause();
        assertEq(xmetro.emergencyDistribute(candidates), 1);
        xmetro.unpause();
        _depositRewards(2);
        assertEq(xmetro.claimable(userA), 2); // Retained 0.5 plus another 1.5.
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), 2);
        vm.prank(userB);
        assertEq(xmetro.claimRewards(), 1);
        assertEq(usdc.balanceOf(address(xmetro)), 0);
    }

    function test_LaterMintFailureRollsBackPositionCacheDebtAndShares() public {
        xmetro.creditYThorFromMigration(userA, 2 ether);
        _depositRewards(3);
        uint256 pending = xmetro.claimable(userA);
        int256 debt = xmetro.rewardDebt(userA);
        metro.setMinter(address(xmetro), false);
        vm.expectRevert(bytes("MetroToken: not minter"));
        xmetro.creditYThorFromMigration(userA, 4 ether);
        assertEq(xmetro.yThorPositionCount(userA), 1);
        assertEq(_activeYThorPrincipal(userA), 2 ether);
        assertEq(xmetro.totalLockedShares(), 2 ether);
        assertEq(xmetro.totalRewardWeight(), 4 ether);
        assertEq(xmetro.claimable(userA), pending);
        assertEq(xmetro.rewardDebt(userA), debt);
    }

    function test_ScaledDebtRejectsSignedOverflowAndRollsBack() public {
        _stake(userA, 1);
        uint256 reward = uint256(type(int256).max) / 1e24;
        _depositRewards(reward);
        assertEq(xmetro.claimable(userA), reward);
        vm.expectRevert(XMetroCore.InvalidAmount.selector);
        xmetro.creditThorFromMigration(userB, 2);
        assertEq(xmetro.thorPositionCount(userB), 0);
        assertEq(xmetro.totalShares(), 1);
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), reward);
    }
}
