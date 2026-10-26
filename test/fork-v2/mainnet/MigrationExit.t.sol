// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {xMETRO} from "../../../src/xMETRO.sol";
import {ThorMigrationEscrow} from "../../../src/ThorMigrationEscrow.sol";
import {MainnetForkBase, IUniswapV2RouterMainnet} from "./MainnetForkBase.sol";

contract MigrationExitMainnetTest is MainnetForkBase {
    address private alice;
    address private bob;
    address private carol;

    event MigratedThor(address indexed user, uint256 amountIn, uint256 principal);
    event MigratedYThor(address indexed user, uint256 amountIn, uint256 principal);
    event ThorPositionCreated(address indexed user, uint256 indexed positionId, uint256 principal, uint64 migratedAt);
    event YThorPositionCreated(address indexed user, uint256 indexed positionId, uint256 principal, uint64 migratedAt);
    event ThorExited(
        address indexed user,
        uint256 indexed positionId,
        uint256 principal,
        uint256 payout,
        uint256 forfeited,
        uint256 rateBps,
        xMETRO.ExitMode mode,
        uint64 exitedAt,
        address indexed forfeitureRecipient
    );
    event YThorExited(
        address indexed user,
        uint256 indexed positionId,
        uint256 principal,
        uint256 payout,
        uint256 forfeited,
        uint256 rateBps,
        xMETRO.ExitMode mode,
        uint64 exitedAt,
        address indexed forfeitureRecipient
    );
    event UnstakeRequested(
        address indexed user, xMETRO.UnstakeSource indexed source, uint256 amount, uint64 unlockTime
    );
    event Withdrawn(address indexed user, xMETRO.UnstakeSource indexed source, uint256 amount);

    function setUp() public {
        _fork();
        _deploySystem();
        core.unpause();
        alice = makeAddr("migration-alice");
        bob = makeAddr("migration-bob");
        carol = makeAddr("migration-carol");
    }

    function _fundAndApprove(address token, address holder, address user, address destination, uint256 amount)
        internal
    {
        _fundMigrationToken(token, holder, user, amount);
        vm.prank(user);
        IERC20(token).approve(destination, amount);
    }

    function _migrateThor(address user, uint256 amount) internal {
        _fundAndApprove(THOR, THOR_HOLDER, user, address(escrow), amount);
        vm.prank(user);
        escrow.migrateThor(amount);
    }

    function _migrateYThor(address user, uint256 amount) internal {
        _fundAndApprove(YTHOR, YTHOR_HOLDER, user, address(escrow), amount);
        vm.prank(user);
        escrow.migrateYThor(amount);
    }

    function _newEscrow(uint256 start) internal returns (ThorMigrationEscrow fresh) {
        fresh = ThorMigrationEscrow(
            _create(
                abi.encodePacked(
                    _artifact("out-core/ThorMigrationEscrow.sol/ThorMigrationEscrow.json"),
                    abi.encode(address(this), address(core), THOR, YTHOR, start)
                )
            )
        );
    }

    function _thorPrincipal(address user) internal view returns (uint256 principal) {
        (uint128 amount,,,) = core.thorPositions(user, 0);
        return amount;
    }

    function _yThorPrincipal(address user) internal view returns (uint256 principal) {
        (uint128 amount,,,) = core.yThorPositions(user, 0);
        return amount;
    }

    /// E-10.01/.02: Tests real THOR migration custody mint position.
    function test_E10_RealThorMigrationCustodyMintPosition() public {
        _fundAndApprove(THOR, THOR_HOLDER, alice, address(escrow), 100 ether);
        vm.expectEmit(true, true, false, true, address(core));
        emit ThorPositionCreated(alice, 0, 100 ether, uint64(block.timestamp));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit MigratedThor(alice, 100 ether, 100 ether);
        vm.prank(alice);
        escrow.migrateThor(100 ether);
        (uint128 principal, uint64 migratedAt, uint64 exitedAt, bool exited) = core.thorPositions(alice, 0);
        assertEq(principal, 100 ether);
        assertEq(migratedAt, block.timestamp);
        assertEq(exitedAt, 0);
        assertFalse(exited);
        assertEq(core.thorPositionCount(alice), 1);
        assertEq(escrow.migratedThor(), 100 ether);
        assertEq(IERC20(THOR).balanceOf(address(escrow)), 100 ether);
        assertEq(metro.balanceOf(address(core)), 100 ether);
        assertEq(core.lockedShares(alice), 100 ether);
        assertEq(core.balanceOf(alice), 0);
        assertEq(core.totalSharesOf(alice), 100 ether);
        assertEq(IERC20(THOR).balanceOf(alice), 0);
    }

    /// E-10.03: Tests real yTHOR migration and reward weight.
    function test_E10_RealYThorMigrationAndRewardWeight() public {
        _fundAndApprove(YTHOR, YTHOR_HOLDER, alice, address(escrow), 100 ether);
        vm.expectEmit(true, true, false, true, address(core));
        emit YThorPositionCreated(alice, 0, 100 ether, uint64(block.timestamp));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit MigratedYThor(alice, 100 ether, 100 ether);
        vm.prank(alice);
        escrow.migrateYThor(100 ether);
        (uint128 principal, uint64 migratedAt,, bool exited) = core.yThorPositions(alice, 0);
        assertEq(principal, 100 ether);
        assertEq(migratedAt, block.timestamp);
        assertFalse(exited);
        assertEq(IERC20(YTHOR).balanceOf(address(escrow)), 100 ether);
        assertEq(metro.balanceOf(address(core)), 100 ether);
        assertEq(core.lockedShares(alice), 100 ether);
        assertEq(core.rewardWeightOf(alice), 200 ether);
        assertEq(core.totalRewardWeight(), 200 ether);
        _distribute(20e6);
        assertEq(core.claimable(alice), 20e6);
    }

    /// E-10.04: Tests repeated THOR and yTHOR migrations create independent positions.
    function test_E10_IndependentRepeatedThorYThorMigrations() public {
        _migrateThor(alice, 10 ether);
        _migrateYThor(alice, 20 ether);
        assertEq(core.thorPositionCount(alice), 1);
        assertEq(core.yThorPositionCount(alice), 1);
        assertEq(core.lockedShares(alice), 30 ether);
        vm.warp(block.timestamp + 1);
        _migrateThor(alice, 1 ether);
        _migrateYThor(alice, 2 ether);
        assertEq(core.thorPositionCount(alice), 2);
        assertEq(core.yThorPositionCount(alice), 2);
        (uint128 thorLater, uint64 thorTime,,) = core.thorPositions(alice, 1);
        (uint128 yThorLater, uint64 yThorTime,,) = core.yThorPositions(alice, 1);
        assertEq(thorLater, 1 ether);
        assertEq(yThorLater, 2 ether);
        assertEq(thorTime, block.timestamp);
        assertEq(yThorTime, block.timestamp);
        assertEq(escrow.migratedThor(), 11 ether);
        assertEq(escrow.migratedYThor(), 22 ether);
    }

    /// E-10.05: Tests start deadline ratio rounding and principal cap.
    function test_E10_StartDeadlineRatioRoundingAndPrincipalCap() public {
        uint256 start = block.timestamp + 1 days;
        ThorMigrationEscrow fresh = _newEscrow(start);
        fresh.setRatios(5e17, 15e17);
        fresh.setCaps(50 ether, 150 ether);
        fresh.setDeadlines(start + 2 days, start + 2 days);
        core.setMigrationEscrow(address(fresh));
        _fundAndApprove(THOR, THOR_HOLDER, alice, address(fresh), 100 ether);
        _fundAndApprove(YTHOR, YTHOR_HOLDER, bob, address(fresh), 100 ether);
        vm.warp(start - 1);
        vm.prank(alice);
        vm.expectRevert("ThorEscrow: not started");
        fresh.migrateThor(100 ether);
        vm.warp(start);
        vm.prank(alice);
        vm.expectRevert("ThorEscrow: zero mint");
        fresh.migrateThor(1);
        vm.prank(alice);
        fresh.migrateThor(100 ether);
        assertEq(fresh.migratedThor(), 50 ether);
        assertEq(_thorPrincipal(alice), 50 ether);
        _fundAndApprove(THOR, THOR_HOLDER, carol, address(fresh), 1 ether);
        vm.prank(carol);
        vm.expectRevert("ThorEscrow: thor cap");
        fresh.migrateThor(1 ether);
        vm.warp(start + 2 days);
        vm.prank(bob);
        fresh.migrateYThor(100 ether);
        assertEq(fresh.migratedYThor(), 150 ether);
        assertEq(_yThorPrincipal(bob), 150 ether);
        address late = makeAddr("migration-late");
        _fundAndApprove(YTHOR, YTHOR_HOLDER, late, address(fresh), 1 ether);
        vm.warp(start + 2 days + 1);
        vm.prank(late);
        vm.expectRevert("ThorEscrow: ythor expired");
        fresh.migrateYThor(1 ether);
        assertEq(IERC20(THOR).balanceOf(address(fresh)), 100 ether);
        assertEq(IERC20(YTHOR).balanceOf(address(fresh)), 100 ether);
    }

    /// E-10.06: Tests transfer mint and cap failures are atomic.
    function test_E10_TransferMintAndCapFailuresAreAtomic() public {
        _fundMigrationToken(THOR, THOR_HOLDER, alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        escrow.migrateThor(1 ether);
        vm.prank(alice);
        IERC20(THOR).approve(address(escrow), 2 ether);
        vm.prank(alice);
        vm.expectRevert();
        escrow.migrateThor(2 ether);
        metro.setMinter(address(core), false);
        vm.prank(alice);
        vm.expectRevert("MetroToken: not minter");
        escrow.migrateThor(1 ether);
        metro.setMinter(address(core), true);
        metro.setMinter(address(this), true);
        metro.mint(address(this), 100_000_000 ether);
        vm.prank(alice);
        vm.expectRevert();
        escrow.migrateThor(1 ether);
        _fundMigrationToken(YTHOR, YTHOR_HOLDER, bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        escrow.migrateYThor(1 ether);
        vm.prank(bob);
        IERC20(YTHOR).approve(address(escrow), 1 ether);
        metro.setMinter(address(core), false);
        vm.prank(bob);
        vm.expectRevert("MetroToken: not minter");
        escrow.migrateYThor(1 ether);
        metro.setMinter(address(core), true);
        vm.prank(bob);
        vm.expectRevert();
        escrow.migrateYThor(1 ether);
        assertEq(core.thorPositionCount(alice), 0);
        assertEq(core.yThorPositionCount(bob), 0);
        assertEq(escrow.migratedThor(), 0);
        assertEq(escrow.migratedYThor(), 0);
        assertEq(IERC20(THOR).balanceOf(address(escrow)), 0);
        assertEq(IERC20(YTHOR).balanceOf(address(escrow)), 0);
        assertEq(IERC20(THOR).balanceOf(alice), 1 ether);
        assertEq(IERC20(YTHOR).balanceOf(bob), 1 ether);
        assertEq(core.thorPositionCount(alice), 0);
        assertEq(core.yThorPositionCount(bob), 0);
        assertEq(core.lockedShares(alice), 0);
        assertEq(metro.balanceOf(address(core)), 0);
    }

    /// E-10.07: Tests only bound escrow can credit.
    function test_E10_OnlyBoundEscrowCanCredit() public {
        vm.prank(alice);
        vm.expectRevert();
        core.creditThorFromMigration(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        core.creditYThorFromMigration(alice, 1 ether);
        ThorMigrationEscrow fresh = _newEscrow(block.timestamp);
        fresh.setRatios(1e18, 1e18);
        fresh.setCaps(1_000 ether, 1_000 ether);
        fresh.setDeadlines(block.timestamp + 1 days, block.timestamp + 1 days);
        core.setMigrationEscrow(address(fresh));
        _fundAndApprove(THOR, THOR_HOLDER, alice, address(escrow), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        escrow.migrateThor(1 ether);
        assertEq(core.thorPositionCount(alice), 0);
        assertEq(IERC20(THOR).balanceOf(address(escrow)), 0);
        assertEq(core.lockedShares(alice), 0);
        _fundAndApprove(THOR, THOR_HOLDER, bob, address(fresh), 1 ether);
        vm.prank(bob);
        fresh.migrateThor(1 ether);
        assertEq(core.lockedShares(bob), 1 ether);
    }

    /// E-11.01: Tests start time owner and boundary.
    function test_E11_StartTimeOwnerAndBoundary() public {
        vm.prank(alice);
        vm.expectRevert();
        escrow.setMigrationStartTime(block.timestamp + 1 days);
        vm.expectRevert("ThorEscrow: bad start time");
        escrow.setMigrationStartTime(block.timestamp - 1);
        escrow.setMigrationStartTime(block.timestamp + 1 days);
        assertEq(escrow.migrationStartTime(), block.timestamp + 1 days);
        escrow.setMigrationStartTime(block.timestamp);
        assertEq(escrow.migrationStartTime(), block.timestamp);
    }

    /// E-11.02: Tests deadlines owner and start relations.
    function test_E11_DeadlinesOwnerAndStartRelations() public {
        escrow.setMigrationStartTime(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert();
        escrow.setDeadlines(block.timestamp + 2 days, block.timestamp + 2 days);
        vm.expectRevert("ThorEscrow: bad deadline");
        escrow.setDeadlines(block.timestamp - 1, block.timestamp + 2 days);
        vm.expectRevert("ThorEscrow: deadline before start");
        escrow.setDeadlines(block.timestamp + 1 days, block.timestamp + 2 days);
        escrow.setDeadlines(block.timestamp + 2 days, block.timestamp + 3 days);
        assertEq(escrow.deadlineThor(), block.timestamp + 2 days);
        assertEq(escrow.deadlineYThor(), block.timestamp + 3 days);
    }

    /// E-11.03: Tests caps owner nonzero and no retroactivity.
    function test_E11_CapsOwnerNonzeroAndNoRetroactivity() public {
        _migrateThor(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        escrow.setCaps(20 ether, 20 ether);
        vm.expectRevert("ThorEscrow: bad cap");
        escrow.setCaps(0, 20 ether);
        escrow.setCaps(5 ether, 20 ether);
        assertEq(escrow.migratedThor(), 10 ether);
        assertEq(_thorPrincipal(alice), 10 ether);
        escrow.setCaps(10 ether, 20 ether);
        assertEq(escrow.migratedThor(), 10 ether);
        assertEq(_thorPrincipal(alice), 10 ether);
        _fundAndApprove(THOR, THOR_HOLDER, bob, address(escrow), 1 ether);
        vm.prank(bob);
        vm.expectRevert("ThorEscrow: thor cap");
        escrow.migrateThor(1 ether);
        escrow.setCaps(11 ether, 20 ether);
        vm.prank(bob);
        escrow.migrateThor(1 ether);
        assertEq(escrow.migratedThor(), 11 ether);
    }

    /// E-11.04: Tests ratios first set locks immediately.
    function test_E11_RatiosFirstSetLocksImmediately() public {
        ThorMigrationEscrow fresh = _newEscrow(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert();
        fresh.setRatios(1e18, 1e18);
        vm.expectRevert("ThorEscrow: bad ratio");
        fresh.setRatios(0, 1e18);
        fresh.setRatios(15e17, 25e17);
        assertEq(fresh.ratioThor(), 15e17);
        assertEq(fresh.ratioYThor(), 25e17);
        vm.expectRevert("ThorEscrow: ratios locked");
        fresh.setRatios(1e18, 1e18);
        assertLt(block.timestamp, fresh.migrationStartTime());
    }

    /// E-12.01: Tests THOR exit curve independent snapshots.
    function test_E12_ThorExitCurveIndependentSnapshots() public {
        _migrateThor(alice, 100 ether);
        (uint128 principal, uint64 migratedAt,,) = core.thorPositions(alice, 0);
        assertEq(principal, 100 ether);
        uint256 snapshot = vm.snapshotState();
        vm.warp(uint256(migratedAt) + 30 days - 1);
        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited, uint256 eligibleAt) =
            core.previewThorExit(alice, 0);
        assertFalse(eligible);
        assertEq(rate, 0);
        assertEq(payout, 0);
        assertEq(forfeited, 0);
        assertEq(eligibleAt, uint256(migratedAt) + 30 days);
        vm.prank(alice);
        vm.expectRevert();
        core.requestThorExit(0);
        assertTrue(vm.revertToState(snapshot));
        _assertThorExitAt(alice, migratedAt, 30 days, 5_000, 50 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertThorExitAt(alice, migratedAt, 60 days, 7_500, 75 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertThorExitAt(alice, migratedAt, 90 days, 10_000, 100 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertThorExitAt(alice, migratedAt, 91 days, 10_000, 100 ether);
    }

    function _assertThorExitAt(
        address user,
        uint64 migratedAt,
        uint256 elapsed,
        uint256 expectedRate,
        uint256 expectedPayout
    ) internal {
        vm.warp(uint256(migratedAt) + elapsed);
        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited, uint256 eligibleAt) =
            core.previewThorExit(user, 0);
        assertTrue(eligible);
        assertEq(rate, expectedRate);
        assertEq(payout, expectedPayout);
        assertEq(forfeited, 100 ether - expectedPayout);
        assertEq(eligibleAt, uint256(migratedAt) + 30 days);
        vm.prank(user);
        (uint256 actualPayout, uint256 actualForfeited) = core.requestThorExit(0);
        assertEq(actualPayout, expectedPayout);
        assertEq(actualForfeited, forfeited);
    }

    /// E-12.02: Tests liquid and stake exit paths.
    function test_E12_LiquidAndStakeExitPaths() public {
        _migrateThor(alice, 100 ether);
        _migrateThor(bob, 100 ether);
        vm.warp(block.timestamp + 60 days);
        vm.prank(alice);
        (uint256 liquid, uint256 liquidForfeited) = core.requestThorExit(0);
        vm.prank(bob);
        (uint256 staked, uint256 stakeForfeited) = core.exitAndStakeThor(0);
        assertEq(liquid, 75 ether);
        assertEq(staked, 75 ether);
        assertEq(liquidForfeited + stakeForfeited, 50 ether);
        assertEq(core.unstakeRequestCountThor(alice), 1);
        assertEq(core.unstakeRequestCountFree(alice), 0);
        assertEq(core.balanceOf(bob), 75 ether);
        assertEq(core.lockedShares(bob), 0);
        assertEq(metro.balanceOf(address(core)), 150 ether);
        assertEq(metro.balanceOf(forfeitureRecipient), 50 ether);
        uint256 unlock = core.unstakeRequestThor(alice, 0).unlockTime;
        vm.warp(unlock);
        vm.prank(alice);
        assertEq(core.withdrawThor(0), 75 ether);
        assertEq(metro.balanceOf(alice), 75 ether);
        assertEq(metro.balanceOf(address(core)), 75 ether);
    }

    /// E-12.03: Tests forfeiture recipient and METRO backing.
    function test_E12_ForfeitureRecipientAndMetroBacking() public {
        _migrateThor(alice, 100 ether);
        uint256 supply = metro.totalSupply();
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        (uint256 payout, uint256 forfeited) = core.requestThorExit(0);
        assertEq(payout + forfeited, 100 ether);
        assertEq(payout, 50 ether);
        assertEq(forfeited, 50 ether);
        assertEq(metro.balanceOf(forfeitureRecipient), 50 ether);
        assertEq(metro.balanceOf(address(core)), 50 ether);
        assertEq(metro.totalSupply(), supply);
        assertEq(IERC20(THOR).balanceOf(address(escrow)), 100 ether);
    }

    /// E-12.04: Tests one time close and historical rewards.
    function test_E12_OneTimeCloseAndHistoricalRewards() public {
        _migrateThor(alice, 100 ether);
        _mintAndStake(bob, 100 ether);
        _distribute(200e6);
        assertEq(core.claimable(alice), 100e6);
        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        core.exitAndStakeThor(0);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.balanceOf(alice), 50 ether);
        (,, uint64 exitedAt, bool exited) = core.thorPositions(alice, 0);
        assertTrue(exited);
        assertEq(exitedAt, block.timestamp);
        vm.prank(alice);
        vm.expectRevert();
        core.requestThorExit(0);
        _distribute(150e6);
        assertEq(core.claimable(alice), 150e6);
        assertEq(core.claimable(bob), 200e6);
        vm.prank(alice);
        assertEq(core.claimRewards(), 150e6);
        assertEq(IERC20(USDC).balanceOf(alice), 150e6);
    }

    /// E-12.05: Tests THOR queue boundary position and events.
    function test_E12_ThorQueueBoundaryPositionAndEvents() public {
        vm.prank(alice);
        assertEq(core.withdrawThor(0), 0);
        _migrateThor(alice, 100 ether);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(true, true, false, true, address(core));
        emit UnstakeRequested(alice, xMETRO.UnstakeSource.Thor, 50 ether, uint64(block.timestamp + 72 hours));
        vm.expectEmit(true, true, true, true, address(core));
        emit ThorExited(
            alice,
            0,
            100 ether,
            50 ether,
            50 ether,
            5_000,
            xMETRO.ExitMode.Liquid,
            uint64(block.timestamp),
            forfeitureRecipient
        );
        vm.prank(alice);
        core.requestThorExit(0);
        assertEq(core.unstakeRequestCountThor(alice), 1);
        assertEq(core.unstakeRequestCountYThor(alice), 0);
        assertEq(core.unstakeRequestCountContributor(alice), 0);
        assertEq(core.unstakeCursorThor(alice), 0);
        uint256 unlock = core.unstakeRequestThor(alice, 0).unlockTime;
        vm.warp(unlock - 1);
        vm.prank(alice);
        vm.expectRevert(xMETRO.NothingToWithdraw.selector);
        core.withdrawThor(0);
        vm.warp(unlock);
        vm.expectEmit(true, true, false, true, address(core));
        emit Withdrawn(alice, xMETRO.UnstakeSource.Thor, 50 ether);
        vm.prank(alice);
        assertEq(core.withdrawThor(0), 50 ether);
        assertEq(core.unstakeCursorThor(alice), 1);
        vm.prank(alice);
        assertEq(core.withdrawThor(0), 0);
        (uint256 thorAmount, uint256 yThorAmount, uint256 contributorAmount, uint256 totalAmount) =
            core.previewWithdrawableNow(alice);
        assertEq(thorAmount + yThorAmount + contributorAmount + totalAmount, 0);
    }

    /// E-13.01: Tests yTHOR exit curve independent snapshots.
    function test_E13_YThorExitCurveIndependentSnapshots() public {
        _migrateYThor(alice, 1_000 ether);
        (, uint64 migratedAt,,) = core.yThorPositions(alice, 0);
        uint256 snapshot = vm.snapshotState();
        vm.warp(uint256(migratedAt) + 120 days - 1);
        (bool eligible, uint256 rate, uint256 payout,, uint256 eligibleAt) = core.previewYThorExit(alice, 0);
        assertFalse(eligible);
        assertEq(rate, 0);
        assertEq(payout, 0);
        assertEq(eligibleAt, uint256(migratedAt) + 120 days);
        vm.prank(alice);
        vm.expectRevert();
        core.exitYThor(0, xMETRO.ExitMode.Liquid);
        assertTrue(vm.revertToState(snapshot));
        _assertYThorExitAt(alice, migratedAt, 120 days, 2_000, 200 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertYThorExitAt(alice, migratedAt, 120 days + 365 days, 4_000, 400 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertYThorExitAt(alice, migratedAt, 120 days + 2 * 365 days, 6_000, 600 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertYThorExitAt(alice, migratedAt, 120 days + 3 * 365 days, 8_000, 800 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertYThorExitAt(alice, migratedAt, 120 days + 4 * 365 days - 1, 9_999, 999.9 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertYThorExitAt(alice, migratedAt, 120 days + 4 * 365 days, 10_000, 1_000 ether);
        assertTrue(vm.revertToState(snapshot));
        _assertYThorExitAt(alice, migratedAt, 120 days + 4 * 365 days + 1, 10_000, 1_000 ether);
    }

    function _assertYThorExitAt(
        address user,
        uint64 migratedAt,
        uint256 elapsed,
        uint256 expectedRate,
        uint256 expectedPayout
    ) internal {
        vm.warp(uint256(migratedAt) + elapsed);
        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited, uint256 eligibleAt) =
            core.previewYThorExit(user, 0);
        assertTrue(eligible);
        assertEq(rate, expectedRate);
        assertEq(payout, expectedPayout);
        assertEq(forfeited, 1_000 ether - expectedPayout);
        assertEq(eligibleAt, uint256(migratedAt) + 120 days);
        vm.prank(user);
        (uint256 actualPayout, uint256 actualForfeited) = core.exitYThor(0, xMETRO.ExitMode.Liquid);
        assertEq(actualPayout, expectedPayout);
        assertEq(actualForfeited, forfeited);
    }

    /// E-13.02: Tests yTHOR liquid and stake paths.
    function test_E13_YThorLiquidAndStakePaths() public {
        _migrateYThor(alice, 100 ether);
        _migrateYThor(bob, 100 ether);
        vm.warp(block.timestamp + 120 days);
        vm.prank(alice);
        (uint256 liquid, uint256 liquidForfeited) = core.exitYThor(0, xMETRO.ExitMode.Liquid);
        vm.prank(bob);
        (uint256 stake, uint256 stakeForfeited) = core.exitYThor(0, xMETRO.ExitMode.Stake);
        assertEq(liquid, 20 ether);
        assertEq(stake, 20 ether);
        assertEq(liquidForfeited + stakeForfeited, 160 ether);
        assertEq(core.unstakeRequestCountYThor(alice), 1);
        assertEq(core.unstakeRequestCountThor(alice), 0);
        assertEq(core.balanceOf(bob), 20 ether);
        assertEq(core.lockedShares(bob), 0);
        assertEq(metro.balanceOf(address(core)), 40 ether);
        vm.warp(core.unstakeRequestYThor(alice, 0).unlockTime);
        vm.prank(alice);
        assertEq(core.withdrawYThor(0), 20 ether);
        assertEq(metro.balanceOf(alice), 20 ether);
    }

    /// E-13.03: Tests active principal weight forfeiture backing.
    function test_E13_ActivePrincipalWeightForfeitureBacking() public {
        _migrateYThor(alice, 100 ether);
        assertEq(core.totalRewardWeight(), 200 ether);
        uint256 supply = metro.totalSupply();
        vm.warp(block.timestamp + 120 days);
        vm.prank(alice);
        (uint256 payout, uint256 forfeited) = core.exitYThor(0, xMETRO.ExitMode.Liquid);
        assertEq(payout + forfeited, 100 ether);
        assertEq(core.rewardWeightOf(alice), 0);
        assertEq(core.totalRewardWeight(), 0);
        assertEq(core.lockedShares(alice), 0);
        assertEq(core.totalShares(), 0);
        assertEq(metro.balanceOf(forfeitureRecipient), forfeited);
        assertEq(metro.balanceOf(address(core)), payout);
        assertEq(metro.totalSupply(), supply);
        assertEq(IERC20(YTHOR).balanceOf(address(escrow)), 100 ether);
    }

    /// E-13.04: Tests closed position old pending claim or auto.
    function test_E13_ClosedPositionOldPendingClaimOrAuto() public {
        _migrateYThor(alice, 100 ether);
        _mintAndStake(bob, 100 ether);
        _distribute(300e6);
        assertEq(core.claimable(alice), 200e6);
        vm.warp(block.timestamp + 120 days);
        vm.prank(alice);
        core.exitYThor(0, xMETRO.ExitMode.Liquid);
        _distribute(100e6);
        assertEq(core.claimable(alice), 200e6);
        assertEq(core.claimable(bob), 200e6);
        vm.prank(alice);
        vm.expectRevert();
        core.exitYThor(0, xMETRO.ExitMode.Stake);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        assertEq(core.claimRewards(), 200e6);
        assertEq(core.claimable(alice), 0);
        assertTrue(vm.revertToState(snapshot));
        _configureSwaps();
        _createMetroPool(10_000 ether, 10_000e6);
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(metro);
        uint256 quote = IUniswapV2RouterMainnet(V2_ROUTER).getAmountsOut(200e6, path)[1];
        vm.prank(alice);
        uint256 received = core.autocompound(quote, block.timestamp + 1 hours, abi.encode(uint8(0), abi.encode(path)));
        assertEq(received, quote);
        assertEq(core.balanceOf(alice), received);
        assertEq(core.claimable(alice), 0);
        assertEq(core.rewardWeightOf(alice), received);
    }

    /// E-13.05: Tests yTHOR queue events and boundary.
    function test_E13_YThorQueueEventsAndBoundary() public {
        vm.prank(alice);
        assertEq(core.withdrawYThor(0), 0);
        _migrateYThor(alice, 100 ether);
        vm.warp(block.timestamp + 120 days);
        vm.expectEmit(true, true, false, true, address(core));
        emit UnstakeRequested(alice, xMETRO.UnstakeSource.YThor, 20 ether, uint64(block.timestamp + 72 hours));
        vm.expectEmit(true, true, true, true, address(core));
        emit YThorExited(
            alice,
            0,
            100 ether,
            20 ether,
            80 ether,
            2_000,
            xMETRO.ExitMode.Liquid,
            uint64(block.timestamp),
            forfeitureRecipient
        );
        vm.prank(alice);
        core.exitYThor(0, xMETRO.ExitMode.Liquid);
        (uint128 principal, uint64 migratedAt, uint64 exitedAt, bool exited) = core.yThorPositions(alice, 0);
        assertEq(principal, 100 ether);
        assertEq(exitedAt, block.timestamp);
        assertGt(exitedAt, migratedAt);
        assertTrue(exited);
        assertEq(core.unstakeRequestCountYThor(alice), 1);
        assertEq(core.unstakeCursorYThor(alice), 0);
        uint256 unlock = core.unstakeRequestYThor(alice, 0).unlockTime;
        vm.warp(unlock - 1);
        vm.prank(alice);
        vm.expectRevert(xMETRO.NothingToWithdraw.selector);
        core.withdrawYThor(0);
        vm.warp(unlock);
        vm.expectEmit(true, true, false, true, address(core));
        emit Withdrawn(alice, xMETRO.UnstakeSource.YThor, 20 ether);
        vm.prank(alice);
        assertEq(core.withdrawYThor(0), 20 ether);
        assertEq(core.unstakeCursorYThor(alice), 1);
        vm.prank(alice);
        assertEq(core.withdrawYThor(0), 0);
    }

    /// E-15.01: Tests mixed positions preview is source sum.
    function test_E15_MixedPositionsPreviewIsSourceSum() public {
        _migrateThor(alice, 100 ether);
        _migrateYThor(alice, 100 ether);
        metro.setMinter(address(this), true);
        metro.mint(alice, 100 ether);
        core.setContributor(alice, true);
        vm.startPrank(alice);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, alice);
        vm.stopPrank();
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(alice, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration / 2);
        (bool thorEligible,, uint256 thorPreview,,) = core.previewThorExit(alice, 0);
        (bool yEligible,, uint256 yPreview,,) = core.previewYThorExit(alice, 0);
        assertTrue(thorEligible);
        assertTrue(yEligible);
        (uint256 thorAmount, uint256 yAmount, uint256 contributorAmount, uint256 total) =
            core.previewWithdrawableNow(alice);
        assertEq(thorAmount, thorPreview);
        assertEq(yAmount, yPreview);
        assertEq(contributorAmount, 50 ether);
        assertEq(total, thorAmount + yAmount + contributorAmount);
    }

    /// E-15.02: Tests all four queues excluded even after maturity.
    function test_E15_AllFourQueuesExcludedEvenAfterMaturity() public {
        _mintAndStake(alice, 100 ether);
        _migrateThor(alice, 100 ether);
        _migrateYThor(alice, 100 ether);
        metro.mint(alice, 100 ether);
        core.setContributor(alice, true);
        vm.startPrank(alice);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, alice);
        core.requestUnstake(100 ether);
        vm.stopPrank();
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(alice, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration);
        vm.startPrank(alice);
        core.requestThorExit(0);
        core.exitYThor(0, xMETRO.ExitMode.Liquid);
        core.requestWithdrawUnlockedContributor(0);
        vm.stopPrank();
        assertEq(core.unstakeRequestCountFree(alice), 1);
        assertEq(core.unstakeRequestCountThor(alice), 1);
        assertEq(core.unstakeRequestCountYThor(alice), 1);
        assertEq(core.unstakeRequestCountContributor(alice), 1);
        (uint256 thorAmount, uint256 yAmount, uint256 contributorAmount, uint256 total) =
            core.previewWithdrawableNow(alice);
        assertEq(thorAmount + yAmount + contributorAmount + total, 0);
        vm.warp(block.timestamp + 72 hours);
        (thorAmount, yAmount, contributorAmount, total) = core.previewWithdrawableNow(alice);
        assertEq(thorAmount + yAmount + contributorAmount + total, 0);
        vm.prank(alice);
        assertGt(core.withdrawFree(0), 0);
        (thorAmount, yAmount, contributorAmount, total) = core.previewWithdrawableNow(alice);
        assertEq(thorAmount + yAmount + contributorAmount + total, 0);
    }

    /// E-15.03: Tests empty partially consumed and closed preview.
    function test_E15_EmptyPartiallyConsumedAndClosedPreview() public {
        address empty = makeAddr("empty-preview");
        (uint256 thorAmount, uint256 yAmount, uint256 contributorAmount, uint256 total) =
            core.previewWithdrawableNow(empty);
        assertEq(thorAmount + yAmount + contributorAmount + total, 0);
        _migrateThor(alice, 100 ether);
        _migrateYThor(alice, 100 ether);
        metro.setMinter(address(this), true);
        metro.mint(alice, 100 ether);
        core.setContributor(alice, true);
        vm.startPrank(alice);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, alice);
        vm.stopPrank();
        vm.expectRevert();
        core.contributorVesting(alice, 1);
        vm.expectRevert();
        core.unstakeRequestThor(alice, 0);
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(alice, 0);
        vm.warp(uint256(schedule.startTime) + schedule.duration / 2);
        (thorAmount, yAmount, contributorAmount, total) = core.previewWithdrawableNow(alice);
        assertEq(contributorAmount, 50 ether);
        assertEq(total, thorAmount + yAmount + contributorAmount);
        vm.prank(alice);
        assertEq(core.claimAndStakeUnlockedContributor(0), 50 ether);
        (thorAmount, yAmount, contributorAmount, total) = core.previewWithdrawableNow(alice);
        assertEq(contributorAmount, 0);
        assertEq(total, thorAmount + yAmount);
        vm.warp(uint256(schedule.startTime) + schedule.duration);
        (thorAmount, yAmount, contributorAmount, total) = core.previewWithdrawableNow(alice);
        assertEq(contributorAmount, 50 ether);
        vm.startPrank(alice);
        core.requestThorExit(0);
        core.exitYThor(0, xMETRO.ExitMode.Liquid);
        core.claimAndStakeUnlockedContributor(0);
        vm.stopPrank();
        (thorAmount, yAmount, contributorAmount, total) = core.previewWithdrawableNow(alice);
        assertEq(thorAmount + yAmount + contributorAmount + total, 0);
    }
}
