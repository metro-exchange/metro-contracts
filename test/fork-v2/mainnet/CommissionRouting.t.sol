// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RewardDistributor} from "../../../src/RewardDistributor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommissionVault} from "./vendor/CommissionVault.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

contract CommissionRoutingMainnetTest is MainnetForkBase {
    address private staker;

    event RewardsDistributed(address indexed caller, uint256 amount, uint64 timestamp);
    event DistributionRouted(
        address indexed caller,
        address indexed commissionVault,
        uint256 grossAmount,
        uint256 commissionAmount,
        uint256 netReward,
        uint64 timestamp
    );

    function setUp() public {
        _fork();
        _deploySystem();
        core.unpause();
        staker = makeAddr("commission-staker");
    }

    function _newVault(address token, address boundDistributor, bool migrationTarget)
        internal
        returns (CommissionVault fresh)
    {
        fresh = new CommissionVault(
            token,
            boundDistributor,
            address(this),
            address(this),
            1_000_000e6,
            1_000_000e6,
            migrationTarget,
            1 days,
            1 days
        );
    }

    function _makeShortfall(uint256 amount) internal {
        if (amount == 0) return;
        string[] memory codes = new string[](1);
        codes[0] = "fork-commission-integration";
        address[] memory payouts = new address[](1);
        payouts[0] = makeAddr("commission-payee");
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vault.proposeSettlement(codes, payouts, amounts);
        vm.warp(vault.pendingActivationTime());
        vault.activateSettlement();
        assertEq(vault.requiredReserve(), amount);
        assertEq(vault.requiredTopUp(), amount);
    }

    function _routeEvent(Vm.Log[] memory logs, uint256 gross, uint256 commission, uint256 net) internal view {
        bool routed;
        bool distributed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(distributor) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == DistributionRouted.selector) {
                routed = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(this));
                assertEq(
                    address(uint160(uint256(logs[i].topics[2]))),
                    commission == 0 && distributor.maxCommissionSplitBps() == 0 ? address(0) : address(vault)
                );
                (uint256 actualGross, uint256 actualCommission, uint256 actualNet, uint64 timestamp) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint64));
                assertEq(actualGross, gross);
                assertEq(actualCommission, commission);
                assertEq(actualNet, net);
                assertEq(timestamp, block.timestamp);
            }
            if (logs[i].topics[0] == RewardsDistributed.selector) {
                distributed = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(this));
                (uint256 amount, uint64 timestamp) = abi.decode(logs[i].data, (uint256, uint64));
                assertEq(amount, net);
                assertEq(timestamp, block.timestamp);
            }
        }
        assertTrue(routed);
        assertTrue(distributed);
    }

    /// E-16.01: Tests new source vault binding and initial state.
    function test_E16_NewSourceVaultBindingAndInitialState() public view {
        assertGt(address(vault).code.length, 0);
        assertEq(address(vault.usdc()), USDC);
        assertEq(vault.distributor(), address(distributor));
        assertEq(vault.owner(), address(this));
        assertEq(vault.operator(), address(this));
        assertEq(vault.guardian(), address(this));
        assertEq(vault.settlementTimelock(), 1 days);
        assertEq(vault.payoutTimelock(), 1 days);
        assertTrue(vault.migrationFinalized());
        assertFalse(vault.paused());
        assertEq(vault.requiredTopUp(), 0);
        assertEq(distributor.commissionVault(), address(vault));
    }

    /// E-16.02: Tests config authority and vault validation.
    function test_E16_ConfigAuthorityAndVaultValidation() public {
        vm.prank(staker);
        vm.expectRevert();
        distributor.setMaxCommissionSplitBps(2_000);
        vm.prank(staker);
        vm.expectRevert();
        distributor.setCommissionVault(address(0));
        vm.expectRevert(RewardDistributor.InvalidCommissionSplitBps.selector);
        distributor.setMaxCommissionSplitBps(10_001);
        vm.expectRevert(RewardDistributor.CommissionVaultNotContract.selector);
        distributor.setCommissionVault(staker);
        CommissionVault wrongToken = _newVault(THOR, address(distributor), false);
        vm.expectRevert(RewardDistributor.CommissionTokenMismatch.selector);
        distributor.setCommissionVault(address(wrongToken));
        CommissionVault wrongDistributor = _newVault(USDC, staker, false);
        vm.expectRevert(RewardDistributor.CommissionDistributorMismatch.selector);
        distributor.setCommissionVault(address(wrongDistributor));
        CommissionVault pending = _newVault(USDC, address(distributor), true);
        vm.expectRevert(RewardDistributor.CommissionVaultMigrationPending.selector);
        distributor.setCommissionVault(address(pending));
        CommissionVault paused = _newVault(USDC, address(distributor), false);
        paused.pause();
        vm.expectRevert(RewardDistributor.CommissionVaultPaused.selector);
        distributor.setCommissionVault(address(paused));
        vault.pause();
        vm.expectRevert(RewardDistributor.CommissionVaultPaused.selector);
        distributor.setMaxCommissionSplitBps(2_000);
        vault.unpause();
        distributor.setMaxCommissionSplitBps(2_000);
        assertEq(distributor.maxCommissionSplitBps(), 2_000);
    }

    function _assertCapCase(uint256 shortfall, uint256 expectedCommission) internal {
        _mintAndStake(staker, 100 ether);
        _makeShortfall(shortfall);
        distributor.setMaxCommissionSplitBps(2_000);
        vm.recordLogs();
        _distribute(100e6);
        _routeEvent(vm.getRecordedLogs(), 100e6, expectedCommission, 100e6 - expectedCommission);
        assertEq(IERC20(USDC).balanceOf(address(vault)), expectedCommission);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6 - expectedCommission);
        assertEq(core.claimable(staker), 100e6 - expectedCommission);
        assertEq(vault.requiredTopUp(), shortfall - expectedCommission);
        assertEq(IERC20(USDC).allowance(address(distributor), address(core)), 0);
    }

    /// E-16.03/.07: Tests min of cap and shortfall four boundaries.
    function test_E16_MinOfCapAndShortfallFourBoundaries() public {
        uint256 snapshot = vm.snapshotState();
        _assertCapCase(0, 0);
        assertTrue(vm.revertToState(snapshot));
        _assertCapCase(10e6, 10e6);
        assertTrue(vm.revertToState(snapshot));
        _assertCapCase(20e6, 20e6);
        assertTrue(vm.revertToState(snapshot));
        _assertCapCase(30e6, 20e6);
    }

    /// E-16.04: Tests zero bps bypass and full commission no core deposit.
    function test_E16_ZeroBpsBypassAndFullCommissionNoCoreDeposit() public {
        _mintAndStake(staker, 100 ether);
        vault.pause();
        _distribute(100e6);
        assertEq(core.claimable(staker), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
        uint256 snapshot = vm.snapshotState();
        assertTrue(vm.revertToState(snapshot));
        // A separate clean fork snapshot has no stake, so any Core depositRewards call must revert.
        _fork();
        _deploySystem();
        core.unpause();
        _makeShortfall(100e6);
        distributor.setMaxCommissionSplitBps(10_000);
        vm.recordLogs();
        _distribute(100e6);
        _routeEvent(vm.getRecordedLogs(), 100e6, 100e6, 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 100e6);
        assertEq(vault.requiredTopUp(), 0);
    }

    /// E-16.05: Tests distribute and from balance same routing.
    function test_E16_DistributeAndFromBalanceSameRouting() public {
        _mintAndStake(staker, 100 ether);
        _makeShortfall(10e6);
        distributor.setMaxCommissionSplitBps(2_000);
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        _distribute(100e6);
        _routeEvent(vm.getRecordedLogs(), 100e6, 10e6, 90e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 90e6);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 10e6);
        assertTrue(vm.revertToState(snapshot));
        _fundUSDC(address(distributor), 100e6);
        vm.recordLogs();
        distributor.distributeFromBalance(100e6);
        _routeEvent(vm.getRecordedLogs(), 100e6, 10e6, 90e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 90e6);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 10e6);
        assertEq(IERC20(USDC).balanceOf(address(distributor)), 0);
        assertEq(core.claimable(staker), 90e6);
    }

    /// E-16.06: Tests core failure rolls back vault and operator transfer.
    function test_E16_CoreFailureRollsBackVaultAndOperatorTransfer() public {
        _makeShortfall(100e6);
        distributor.setMaxCommissionSplitBps(2_000);
        _fundUSDC(address(this), 100e6);
        IERC20(USDC).approve(address(distributor), 100e6);
        uint256 operatorBefore = IERC20(USDC).balanceOf(address(this));
        vm.expectRevert();
        distributor.distribute(100e6);
        assertEq(IERC20(USDC).balanceOf(address(this)), operatorBefore);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
        assertEq(vault.requiredTopUp(), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(distributor)), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        assertEq(IERC20(USDC).allowance(address(distributor), address(core)), 0);
        assertEq(core.accRewardPerShare(), 0);
    }

    /// E-16.08: Tests disable split before unbind and bypass faulty vault.
    function test_E16_DisableSplitBeforeUnbindAndBypassFaultyVault() public {
        _mintAndStake(staker, 100 ether);
        _makeShortfall(100e6);
        distributor.setMaxCommissionSplitBps(2_000);
        vm.expectRevert(RewardDistributor.CommissionSplitEnabled.selector);
        distributor.setCommissionVault(address(0));
        distributor.setMaxCommissionSplitBps(0);
        distributor.setCommissionVault(address(0));
        assertEq(distributor.commissionVault(), address(0));
        vault.pause();
        vm.recordLogs();
        _distribute(100e6);
        _routeEvent(vm.getRecordedLogs(), 100e6, 0, 100e6);
        assertEq(core.claimable(staker), 100e6);
        assertEq(vault.requiredTopUp(), 100e6);
    }
}
