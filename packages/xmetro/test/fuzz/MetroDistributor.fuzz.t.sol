// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetroDistributorV1} from "../../src/MetroDistributorV1.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {MetroToken} from "../../src/metro.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {MockRateLimitedForwarder} from "../mocks/MockRateLimitedForwarder.sol";
import {MetroDistributorV2Harness} from "../mocks/MetroDistributorV2Harness.sol";

contract MetroDistributorFuzzTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ERC20Mintable internal usdc;
    MetroToken internal metro;
    xMETRO internal xmetro;
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal polVault = makeAddr("polVault");
    address internal swapSink = makeAddr("swapSink");

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        xmetro = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);

        address staker = makeAddr("staker");
        metro.mint(staker, 100 ether);
        vm.startPrank(staker);
        metro.approve(address(xmetro), 100 ether);
        xmetro.stake(100 ether);
        vm.stopPrank();
    }

    function _routed(uint256 balance, uint256 maxAmount) internal pure returns (uint256) {
        return maxAmount == 0 ? balance : Math.min(balance, maxAmount);
    }

    function testFuzz_V1LegsSumToRoutedAmountAndMatchShares(
        uint128 forwardedSeed,
        uint128 directSeed,
        uint128 maxSeed,
        uint16 bpsSeed,
        uint128 shortfallSeed
    ) public {
        uint256 forwarded = bound(uint256(forwardedSeed), 0, 1e30);
        uint256 direct = bound(uint256(directSeed), forwarded == 0 ? 1 : 0, 1e30);
        uint256 balance = forwarded + direct;
        uint256 maxAmount = bound(uint256(maxSeed), 0, balance * 2);
        uint16 bps = uint16(bound(uint256(bpsSeed), 0, 10_000));
        uint256 shortfall = bound(uint256(shortfallSeed), 0, 1e30);

        MetroDistributorV1 distributor = new MetroDistributorV1(address(xmetro), treasury, polVault, address(this));
        xmetro.setRewardDistributor(address(distributor));
        distributor.setOperator(operator, true);
        MockCommissionVault vault = new MockCommissionVault(address(usdc), shortfall, address(distributor));
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(bps);
        MockRateLimitedForwarder forwarder = new MockRateLimitedForwarder(address(usdc), address(distributor));
        distributor.setForwarder(address(forwarder));
        usdc.mint(address(forwarder), forwarded);
        usdc.mint(address(distributor), direct);

        vm.prank(operator);
        distributor.distribute(maxAmount);

        uint256 routed = _routed(balance, maxAmount);
        uint256 commission = usdc.balanceOf(address(vault));
        uint256 remainder = routed - commission;
        uint256 staker = usdc.balanceOf(address(xmetro));
        assertEq(commission, Math.min(Math.mulDiv(routed, bps, 10_000), shortfall));
        assertEq(commission + usdc.balanceOf(treasury) + usdc.balanceOf(polVault) + staker, routed);
        assertEq(usdc.balanceOf(address(distributor)), balance - routed);
        assertEq(usdc.balanceOf(treasury), Math.mulDiv(remainder, 2_500, 10_000));
        assertEq(usdc.balanceOf(polVault), Math.mulDiv(remainder, 2_500, 10_000));
        assertApproxEqAbs(staker, Math.mulDiv(remainder, 5_000, 10_000), 2);
        assertGe(staker, Math.mulDiv(remainder, 5_000, 10_000));
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
    }

    function testFuzz_V2BucketTripleSplitsAndBurnsEverythingBought(
        uint128 grossSeed,
        uint128 maxSeed,
        uint16 treasurySeed,
        uint16 buybackSeed,
        uint96 metroOutSeed
    ) public {
        uint256 gross = bound(uint256(grossSeed), 1, 1e30);
        uint256 maxAmount = bound(uint256(maxSeed), 0, gross * 2);
        uint16 treasuryBps = uint16(bound(uint256(treasurySeed), 0, 10_000));
        uint16 buybackBps = uint16(bound(uint256(buybackSeed), 0, 10_000 - treasuryBps));
        uint16 stakersBps = 10_000 - treasuryBps - buybackBps;
        uint256 metroOut = bound(uint256(metroOutSeed), 1, 1e24);

        MetroDistributorV2Harness distributor =
            new MetroDistributorV2Harness(address(xmetro), treasury, address(this), swapSink);
        xmetro.setRewardDistributor(address(distributor));
        distributor.setOperator(operator, true);
        distributor.setBucketBps(stakersBps, treasuryBps, buybackBps);
        distributor.setMetroOut(metroOut);
        metro.mint(address(distributor), metroOut);
        usdc.mint(address(distributor), gross);

        vm.prank(operator);
        distributor.distribute(maxAmount);

        uint256 routed = _routed(gross, maxAmount);
        uint256 buyback = Math.mulDiv(routed, buybackBps, 10_000);
        uint256 staker = usdc.balanceOf(address(xmetro));
        assertEq(usdc.balanceOf(treasury), Math.mulDiv(routed, treasuryBps, 10_000));
        assertEq(usdc.balanceOf(swapSink), buyback);
        assertEq(usdc.balanceOf(treasury) + buyback + staker, routed);
        assertApproxEqAbs(staker, Math.mulDiv(routed, stakersBps, 10_000), 2);
        assertEq(usdc.balanceOf(address(distributor)), gross - routed);
        assertEq(metro.balanceOf(DEAD), buyback == 0 ? 0 : metroOut);
    }
}
