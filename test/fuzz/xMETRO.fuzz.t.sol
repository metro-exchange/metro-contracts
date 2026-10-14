// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {xMETRO as XMetroCore} from "../../src/xMETRO.sol";
import {MetroToken} from "../../src/metro.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockXMetroDeFiAdapter} from "../mocks/MockXMetroDeFiAdapter.sol";

contract xMETROFuzzTest is Test {
    ERC20Mintable internal usdc;
    MetroToken internal metro;
    XMetroCore internal xmetro;
    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");
    address internal forfeiture = makeAddr("forfeiture");

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
        xmetro = new XMetroCore(address(this), address(metro), address(usdc), forfeiture, 20_000);
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

    function _deposit(uint256 amount) internal {
        usdc.mint(address(this), amount);
        xmetro.depositRewards(amount);
    }

    function testFuzz_YThorPrincipalCreatesConfiguredRewardWeight(uint128 principalSeed) public {
        uint256 principal = bound(uint256(principalSeed), 1, metro.MAX_SUPPLY());
        uint256 supplyBefore = metro.totalSupply();
        xmetro.creditYThorFromMigration(userA, principal);

        assertEq(xmetro.lockedShares(userA), principal);
        assertEq(_activeYThorPrincipal(userA), principal);
        assertEq(xmetro.totalSharesOf(userA), principal);
        assertEq(xmetro.rewardWeightOf(userA), principal * 2);
        assertEq(xmetro.totalRewardWeight(), principal * 2);
        assertEq(metro.totalSupply() - supplyBefore, principal);
        assertEq(metro.balanceOf(address(xmetro)), principal);
    }

    function testFuzz_ThorExitCurveAndFundsConservation(uint128 principalSeed, uint32 elapsedSeed, bool stakeMode)
        public
    {
        uint256 principal = bound(uint256(principalSeed), 1, metro.MAX_SUPPLY());
        uint256 elapsed = bound(uint256(elapsedSeed), 0, 200 days);
        xmetro.creditThorFromMigration(userA, principal);
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA);
        vm.warp(uint256(migratedAt) + elapsed);

        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited,) = xmetro.previewThorExit(userA);
        if (elapsed < 30 days) {
            assertFalse(eligible);
            assertEq(rate, 0);
            return;
        }

        uint256 expectedRate = elapsed >= 90 days ? 10_000 : 5_000 + Math.mulDiv(elapsed - 30 days, 5_000, 60 days);
        assertTrue(eligible);
        assertEq(rate, expectedRate);
        assertEq(payout, Math.mulDiv(principal, expectedRate, 10_000));
        assertEq(payout + forfeited, principal);

        vm.prank(userA);
        if (stakeMode) xmetro.exitAndStakeThor();
        else xmetro.requestThorExit();
        assertEq(metro.balanceOf(forfeiture), forfeited);
        assertEq(metro.balanceOf(address(xmetro)), payout);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(xmetro.rewardWeightOf(userA), stakeMode ? payout : 0);
        assertEq(xmetro.unstakeRequestCountThor(userA), !stakeMode && payout > 0 ? 1 : 0);
    }

    function testFuzz_YThorExitCurveAndFundsConservation(uint128 principalSeed, uint32 elapsedSeed, bool stakeMode)
        public
    {
        uint256 principal = bound(uint256(principalSeed), 1, metro.MAX_SUPPLY());
        uint256 maxElapsed = 120 days + 10 * 365 days;
        uint256 elapsed = bound(uint256(elapsedSeed), 0, maxElapsed);
        xmetro.creditYThorFromMigration(userA, principal);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA);
        vm.warp(uint256(migratedAt) + elapsed);

        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited,) = xmetro.previewYThorExit(userA);
        if (elapsed < 120 days) {
            assertFalse(eligible);
            assertEq(rate, 0);
            return;
        }

        uint256 sinceEligible = elapsed - 120 days;
        uint256 expectedRate =
            sinceEligible >= 5 * 365 days ? 5_000 : 1_000 + Math.mulDiv(sinceEligible, 4_000, 5 * 365 days);
        assertEq(rate, expectedRate);
        assertGe(rate, 1_000);
        assertLe(rate, 5_000);
        assertEq(payout, Math.mulDiv(principal, rate, 10_000));
        assertEq(payout + forfeited, principal);

        vm.prank(userA);
        xmetro.exitYThor(stakeMode ? XMetroCore.ExitMode.Stake : XMetroCore.ExitMode.Liquid);
        assertEq(metro.balanceOf(forfeiture), forfeited);
        assertEq(metro.balanceOf(address(xmetro)), payout);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(xmetro.totalRewardWeight(), stakeMode ? payout : 0);
        assertEq(xmetro.rewardWeightOf(userA), stakeMode ? payout : 0);
        assertEq(xmetro.unstakeRequestCountYThor(userA), !stakeMode && payout > 0 ? 1 : 0);
    }

    function testFuzz_YThorRateIsMonotonic(uint32 firstSeed, uint32 secondSeed) public {
        uint256 first = bound(uint256(firstSeed), 120 days, 120 days + 10 * 365 days);
        uint256 second = bound(uint256(secondSeed), 120 days, 120 days + 10 * 365 days);
        if (first > second) (first, second) = (second, first);
        xmetro.creditYThorFromMigration(userA, 100_000 ether);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA);

        vm.warp(uint256(migratedAt) + first);
        (, uint256 firstRate,,,) = xmetro.previewYThorExit(userA);
        vm.warp(uint256(migratedAt) + second);
        (, uint256 secondRate,,,) = xmetro.previewYThorExit(userA);
        assertLe(firstRate, secondRate);
        assertLe(secondRate, 5_000);
    }

    function testFuzz_ExitPreservesPastPendingAndStopsFutureYThorRewards(
        uint128 principalSeed,
        uint128 rewardsSeed,
        uint32 eligibleElapsedSeed
    ) public {
        uint256 principal = bound(uint256(principalSeed), 1e6, 1e24);
        uint256 rewards = bound(uint256(rewardsSeed), 10, 1e24);
        uint256 elapsed = bound(uint256(eligibleElapsedSeed), 120 days, 120 days + 5 * 365 days);
        xmetro.creditYThorFromMigration(userA, principal);
        _stake(userB, principal);
        _deposit(rewards);
        uint256 pendingBefore = xmetro.claimable(userA);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA);
        vm.warp(uint256(migratedAt) + elapsed);

        vm.prank(userA);
        xmetro.exitYThor(XMetroCore.ExitMode.Liquid);
        assertApproxEqAbs(xmetro.claimable(userA), pendingBefore, 1);

        uint256 afterExit = xmetro.claimable(userA);
        _deposit(rewards);
        assertApproxEqAbs(xmetro.claimable(userA), afterExit, 1);
        assertGt(xmetro.claimable(userB), 0);
    }

    function testFuzz_MixedPositionYThorExitOnlyRemovesItsOwnPrincipal(
        uint96 freeSeed,
        uint96 thorSeed,
        uint96 yThorSeed
    ) public {
        uint256 freeAmount = bound(uint256(freeSeed), 1, 1e24);
        uint256 thorAmount = bound(uint256(thorSeed), 1, 1e24);
        uint256 yThorAmount = bound(uint256(yThorSeed), 1, 1e24);
        _stake(userA, freeAmount);
        xmetro.creditThorFromMigration(userA, thorAmount);
        xmetro.creditYThorFromMigration(userA, yThorAmount);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA);
        vm.warp(uint256(migratedAt) + 120 days);

        vm.prank(userA);
        xmetro.exitYThor(XMetroCore.ExitMode.Liquid);
        assertEq(xmetro.balanceOf(userA), freeAmount);
        assertEq(xmetro.lockedShares(userA), thorAmount);
        assertEq(xmetro.rewardWeightOf(userA), freeAmount + thorAmount);
        (uint128 storedThor,,, bool thorExited) = xmetro.thorPositions(userA);
        assertEq(storedThor, thorAmount);
        assertFalse(thorExited);
    }

    function testFuzz_YThorRewardAutocompoundThenExitSequence(
        uint96 principalSeed,
        uint64 rewardUnitsSeed,
        uint32 elapsedSeed,
        bool stakeExit
    ) public {
        uint256 principal = bound(uint256(principalSeed), 1 ether, 1e24);
        uint256 rewardUnits = bound(uint256(rewardUnitsSeed), 1, 1e12);
        uint256 rewards = rewardUnits * 3;
        uint256 elapsed = bound(uint256(elapsedSeed), 120 days, 120 days + 5 * 365 days);
        xmetro.creditYThorFromMigration(userA, principal);
        _stake(userB, principal);
        _deposit(rewards);

        uint256 pending = xmetro.claimable(userA);
        assertApproxEqAbs(pending, rewardUnits * 2, 2);
        MockXMetroDeFiAdapter adapter =
            new MockXMetroDeFiAdapter(address(xmetro), address(usdc), address(metro), 1e12, 1);
        xmetro.pause();
        xmetro.setDeFiAdapter(address(adapter));
        xmetro.unpause();
        uint256 compounded = pending * 1e12;
        metro.mint(address(adapter), compounded);
        vm.prank(userA);
        xmetro.autocompound(compounded, block.timestamp + 1 days, "");
        assertEq(xmetro.balanceOf(userA), compounded);

        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA);
        vm.warp(uint256(migratedAt) + elapsed);
        (,, uint256 payout,,) = xmetro.previewYThorExit(userA);
        vm.prank(userA);
        xmetro.exitYThor(stakeExit ? XMetroCore.ExitMode.Stake : XMetroCore.ExitMode.Liquid);

        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(xmetro.balanceOf(userA), compounded + (stakeExit ? payout : 0));
    }

    function testFuzz_WeightChangesOnlyFutureRewardsForAllActiveYThor(uint16 firstSeed, uint16 secondSeed) public {
        uint256 firstWeight = bound(uint256(firstSeed), 0, 50_000);
        uint256 secondWeight = bound(uint256(secondSeed), 0, 50_000);
        uint256 principal = 1 ether;

        _stake(userB, principal);
        xmetro.creditYThorFromMigration(userA, principal);

        if (firstWeight != 20_000) {
            xmetro.setYThorRewardWeightBps(firstWeight);
        }
        uint256 firstYThorReward = Math.mulDiv(principal, firstWeight, 10_000);
        _deposit(principal + firstYThorReward);
        uint256 firstPending = xmetro.claimable(userA);
        assertEq(firstPending, firstYThorReward);
        assertEq(xmetro.claimable(userB), principal);

        if (secondWeight != firstWeight) {
            xmetro.setYThorRewardWeightBps(secondWeight);
            assertEq(xmetro.claimable(userA), firstPending);
            assertEq(xmetro.claimable(userB), principal);
        }

        uint256 secondYThorReward = Math.mulDiv(principal, secondWeight, 10_000);
        _deposit(principal + secondYThorReward);
        assertEq(xmetro.claimable(userA), firstYThorReward + secondYThorReward);
        assertEq(xmetro.claimable(userB), principal * 2);
    }

    function testFuzz_RoundedYThorWeightNeverCreatesUnbackedClaimable(
        uint16 weightSeed,
        uint16 principalSeed,
        uint96 rewardsSeed
    ) public {
        uint256 weight = bound(uint256(weightSeed), 0, 50_000);
        uint256 principal = bound(uint256(principalSeed), 1, 10_000);
        uint256 rewards = bound(uint256(rewardsSeed), 1, 1e24);

        _stake(userB, 1);
        xmetro.creditYThorFromMigration(userA, principal);
        xmetro.setYThorRewardWeightBps(weight);
        _deposit(rewards);

        assertLe(xmetro.claimable(userA) + xmetro.claimable(userB), rewards);
    }

    function testFuzz_EmergencyDistributionDeduplicatesAcrossTwoBatches(
        uint96 firstRewardSeed,
        uint96 secondRewardSeed,
        uint8 lengthSeed,
        uint256 listSeed
    ) public {
        address third = makeAddr("emergency-third");
        address[3] memory accounts = [userA, userB, third];
        _stake(userA, 1 ether);
        _stake(userB, 2 ether);
        _stake(third, 3 ether);
        uint256 firstUnit = bound(uint256(firstRewardSeed), 1, 1e6);
        uint256 secondUnit = bound(uint256(secondRewardSeed), 1, 1e6);
        _deposit(firstUnit * 6);

        uint256 count = bound(uint256(lengthSeed), 1, 30);
        address[] memory candidates = new address[](count);
        bool[3] memory included;
        candidates[0] = userA;
        included[0] = true;
        for (uint256 i = 1; i < count; ++i) {
            uint256 choice = uint256(keccak256(abi.encode(listSeed, i))) % 4;
            if (choice < 3) {
                candidates[i] = accounts[choice];
                included[choice] = true;
            }
        }

        xmetro.pause();
        uint256 firstExpected;
        for (uint256 i; i < 3; ++i) {
            if (included[i]) firstExpected += firstUnit * (i + 1);
        }
        assertEq(xmetro.emergencyDistribute(candidates), firstExpected);
        vm.expectRevert(XMetroCore.NoRewards.selector);
        xmetro.emergencyDistribute(candidates);
        xmetro.unpause();
        _deposit(secondUnit * 6);
        xmetro.pause();

        uint256 secondExpected;
        for (uint256 i; i < 3; ++i) {
            if (included[i]) secondExpected += secondUnit * (i + 1);
        }
        assertEq(xmetro.emergencyDistribute(candidates), secondExpected);
        for (uint256 i; i < 3; ++i) {
            uint256 paid = included[i] ? (firstUnit + secondUnit) * (i + 1) : 0;
            uint256 pending = included[i] ? 0 : (firstUnit + secondUnit) * (i + 1);
            assertEq(usdc.balanceOf(accounts[i]), paid);
            assertEq(xmetro.claimable(accounts[i]), pending);
        }
        assertEq(usdc.balanceOf(address(xmetro)), firstUnit * 6 + secondUnit * 6 - firstExpected - secondExpected);
    }

    function _activeYThorPrincipal(address user) private view returns (uint256) {
        (uint128 principal,,, bool exited) = xmetro.yThorPositions(user);
        return exited ? 0 : uint256(principal);
    }
}
