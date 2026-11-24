// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";

import {MetroDistributorBase} from "../../src/MetroDistributorBase.sol";
import {MetroDistributorV2} from "../../src/MetroDistributorV2.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {MetroDistributorFixture} from "../mocks/MetroDistributorFixture.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {MetroDistributorV2Harness} from "../mocks/MetroDistributorV2Harness.sol";

contract MetroDistributorV2Test is MetroDistributorFixture {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    xMETRO internal xmetro;
    MetroDistributorV2 internal distributor;

    address internal operator = makeAddr("operator");
    address internal outsider = makeAddr("outsider");
    address internal treasury = makeAddr("treasury");
    address internal swapSink = makeAddr("swapSink");

    function setUp() public {
        _deployTokens();
        xmetro = _deployCoreWithStaker(100 ether);
        distributor = new MetroDistributorV2(address(xmetro), treasury, address(this));
        _bind(distributor);
    }

    function _bind(MetroDistributorV2 target) internal {
        xmetro.setRewardDistributor(address(target));
        target.setOperator(operator, true);
    }

    function test_DefaultsAndMetroBinding() public {
        assertEq(address(distributor.metro()), address(metro));
        vm.expectEmit(false, false, false, true);
        emit MetroDistributorV2.BucketBpsUpdated(5_500, 2_500, 2_000);
        new MetroDistributorV2(address(xmetro), treasury, address(this));
        assertEq(distributor.stakersBps(), 5_500);
        assertEq(distributor.treasuryBps(), 2_500);
        assertEq(distributor.buybackBps(), 2_000);
        assertEq(distributor.treasury(), treasury);
    }

    function test_SetBucketBpsRequiresExactTotalAndOwner() public {
        vm.expectRevert(MetroDistributorV2.InvalidBucketBps.selector);
        distributor.setBucketBps(5_500, 2_500, 1_999);
        vm.expectRevert(MetroDistributorV2.InvalidBucketBps.selector);
        distributor.setBucketBps(5_500, 2_500, 2_001);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        distributor.setBucketBps(7_500, 2_500, 0);

        vm.expectEmit(false, false, false, true, address(distributor));
        emit MetroDistributorV2.BucketBpsUpdated(7_500, 2_500, 0);
        distributor.setBucketBps(7_500, 2_500, 0);
        assertEq(distributor.stakersBps(), 7_500);
        assertEq(distributor.treasuryBps(), 2_500);
        assertEq(distributor.buybackBps(), 0);
    }

    function test_ProductionBuybackRevertsUntilImplemented() public {
        usdc.mint(address(distributor), 100e6);
        vm.prank(operator);
        vm.expectRevert(MetroDistributorV2.BuybackNotImplemented.selector);
        distributor.distribute(0);
    }

    function test_ProductionDistributeWorksWithBuybackDisabled() public {
        distributor.setBucketBps(7_500, 2_500, 0);
        usdc.mint(address(distributor), 100e6);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.Distributed(operator, 100e6, 0, 75e6, 25e6, 0, uint64(block.timestamp));
        vm.prank(operator);
        distributor.distribute(0);
        assertEq(usdc.balanceOf(address(xmetro)), 75e6);
        assertEq(usdc.balanceOf(treasury), 25e6);
    }

    function test_HarnessBuysBackAndBurnsInline() public {
        MetroDistributorV2Harness harness =
            new MetroDistributorV2Harness(address(xmetro), treasury, address(this), swapSink);
        _bind(harness);
        MockCommissionVault vault = new MockCommissionVault(address(usdc), 100e6, address(harness));
        harness.setCommissionVault(address(vault));
        harness.setMaxCommissionSplitBps(1_000);
        harness.setMetroOut(42 ether);
        metro.mint(address(harness), 42 ether);
        usdc.mint(address(harness), 1_000e6);

        vm.expectEmit(true, false, false, true, address(harness));
        emit MetroDistributorBase.TreasuryPaid(treasury, 225e6);
        vm.expectEmit(false, false, false, true, address(harness));
        emit MetroDistributorV2.BuybackExecuted(180e6, 42 ether);
        vm.expectEmit(false, false, false, true, address(harness));
        emit MetroDistributorV2.MetroBurned(42 ether);
        vm.expectEmit(true, false, false, true, address(harness));
        emit MetroDistributorBase.RewardsDistributed(operator, 495e6, uint64(block.timestamp));
        vm.expectEmit(true, false, false, true, address(harness));
        emit MetroDistributorBase.Distributed(operator, 1_000e6, 100e6, 495e6, 225e6, 180e6, uint64(block.timestamp));
        vm.prank(operator);
        harness.distribute(0);

        assertEq(metro.balanceOf(DEAD), 42 ether);
        assertEq(metro.balanceOf(address(harness)), 0);
        assertEq(usdc.balanceOf(swapSink), 180e6);
        assertEq(usdc.balanceOf(address(xmetro)), 495e6);
        assertEq(usdc.balanceOf(address(harness)), 0);
    }

    function test_HarnessZeroMetroOutSkipsBurnLeg() public {
        MetroDistributorV2Harness harness =
            new MetroDistributorV2Harness(address(xmetro), treasury, address(this), swapSink);
        _bind(harness);
        usdc.mint(address(harness), 100e6);

        vm.recordLogs();
        vm.prank(operator);
        harness.distribute(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool buybackLogged;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != MetroDistributorV2.MetroBurned.selector);
            if (logs[i].topics[0] == MetroDistributorV2.BuybackExecuted.selector) buybackLogged = true;
        }
        assertTrue(buybackLogged);
        assertEq(usdc.balanceOf(swapSink), 20e6);
        assertEq(metro.balanceOf(DEAD), 0);
    }
}
