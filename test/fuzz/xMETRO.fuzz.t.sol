// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

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
        (, uint64 migratedAt,,) = xmetro.thorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + elapsed);

        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited,) = xmetro.previewThorExit(userA, 0);
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
        if (stakeMode) xmetro.exitAndStakeThor(0);
        else xmetro.requestThorExit(0);
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
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + elapsed);

        (bool eligible, uint256 rate, uint256 payout, uint256 forfeited,) = xmetro.previewYThorExit(userA, 0);
        if (elapsed < 120 days) {
            assertFalse(eligible);
            assertEq(rate, 0);
            return;
        }

        uint256 sinceEligible = elapsed - 120 days;
        uint256 expectedRate =
            sinceEligible >= 4 * 365 days ? 10_000 : 2_000 + Math.mulDiv(sinceEligible, 8_000, 4 * 365 days);
        assertEq(rate, expectedRate);
        assertGe(rate, 2_000);
        assertLe(rate, 10_000);
        assertEq(payout, Math.mulDiv(principal, rate, 10_000));
        assertEq(payout + forfeited, principal);

        uint256 supplyBeforeExit = metro.totalSupply();
        vm.prank(userA);
        (uint256 actualPayout, uint256 actualForfeited) =
            xmetro.exitYThor(0, stakeMode ? XMetroCore.ExitMode.Stake : XMetroCore.ExitMode.Liquid);
        assertEq(actualPayout, payout);
        assertEq(actualForfeited, forfeited);
        assertEq(metro.totalSupply(), supplyBeforeExit);
        if (sinceEligible >= 4 * 365 days) {
            assertEq(actualPayout, principal);
            assertEq(actualForfeited, 0);
        }
        assertEq(metro.balanceOf(forfeiture), forfeited);
        assertEq(metro.balanceOf(address(xmetro)), payout);
        assertEq(xmetro.lockedShares(userA), 0);
        assertEq(_activeYThorPrincipal(userA), 0);
        assertEq(xmetro.totalRewardWeight(), stakeMode ? payout : 0);
        assertEq(xmetro.rewardWeightOf(userA), stakeMode ? payout : 0);
        assertEq(xmetro.unstakeRequestCountYThor(userA), !stakeMode && payout > 0 ? 1 : 0);
        if (stakeMode) {
            assertEq(xmetro.balanceOf(userA), payout);
        } else if (payout > 0) {
            vm.warp(xmetro.unstakeRequestYThor(userA, 0).unlockTime);
            vm.prank(userA);
            assertEq(xmetro.withdrawYThor(0), payout);
            assertEq(metro.balanceOf(userA), payout);
        }
        vm.prank(userA);
        vm.expectRevert(XMetroCore.InvalidConfiguration.selector);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
    }

    function testFuzz_YThorRateIsMonotonic(uint32 firstSeed, uint32 secondSeed) public {
        uint256 first = bound(uint256(firstSeed), 120 days, 120 days + 10 * 365 days);
        uint256 second = bound(uint256(secondSeed), 120 days, 120 days + 10 * 365 days);
        if (first > second) (first, second) = (second, first);
        xmetro.creditYThorFromMigration(userA, 100_000 ether);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);

        vm.warp(uint256(migratedAt) + first);
        (, uint256 firstRate,,,) = xmetro.previewYThorExit(userA, 0);
        vm.warp(uint256(migratedAt) + second);
        (, uint256 secondRate,,,) = xmetro.previewYThorExit(userA, 0);
        assertLe(firstRate, secondRate);
        assertLe(secondRate, 10_000);
    }

    function testFuzz_ExitPreservesPastPendingAndStopsFutureYThorRewards(
        uint128 principalSeed,
        uint128 rewardsSeed,
        uint32 eligibleElapsedSeed
    ) public {
        uint256 principal = bound(uint256(principalSeed), 1e6, 1e24);
        uint256 rewards = bound(uint256(rewardsSeed), 10, 1e24);
        uint256 elapsed = bound(uint256(eligibleElapsedSeed), 120 days, 120 days + 4 * 365 days);
        xmetro.creditYThorFromMigration(userA, principal);
        _stake(userB, principal);
        _deposit(rewards);
        uint256 pendingBefore = xmetro.claimable(userA);
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + elapsed);

        vm.prank(userA);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
        assertEq(xmetro.claimable(userA), pendingBefore);

        uint256 afterExit = xmetro.claimable(userA);
        _deposit(rewards);
        assertEq(xmetro.claimable(userA), afterExit);
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
        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + 120 days);

        vm.prank(userA);
        xmetro.exitYThor(0, XMetroCore.ExitMode.Liquid);
        assertEq(xmetro.balanceOf(userA), freeAmount);
        assertEq(xmetro.lockedShares(userA), thorAmount);
        assertEq(xmetro.rewardWeightOf(userA), freeAmount + thorAmount);
        (uint128 storedThor,,, bool thorExited) = xmetro.thorPositions(userA, 0);
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
        uint256 elapsed = bound(uint256(elapsedSeed), 120 days, 120 days + 4 * 365 days);
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

        (, uint64 migratedAt,,) = xmetro.yThorPositions(userA, 0);
        vm.warp(uint256(migratedAt) + elapsed);
        (,, uint256 payout,,) = xmetro.previewYThorExit(userA, 0);
        vm.prank(userA);
        xmetro.exitYThor(0, stakeExit ? XMetroCore.ExitMode.Stake : XMetroCore.ExitMode.Liquid);

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

    function _activeYThorPrincipal(address user) private view returns (uint256 total) {
        for (uint256 id; id < xmetro.yThorPositionCount(user); ++id) {
            (uint128 principal,,, bool exited) = xmetro.yThorPositions(user, id);
            if (!exited) total += principal;
        }
    }

    function testFuzz_RewardSequenceMatchesAccrualModel(uint256 seed, bool includeTreasury) public {
        address[2] memory accounts = [includeTreasury ? forfeiture : userA, userB];
        uint256[2] memory free = [uint256(2 ether), uint256(3 ether)];
        uint256[2] memory yPrincipal;
        uint256[2] memory thorPrincipal;
        uint256[2] memory earnedScaled;
        _stake(accounts[0], free[0]);
        _stake(userB, free[1]);
        uint256 weightBps = 20_000;
        uint256 deposited;
        uint256 paid;
        for (uint256 step; step < 32; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 actor = (seed >> 8) % 2;
            uint256 other = 1 - actor;
            uint256 amount = (seed >> 16) % 1e18 + 1;
            uint256 action = seed % 7;
            if (action == 0) {
                uint256 reward = (seed >> 32) % 1e6 + 1;
                uint256 activeY = (includeTreasury ? 0 : yPrincipal[0]) + yPrincipal[1];
                uint256 yWeight = activeY * weightBps / 10_000;
                uint256 weight =
                    free[0] + free[1] + (includeTreasury ? 0 : thorPrincipal[0]) + thorPrincipal[1] + yWeight;
                if (weight != 0) {
                    uint256 delta = reward * 1e24 / weight;
                    uint256 yDelta = activeY == 0 ? 0 : delta * yWeight / activeY;
                    for (uint256 j; j < 2; ++j) {
                        bool excluded = includeTreasury && j == 0;
                        earnedScaled[j] += (free[j] + (excluded ? 0 : thorPrincipal[j])) * delta
                            + (excluded ? 0 : yPrincipal[j]) * yDelta;
                    }
                    _deposit(reward);
                    deposited += reward;
                }
            } else if (action == 1) {
                xmetro.creditYThorFromMigration(accounts[actor], amount);
                yPrincipal[actor] += amount;
            } else if (action == 2) {
                _stake(accounts[actor], amount);
                free[actor] += amount;
            } else if (action == 3) {
                amount = free[actor] == 0 ? 0 : amount % (free[actor] + 1);
                vm.prank(accounts[actor]);
                xmetro.transfer(accounts[other], amount);
                free[actor] -= amount;
                free[other] += amount;
            } else if (action == 4) {
                uint256 expected = earnedScaled[actor] / 1e24;
                vm.prank(accounts[actor]);
                assertEq(xmetro.claimRewards(), expected);
                earnedScaled[actor] -= expected * 1e24;
                paid += expected;
            } else if (action == 6) {
                xmetro.creditThorFromMigration(accounts[actor], amount);
                thorPrincipal[actor] += amount;
            } else {
                weightBps = (seed >> 24) % 50_001;
                xmetro.setYThorRewardWeightBps(weightBps);
            }
            assertEq(xmetro.claimable(accounts[0]), earnedScaled[0] / 1e24);
            assertEq(xmetro.claimable(userB), earnedScaled[1] / 1e24);
            assertLe(xmetro.claimable(accounts[0]) + xmetro.claimable(userB), usdc.balanceOf(address(xmetro)));
            assertEq(paid + usdc.balanceOf(address(xmetro)), deposited);
        }
    }

    function testFuzz_TreasuryMixedPrincipalExitsMatchRewardModel(
        uint96 treasurySeed,
        uint96 ordinarySeed,
        uint16 multiplierSeed,
        bool yThorExit,
        bool stakeMode
    ) public {
        uint256 principal = bound(uint256(treasurySeed), 1, 1e24);
        uint256 ordinary = bound(uint256(ordinarySeed), 1, 1e24);
        uint256 multiplier = bound(uint256(multiplierSeed), 0, 50_000);
        _stake(forfeiture, ordinary);
        xmetro.creditThorFromMigration(forfeiture, principal);
        xmetro.creditYThorFromMigration(forfeiture, principal);
        xmetro.creditYThorFromMigration(userA, ordinary);
        xmetro.setYThorRewardWeightBps(multiplier);
        uint256 yWeight = ordinary * multiplier / 10_000;
        uint256 expectedWeight = ordinary + yWeight;
        assertEq(xmetro.totalRewardWeight(), expectedWeight);
        assertEq(xmetro.rewardWeightOf(forfeiture), ordinary);
        uint256 reward = 1_000e6;
        uint256 delta = reward * 1e24 / expectedWeight;
        uint256 treasuryEarned = ordinary * delta;
        uint256 userEarned = ordinary * (delta * yWeight / ordinary);
        _deposit(reward);
        assertEq(xmetro.claimable(forfeiture), treasuryEarned / 1e24);
        assertEq(xmetro.claimable(userA), userEarned / 1e24);
        vm.warp(vm.getBlockTimestamp() + 120 days + 4 * 365 days);
        uint256 supply = metro.totalSupply();
        vm.prank(forfeiture);
        uint256 payout;
        uint256 forfeited;
        if (yThorExit) {
            (payout, forfeited) =
                xmetro.exitYThor(0, stakeMode ? XMetroCore.ExitMode.Stake : XMetroCore.ExitMode.Liquid);
        } else if (stakeMode) {
            (payout, forfeited) = xmetro.exitAndStakeThor(0);
        } else {
            (payout, forfeited) = xmetro.requestThorExit(0);
        }
        assertEq(payout, principal);
        assertEq(forfeited, 0);
        assertEq(metro.totalSupply(), supply);
        assertEq(xmetro.lockedShares(forfeiture), principal);
        uint256 ordinaryAfter = ordinary + (stakeMode ? principal : 0);
        assertEq(xmetro.totalRewardWeight(), ordinaryAfter + yWeight);
        assertEq(xmetro.claimable(forfeiture), treasuryEarned / 1e24);
        delta = reward * 1e24 / (ordinaryAfter + yWeight);
        treasuryEarned += ordinaryAfter * delta;
        userEarned += ordinary * (delta * yWeight / ordinary);
        _deposit(reward);
        vm.prank(forfeiture);
        uint256 paid = xmetro.claimRewards();
        assertEq(paid, treasuryEarned / 1e24);
        vm.prank(userA);
        uint256 otherPaid = xmetro.claimRewards();
        assertEq(otherPaid, userEarned / 1e24);
        assertLe(paid + otherPaid, 2 * reward);
        assertEq(paid + otherPaid + usdc.balanceOf(address(xmetro)), 2 * reward);
        assertEq(metro.balanceOf(address(xmetro)), xmetro.totalShares() + (stakeMode ? 0 : principal));
    }
}
