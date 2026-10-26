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
        assertEq(yPayout, 20 ether);
        assertEq(yForfeited, 80 ether);
        assertEq(metro.balanceOf(forfeiture), 80 ether);

        vm.warp(block.timestamp + xmetro.UNSTAKE_DELAY());
        vm.prank(userA);
        xmetro.withdrawThor(0);
        vm.prank(userB);
        xmetro.withdrawYThor(0);
        assertEq(metro.balanceOf(userA), 100 ether);
        assertEq(metro.balanceOf(userB), 20 ether);
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

    function test_YThorHalfRatioLiquidExitAtStart() public {
        _halfRatioExit(false, false);
    }

    function test_YThorHalfRatioLiquidExitAtMaturity() public {
        _halfRatioExit(false, true);
    }

    function test_YThorHalfRatioStakeExitAtStart() public {
        _halfRatioExit(true, false);
    }

    function test_YThorHalfRatioStakeExitAtMaturity() public {
        _halfRatioExit(true, true);
    }

    function _halfRatioExit(bool stakeMode, bool mature) private {
        escrow = new ThorMigrationEscrow(address(this), address(xmetro), address(thor), address(yThor), block.timestamp);
        escrow.setCaps(1_000 ether, 1_000 ether);
        escrow.setRatios(1e18, 0.5e18);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        xmetro.setMigrationEscrow(address(escrow));
        uint256 supply = metro.totalSupply();
        _migrate(userA, yThor, 100 ether, true);
        assertEq(metro.totalSupply() - supply, 50 ether);
        (uint128 principal, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        assertEq(principal, 50 ether);
        assertEq(xmetro.rewardWeightOf(userA), 100 ether);
        assertEq(yThor.balanceOf(address(escrow)), 100 ether);
        _migrate(userB, thor, 100 ether, false);
        _distributeTestRewards(200e6);
        assertEq(xmetro.claimable(userA), 100e6);
        vm.warp(uint256(migratedAt) + 14400 seconds + (mature ? 43200 seconds : 0));
        supply = metro.totalSupply();
        vm.prank(userA);
        (uint256 payout, uint256 forfeited) =
            xmetro.exitYThor(0, stakeMode ? xMETRO.ExitMode.Stake : xMETRO.ExitMode.Liquid);
        assertEq(payout, mature ? 50 ether : 10 ether);
        assertEq(forfeited, mature ? 0 : 40 ether);
        assertEq(metro.balanceOf(forfeiture), forfeited);
        assertEq(metro.totalSupply(), supply);
        assertEq(xmetro.claimable(userA), 100e6);
        assertEq(xmetro.lockedShares(userA), 0);
        (,,, bool exited) = xmetro.yThorPositions(userA, 0);
        assertTrue(exited);
        assertEq(xmetro.rewardWeightOf(userA), stakeMode ? payout : 0);
        vm.prank(userA);
        vm.expectRevert(xMETRO.InvalidConfiguration.selector);
        xmetro.exitYThor(0, xMETRO.ExitMode.Stake);
        _distributeTestRewards(100e6 + (stakeMode ? payout / 1e12 : 0));
        vm.prank(userA);
        assertEq(xmetro.claimRewards(), 100e6 + (stakeMode ? payout / 1e12 : 0));
        assertEq(xmetro.claimable(userB), 200e6);
        if (stakeMode) {
            assertEq(xmetro.balanceOf(userA), payout);
            assertEq(xmetro.unstakeRequestCountYThor(userA), 0);
        } else {
            assertEq(xmetro.unstakeRequestCountYThor(userA), 1);
            vm.warp(block.timestamp + 1800 seconds - 1);
            vm.prank(userA);
            vm.expectRevert(xMETRO.NothingToWithdraw.selector);
            xmetro.withdrawYThor(0);
            vm.warp(block.timestamp + 1);
            vm.prank(userA);
            assertEq(xmetro.withdrawYThor(0), payout);
            assertEq(metro.balanceOf(userA), payout);
        }
    }

    function _distributeTestRewards(uint256 amount) private {
        usdc.mint(address(this), amount);
        usdc.approve(address(distributor), amount);
        distributor.distribute(amount);
    }

    function test_TreasuryRealMigrationRewardsAndExitAccounting() public {
        _migrate(forfeiture, thor, 100 ether, false);
        _migrate(forfeiture, yThor, 100 ether, true);
        _migrate(userA, thor, 100 ether, false);
        _migrate(userB, yThor, 100 ether, true);
        assertEq(xmetro.rewardWeightOf(forfeiture), 0);
        assertEq(xmetro.totalRewardWeight(), 300 ether);
        vault.setTargetBalance(30e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(2_000);
        _distributeTestRewards(300e6);
        assertEq(xmetro.claimable(forfeiture), 0);
        assertEq(xmetro.claimable(userA), 90e6);
        assertEq(xmetro.claimable(userB), 180e6);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 3600 seconds);
        vm.prank(forfeiture);
        (uint256 thorPayout, uint256 thorForfeited) = xmetro.exitAndStakeThor(0);
        assertEq(thorPayout, 50 ether);
        assertEq(thorForfeited, 50 ether);
        assertEq(metro.balanceOf(forfeiture), 50 ether);
        assertEq(xmetro.rewardWeightOf(forfeiture), 50 ether);
        assertEq(xmetro.claimable(forfeiture), 0);
        _distributeTestRewards(350e6);
        assertEq(xmetro.claimable(forfeiture), 50e6);
        vm.warp(start + 14400 seconds);
        vm.prank(forfeiture);
        (uint256 yPayout, uint256 yForfeited) = xmetro.exitYThor(0, xMETRO.ExitMode.Liquid);
        assertEq(yPayout, 20 ether);
        assertEq(yForfeited, 80 ether);
        assertEq(metro.balanceOf(forfeiture), 130 ether);
        assertEq(metro.balanceOf(address(xmetro)), 270 ether);
        assertEq(xmetro.unstakeRequestYThor(forfeiture, 0).amount, 20 ether);
        assertEq(xmetro.claimable(forfeiture), 50e6);
        assertEq(metro.totalSupply(), 400 ether);
        vm.warp(block.timestamp + 1800 seconds);
        vm.startPrank(forfeiture);
        assertEq(xmetro.withdrawYThor(0), 20 ether);
        assertEq(xmetro.claimRewards(), 50e6);
        vm.stopPrank();
        assertEq(metro.balanceOf(forfeiture), 150 ether);
        assertEq(xmetro.balanceOf(forfeiture), 50 ether);
        assertEq(xmetro.claimable(userA), 190e6);
        assertEq(xmetro.claimable(userB), 380e6);
        assertEq(usdc.balanceOf(address(xmetro)), 570e6);
    }

    function test_TreasuryOnlyDistributionRollbackAndCommissionOnlyRouting() public {
        _migrate(forfeiture, thor, 100 ether, false);
        _migrate(forfeiture, yThor, 100 ether, true);
        vault.setTargetBalance(100e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(5_000);
        usdc.mint(address(this), 40e6);
        usdc.approve(address(distributor), 40e6);
        vm.expectRevert(xMETRO.InvalidConfiguration.selector);
        distributor.distribute(40e6);
        assertEq(usdc.balanceOf(address(this)), 40e6);
        assertEq(usdc.allowance(address(this), address(distributor)), 40e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.balanceOf(address(xmetro)), 0);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
        usdc.mint(address(distributor), 40e6);
        vm.expectRevert(xMETRO.InvalidConfiguration.selector);
        distributor.distributeFromBalance(40e6);
        assertEq(usdc.balanceOf(address(distributor)), 40e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        distributor.setMaxCommissionSplitBps(10_000);
        distributor.distributeFromBalance(40e6);
        distributor.distribute(40e6);
        assertEq(usdc.balanceOf(address(vault)), 80e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.balanceOf(address(xmetro)), 0);
        assertEq(xmetro.totalRewardWeight(), 0);
    }

    function test_TreasuryMintFailureRollsBackMigrationAndExcludedPrincipal() public {
        _migrate(userA, thor, 100 ether, false);
        _migrate(forfeiture, thor, 10 ether, false);
        _migrate(forfeiture, yThor, 20 ether, true);
        metro.setMinter(address(xmetro), false);
        thor.mint(forfeiture, 5 ether);
        yThor.mint(forfeiture, 7 ether);
        vm.startPrank(forfeiture);
        thor.approve(address(escrow), 5 ether);
        yThor.approve(address(escrow), 7 ether);
        vm.expectRevert(bytes("MetroToken: not minter"));
        escrow.migrateThor(5 ether);
        vm.expectRevert(bytes("MetroToken: not minter"));
        escrow.migrateYThor(7 ether);
        vm.stopPrank();
        assertEq(xmetro.thorPositionCount(forfeiture), 1);
        assertEq(xmetro.yThorPositionCount(forfeiture), 1);
        assertEq(escrow.migratedThor(), 110 ether);
        assertEq(escrow.migratedYThor(), 20 ether);
        assertEq(thor.balanceOf(forfeiture), 5 ether);
        assertEq(yThor.balanceOf(forfeiture), 7 ether);
        assertEq(xmetro.lockedShares(forfeiture), 30 ether);
        assertEq(xmetro.totalShares(), 130 ether);
        assertEq(xmetro.totalRewardWeight(), 100 ether);
        assertEq(xmetro.rewardDebt(forfeiture), 0);
        _distributeTestRewards(100e6);
        assertEq(xmetro.claimable(userA), 100e6);
        assertEq(xmetro.claimable(forfeiture), 0);
    }
}
