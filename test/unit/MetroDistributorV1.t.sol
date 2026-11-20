// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";

import {MetroDistributorBase} from "../../src/MetroDistributorBase.sol";
import {MetroDistributorV1} from "../../src/MetroDistributorV1.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {MetroToken} from "../../src/metro.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MaliciousERC20} from "../mocks/MaliciousERC20.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {MockRateLimitedForwarder} from "../mocks/MockRateLimitedForwarder.sol";

contract MetroDistributorV1Test is Test {
    ERC20Mintable internal usdc;
    MetroToken internal metro;
    xMETRO internal xmetro;
    MetroDistributorV1 internal distributor;
    MockCommissionVault internal vault;
    MockRateLimitedForwarder internal forwarder;

    address internal operator = makeAddr("operator");
    address internal outsider = makeAddr("outsider");
    address internal staker = makeAddr("staker");
    address internal treasury = makeAddr("treasury");
    address internal polVault = makeAddr("polVault");

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        xmetro = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);
        distributor = new MetroDistributorV1(address(xmetro), treasury, polVault, address(this));
        xmetro.setRewardDistributor(address(distributor));
        distributor.setOperator(operator, true);

        metro.mint(staker, 100 ether);
        vm.startPrank(staker);
        metro.approve(address(xmetro), 100 ether);
        xmetro.stake(100 ether);
        vm.stopPrank();

        vault = new MockCommissionVault(address(usdc), 0, address(distributor));
        forwarder = new MockRateLimitedForwarder(address(usdc), address(distributor));
    }

    function _enableCommission(uint16 bps, uint256 shortfall) internal {
        vault.setTargetBalance(shortfall);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(bps);
    }

    function _distribute(uint256 maxAmount) internal {
        vm.prank(operator);
        distributor.distribute(maxAmount);
    }

    function test_ConstructorBindsCoreAndRejectsZeroAddresses() public {
        assertEq(address(distributor.xMETRO()), address(xmetro));
        assertEq(address(distributor.rewardToken()), address(usdc));
        assertEq(distributor.treasury(), treasury);
        assertEq(distributor.polVault(), polVault);
        assertEq(distributor.STAKERS_BPS(), 5_000);
        assertEq(distributor.TREASURY_BPS(), 2_500);
        assertEq(distributor.POL_BUYBACK_BPS(), 1_000);
        assertEq(distributor.POL_LIQUIDITY_BPS(), 1_500);
        assertEq(
            distributor.STAKERS_BPS() + distributor.TREASURY_BPS() + distributor.POL_BUYBACK_BPS()
                + distributor.POL_LIQUIDITY_BPS(),
            distributor.BPS_DENOMINATOR()
        );

        vm.expectRevert(MetroDistributorBase.ZeroXMetro.selector);
        new MetroDistributorV1(address(0), treasury, polVault, address(this));
        vm.expectRevert(MetroDistributorBase.ZeroTreasury.selector);
        new MetroDistributorV1(address(xmetro), address(0), polVault, address(this));
        vm.expectRevert(MetroDistributorV1.ZeroPolVault.selector);
        new MetroDistributorV1(address(xmetro), treasury, address(0), address(this));
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new MetroDistributorV1(address(xmetro), treasury, polVault, address(0));
    }

    function test_SettersValidateAndEmit() public {
        vm.expectRevert(MetroDistributorBase.InvalidOperator.selector);
        distributor.setOperator(address(0), true);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.OperatorUpdated(outsider, true);
        distributor.setOperator(outsider, true);
        assertTrue(distributor.operators(outsider));

        vm.expectRevert(MetroDistributorBase.ZeroTreasury.selector);
        distributor.setTreasury(address(0));
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(true, true, false, true, address(distributor));
        emit MetroDistributorBase.TreasuryUpdated(treasury, newTreasury);
        distributor.setTreasury(newTreasury);
        assertEq(distributor.treasury(), newTreasury);

        vm.expectRevert(MetroDistributorV1.ZeroPolVault.selector);
        distributor.setPolVault(address(0));
        address newPolVault = makeAddr("newPolVault");
        vm.expectEmit(true, true, false, true, address(distributor));
        emit MetroDistributorV1.PolVaultUpdated(polVault, newPolVault);
        distributor.setPolVault(newPolVault);
        assertEq(distributor.polVault(), newPolVault);

        MockRateLimitedForwarder wrongToken =
            new MockRateLimitedForwarder(address(new ERC20Mintable("X", "X", 6)), address(distributor));
        vm.expectRevert(MetroDistributorBase.ForwarderTokenMismatch.selector);
        distributor.setForwarder(address(wrongToken));
        vm.expectEmit(true, true, false, true, address(distributor));
        emit MetroDistributorBase.ForwarderUpdated(address(0), address(forwarder));
        distributor.setForwarder(address(forwarder));
        assertEq(address(distributor.forwarder()), address(forwarder));
        vm.expectEmit(true, true, false, true, address(distributor));
        emit MetroDistributorBase.ForwarderUpdated(address(forwarder), address(0));
        distributor.setForwarder(address(0));
    }

    function test_CommissionConfigurationKeepsRewardDistributorValidation() public {
        vm.expectRevert(MetroDistributorBase.InvalidCommissionSplitBps.selector);
        distributor.setMaxCommissionSplitBps(10_001);
        vm.expectRevert(MetroDistributorBase.ZeroCommissionVault.selector);
        distributor.setMaxCommissionSplitBps(1);
        vm.expectRevert(MetroDistributorBase.CommissionVaultNotContract.selector);
        distributor.setCommissionVault(outsider);
        MockCommissionVault wrongToken =
            new MockCommissionVault(address(new ERC20Mintable("X", "X", 6)), 0, address(distributor));
        vm.expectRevert(MetroDistributorBase.CommissionTokenMismatch.selector);
        distributor.setCommissionVault(address(wrongToken));
        MockCommissionVault wrongDistributor = new MockCommissionVault(address(usdc), 0, outsider);
        vm.expectRevert(MetroDistributorBase.CommissionDistributorMismatch.selector);
        distributor.setCommissionVault(address(wrongDistributor));

        vm.expectEmit(true, true, false, true, address(distributor));
        emit MetroDistributorBase.CommissionVaultUpdated(address(0), address(vault));
        distributor.setCommissionVault(address(vault));
        vm.expectEmit(false, false, false, true, address(distributor));
        emit MetroDistributorBase.MaxCommissionSplitBpsUpdated(0, 2_000);
        distributor.setMaxCommissionSplitBps(2_000);

        vm.expectRevert(MetroDistributorBase.CommissionSplitEnabled.selector);
        distributor.setCommissionVault(address(0));
        distributor.setMaxCommissionSplitBps(0);
        distributor.setCommissionVault(address(0));
        assertEq(distributor.commissionVault(), address(0));
    }

    function test_RescueTokens() public {
        usdc.mint(address(distributor), 5e6);
        vm.expectRevert(MetroDistributorBase.InvalidRecipient.selector);
        distributor.rescueTokens(address(usdc), address(0), 1);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit MetroDistributorBase.TokensRescued(address(usdc), outsider, 5e6);
        distributor.rescueTokens(address(usdc), outsider, 5e6);
        assertEq(usdc.balanceOf(outsider), 5e6);
    }

    function test_OnlyOperatorDistributesAndOnlyOwnerConfigures() public {
        vm.startPrank(outsider);
        vm.expectRevert(MetroDistributorBase.UnauthorizedOperator.selector);
        distributor.distribute(0);
        bytes memory unauthorized = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider);
        vm.expectRevert(unauthorized);
        distributor.setOperator(outsider, true);
        vm.expectRevert(unauthorized);
        distributor.setCommissionVault(address(vault));
        vm.expectRevert(unauthorized);
        distributor.setMaxCommissionSplitBps(0);
        vm.expectRevert(unauthorized);
        distributor.setForwarder(address(forwarder));
        vm.expectRevert(unauthorized);
        distributor.setTreasury(outsider);
        vm.expectRevert(unauthorized);
        distributor.setPolVault(outsider);
        vm.expectRevert(unauthorized);
        distributor.rescueTokens(address(usdc), outsider, 0);
        vm.stopPrank();
    }

    function test_FullRunEmitsEveryLegInOrder() public {
        distributor.setForwarder(address(forwarder));
        _enableCommission(1_000, 100e6);
        usdc.mint(address(forwarder), 1_000e6);

        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.ForwarderPulled(address(forwarder), 1_000e6);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.CommissionToppedUp(address(vault), 100e6);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.TreasuryPaid(treasury, 225e6);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorV1.PolVaultFunded(polVault, 225e6);
        vm.expectEmit(false, false, false, true, address(distributor));
        emit MetroDistributorV1.PolBuybackAllocated(90e6);
        vm.expectEmit(false, false, false, true, address(distributor));
        emit MetroDistributorV1.PolLiquidityAllocated(135e6);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.RewardsDistributed(operator, 450e6, uint64(block.timestamp));
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.Distributed(operator, 1_000e6, 100e6, 450e6, 225e6, 225e6, uint64(block.timestamp));
        _distribute(0);

        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(usdc.balanceOf(treasury), 225e6);
        assertEq(usdc.balanceOf(polVault), 225e6);
        assertEq(usdc.balanceOf(address(xmetro)), 450e6);
        assertEq(xmetro.claimable(staker), 450e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
    }

    function test_State_ForwarderUnsetRoutesExistingBalance() public {
        usdc.mint(address(distributor), 100e6);
        _distribute(0);
        assertEq(usdc.balanceOf(address(xmetro)), 50e6);
        assertEq(usdc.balanceOf(treasury), 25e6);
        assertEq(usdc.balanceOf(polVault), 25e6);
    }

    function test_State_ForwarderPausedOrEmptyRoutesBalanceOrReverts() public {
        distributor.setForwarder(address(forwarder));
        vm.prank(operator);
        vm.expectRevert(MetroDistributorBase.ZeroAmount.selector);
        distributor.distribute(0);

        usdc.mint(address(forwarder), 40e6);
        forwarder.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(MetroDistributorBase.ZeroAmount.selector);
        distributor.distribute(0);

        usdc.mint(address(distributor), 100e6);
        _distribute(0);
        assertEq(usdc.balanceOf(address(forwarder)), 40e6);
        assertEq(usdc.balanceOf(address(xmetro)), 50e6);
    }

    function test_State_ForwarderReleasesOnlyItsSlice() public {
        distributor.setForwarder(address(forwarder));
        usdc.mint(address(forwarder), 100e6);
        forwarder.setReleasable(20e6);
        _distribute(0);
        assertEq(usdc.balanceOf(address(forwarder)), 80e6);
        assertEq(usdc.balanceOf(address(xmetro)), 10e6);
    }

    function test_State_MaxAmountCapsRoutedAmount() public {
        usdc.mint(address(distributor), 100e6);
        _distribute(40e6);
        assertEq(usdc.balanceOf(address(xmetro)), 20e6);
        assertEq(usdc.balanceOf(address(distributor)), 60e6);

        _distribute(60e6);
        assertEq(usdc.balanceOf(address(xmetro)), 50e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);

        usdc.mint(address(distributor), 10e6);
        _distribute(1_000e6);
        assertEq(usdc.balanceOf(address(xmetro)), 55e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function test_State_DirectTransferIsIncludedWithForwarderPull() public {
        distributor.setForwarder(address(forwarder));
        usdc.mint(address(forwarder), 60e6);
        usdc.mint(address(distributor), 40e6);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit MetroDistributorBase.Distributed(operator, 100e6, 0, 50e6, 25e6, 25e6, uint64(block.timestamp));
        _distribute(0);
    }

    function test_State_CommissionDisabledSendsAllToBuckets() public {
        distributor.setCommissionVault(address(vault));
        vault.setTargetBalance(1_000e6);
        usdc.mint(address(distributor), 100e6);
        _distribute(0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(xmetro)), 50e6);
    }

    function test_State_InvalidCommissionVaultRevertsWhileSplitEnabled() public {
        _enableCommission(1_000, 10e6);
        usdc.mint(address(distributor), 100e6);

        vault.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(MetroDistributorBase.CommissionVaultPaused.selector);
        distributor.distribute(0);
        vault.setPaused(false);

        vault.setMigrationFinalized(false);
        vm.prank(operator);
        vm.expectRevert(MetroDistributorBase.CommissionVaultMigrationPending.selector);
        distributor.distribute(0);
        vault.setMigrationFinalized(true);

        vault.setDistributor(outsider);
        vm.prank(operator);
        vm.expectRevert(MetroDistributorBase.CommissionDistributorMismatch.selector);
        distributor.distribute(0);
    }

    function test_State_CommissionConsumesEverythingSkipsLegs() public {
        _enableCommission(10_000, 1_000e6);
        usdc.mint(address(distributor), 100e6);
        vm.recordLogs();
        _distribute(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[1].topics[0], MetroDistributorBase.CommissionToppedUp.selector);
        assertEq(logs[2].topics[0], MetroDistributorBase.Distributed.selector);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(polVault), 0);
        assertEq(usdc.balanceOf(address(xmetro)), 0);
    }

    function test_State_TinyAmountSkipsZeroLegsAndDustGoesToStakers() public {
        usdc.mint(address(distributor), 3);
        vm.recordLogs();
        _distribute(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[logs.length - 2].topics[0], MetroDistributorBase.RewardsDistributed.selector);
        assertEq(logs[logs.length - 1].topics[0], MetroDistributorBase.Distributed.selector);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(polVault), 0);
        assertEq(usdc.balanceOf(address(xmetro)), 3);

        usdc.mint(address(distributor), 7);
        _distribute(0);
        assertEq(usdc.balanceOf(treasury), 1);
        assertEq(usdc.balanceOf(polVault), 1);
        assertEq(usdc.balanceOf(address(xmetro)), 8);
    }

    function test_State_ReentrancyIsBlocked() public {
        MaliciousERC20 token = new MaliciousERC20("Malicious", "MUSDC", 6);
        xMETRO core = new xMETRO(address(this), address(metro), address(token), makeAddr("forfeiture"), 20_000);
        MetroDistributorV1 guarded = new MetroDistributorV1(address(core), treasury, polVault, address(this));
        core.setRewardDistributor(address(guarded));
        guarded.setOperator(address(this), true);
        guarded.setOperator(address(token), true);
        metro.mint(staker, 1 ether);
        vm.startPrank(staker);
        metro.approve(address(core), 1 ether);
        core.stake(1 ether);
        vm.stopPrank();

        token.mint(address(guarded), 100e6);
        token.setAttack(address(guarded), abi.encodeCall(MetroDistributorBase.distribute, (0)), true);
        guarded.distribute(0);
        assertTrue(token.attackAttempted());
        assertFalse(token.attackSucceeded());
        assertEq(token.attackRevertData(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        assertEq(token.balanceOf(address(core)), 50e6);
    }

    function test_TwoStepOwnership() public {
        address next = makeAddr("next");
        distributor.transferOwnership(next);
        assertEq(distributor.owner(), address(this));
        assertEq(distributor.pendingOwner(), next);
        vm.prank(next);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), next);
    }
}
