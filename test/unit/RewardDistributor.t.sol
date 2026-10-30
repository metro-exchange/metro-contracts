// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import {MaliciousERC20} from "../mocks/MaliciousERC20.sol";

import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {MetroToken} from "../../src/metro.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {SourceCompatibleCommissionVault} from "../mocks/SourceCompatibleCommissionVault.sol";

contract RevertingVaultTransferToken is ERC20Mintable {
    address public blockedRecipient;

    constructor() ERC20Mintable("REVERT", "REVERT", 6) {}

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blockedRecipient, "RevertingToken: blocked transfer");
        return super.transfer(to, amount);
    }
}

contract RewardDistributorTest is Test {
    ERC20Mintable internal usdc;
    ERC20Mintable internal otherToken;
    MetroToken internal metro;
    xMETRO internal xmetro;
    RewardDistributor internal distributor;
    MockCommissionVault internal vault;

    address internal operator = makeAddr("operator");
    address internal user = makeAddr("user");
    address internal outsider = makeAddr("outsider");
    address internal forfeitureRecipient = makeAddr("forfeitureMultisig");

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        otherToken = new ERC20Mintable("OTHER", "OTHER", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        xmetro = new xMETRO(address(this), address(metro), address(usdc), forfeitureRecipient, 20_000);
        distributor = new RewardDistributor(address(xmetro), address(this));
        xmetro.setRewardDistributor(address(distributor));
        distributor.setOperator(operator, true);

        metro.mint(user, 100 ether);
        vm.prank(user);
        metro.approve(address(xmetro), 100 ether);
        vm.prank(user);
        xmetro.stake(100 ether);

        vault = new MockCommissionVault(address(usdc), 0, address(distributor));
        usdc.mint(operator, 10_000e6);
        vm.prank(operator);
        usdc.approve(address(distributor), type(uint256).max);
    }

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function test_TwoStepOwnershipAcceptReplaceCancelAndPermissions() public {
        address next = makeAddr("pending-owner");
        address replaced = makeAddr("replacement-owner");
        assertEq(distributor.owner(), address(this));
        assertEq(distributor.pendingOwner(), address(0));
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        distributor.acceptOwnership();
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        distributor.transferOwnership(replaced);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit OwnershipTransferStarted(address(this), next);
        distributor.transferOwnership(next);
        assertEq(distributor.owner(), address(this));
        assertEq(distributor.pendingOwner(), next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        distributor.setOperator(outsider, true);
        distributor.setOperator(outsider, true);
        distributor.transferOwnership(replaced);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        distributor.acceptOwnership();
        distributor.transferOwnership(address(0));
        assertEq(distributor.owner(), address(this));
        assertEq(distributor.pendingOwner(), address(0));
        vm.prank(replaced);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", replaced));
        distributor.acceptOwnership();
        distributor.transferOwnership(next);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit OwnershipTransferred(address(this), next);
        vm.prank(next);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), next);
        assertEq(distributor.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        distributor.setOperator(outsider, true);
        vm.prank(next);
        distributor.setOperator(outsider, true);
        vm.prank(next);
        distributor.transferOwnership(replaced);
        vm.prank(next);
        distributor.renounceOwnership();
        assertEq(distributor.owner(), address(0));
        assertEq(distributor.pendingOwner(), address(0));
        vm.prank(replaced);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", replaced));
        distributor.acceptOwnership();
    }

    function test_AcceptingOwnerRetainsOperatorAndUserRewards() public {
        address next = makeAddr("distributor-next-owner");
        distributor.transferOwnership(next);
        vm.prank(next);
        distributor.acceptOwnership();
        assertTrue(distributor.operators(operator));
        vm.prank(operator);
        distributor.distribute(10e6);
        assertEq(xmetro.claimable(user), 10e6);
    }

    function testFuzz_TransientGuardChecksAuthorizedCallbacksAndSameTransactionRetry(
        bool fromBalance,
        bool crossFunction
    ) public {
        MaliciousERC20 token = new MaliciousERC20("Malicious rewards", "MUSDC", 6);
        xMETRO guardedCore = new xMETRO(address(this), address(metro), address(token), forfeitureRecipient, 20_000);
        RewardDistributor guarded = new RewardDistributor(address(guardedCore), address(this));
        guardedCore.setRewardDistributor(address(guarded));
        guarded.setOperator(address(this), true);
        guarded.setOperator(address(token), true); // Reach the lock, not an unrelated operator failure.
        MockCommissionVault commission = new MockCommissionVault(address(token), 100e6, address(guarded));
        guarded.setCommissionVault(address(commission));
        guarded.setMaxCommissionSplitBps(1_000);
        metro.mint(user, 100 ether);
        vm.startPrank(user);
        metro.approve(address(guardedCore), 100 ether);
        guardedCore.stake(100 ether);
        vm.stopPrank();
        token.mint(fromBalance ? address(guarded) : address(this), 30e6);
        token.approve(address(guarded), type(uint256).max);
        bool nestedBalance = crossFunction ? !fromBalance : fromBalance;
        bytes memory nested = nestedBalance
            ? abi.encodeCall(RewardDistributor.distributeFromBalance, (1))
            : abi.encodeCall(RewardDistributor.distribute, (1));
        for (uint256 i; i < 2; ++i) {
            token.setAttack(address(guarded), nested, true);
            if (fromBalance) guarded.distributeFromBalance(10e6);
            else guarded.distribute(10e6);
            assertTrue(token.attackAttempted());
            assertFalse(token.attackSucceeded());
            assertEq(token.attackRevertData(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        }
        assertEq(guardedCore.claimable(user), 18e6);
        assertEq(token.balanceOf(address(commission)), 2e6);
        token.setAttack(address(guarded), nested, false);
        guardedCore.pause();
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        if (fromBalance) guarded.distributeFromBalance(10e6);
        else guarded.distribute(10e6);
        assertEq(token.balanceOf(address(commission)), 2e6);
        assertEq(guardedCore.claimable(user), 18e6);
        guardedCore.unpause();
        if (fromBalance) guarded.distributeFromBalance(10e6);
        else guarded.distribute(10e6);
        assertEq(token.balanceOf(address(commission)), 3e6);
        assertEq(guardedCore.claimable(user), 27e6);
    }

    function test_ConstructorAndOperatorPermissions() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new RewardDistributor(address(xmetro), address(0));
        assertEq(address(distributor.rewardToken()), address(usdc));
        assertEq(address(distributor.xMETRO()), address(xmetro));

        vm.expectRevert(bytes("RewardDistributor: zero xMETRO"));
        new RewardDistributor(address(0), address(this));

        vm.prank(outsider);
        vm.expectRevert();
        distributor.setOperator(outsider, true);

        vm.prank(outsider);
        vm.expectRevert(bytes("RewardDistributor: only operator"));
        distributor.distribute(1);

        vm.prank(operator);
        vm.expectRevert(bytes("RewardDistributor: zero amount"));
        distributor.distribute(0);
    }

    function test_CommissionConfigurationValidationAndMigration() public {
        vm.prank(outsider);
        vm.expectRevert();
        distributor.setCommissionVault(address(vault));

        vm.expectRevert(bytes("RewardDistributor: bps > 10000"));
        distributor.setMaxCommissionSplitBps(10_001);

        vm.expectRevert(bytes("RewardDistributor: zero vault"));
        distributor.setMaxCommissionSplitBps(1);

        vm.expectRevert(bytes("RewardDistributor: vault not contract"));
        distributor.setCommissionVault(outsider);

        MockCommissionVault wrongTokenVault = new MockCommissionVault(address(otherToken), 1, address(distributor));
        vm.expectRevert(bytes("RewardDistributor: token mismatch"));
        distributor.setCommissionVault(address(wrongTokenVault));

        MockCommissionVault wrongDistributorVault = new MockCommissionVault(address(usdc), 1, outsider);
        vm.expectRevert(bytes("RewardDistributor: distributor mismatch"));
        distributor.setCommissionVault(address(wrongDistributorVault));

        MockCommissionVault pendingMigrationVault = new MockCommissionVault(address(usdc), 1, address(distributor));
        pendingMigrationVault.setMigrationFinalized(false);
        vm.expectRevert(bytes("RewardDistributor: vault migration pending"));
        distributor.setCommissionVault(address(pendingMigrationVault));

        MockCommissionVault pausedVault = new MockCommissionVault(address(usdc), 1, address(distributor));
        pausedVault.setPaused(true);
        vm.expectRevert(bytes("RewardDistributor: vault paused"));
        distributor.setCommissionVault(address(pausedVault));

        vm.expectEmit(true, true, false, true);
        emit RewardDistributor.CommissionVaultUpdated(address(0), address(vault));
        distributor.setCommissionVault(address(vault));
        vm.expectEmit(false, false, false, true);
        emit RewardDistributor.MaxCommissionSplitBpsUpdated(0, 2_500);
        distributor.setMaxCommissionSplitBps(2_500);

        vm.expectRevert(bytes("RewardDistributor: split enabled"));
        distributor.setCommissionVault(address(0));

        MockCommissionVault replacement = new MockCommissionVault(address(usdc), 100e6, address(distributor));
        distributor.setCommissionVault(address(replacement));
        assertEq(distributor.commissionVault(), address(replacement));

        distributor.setMaxCommissionSplitBps(0);
        distributor.setCommissionVault(address(0));
        assertEq(distributor.commissionVault(), address(0));
    }

    function test_ZeroBpsBypassesVaultCompletely() public {
        distributor.setCommissionVault(address(vault));
        vault.setTargetBalance(100e6);
        vault.setRevertRequiredTopUp(true);

        vm.prank(operator);
        distributor.distribute(100e6);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(xmetro.claimable(user), 100e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
    }

    function test_ZeroBpsIsRecoveryPathWhenConfiguredVaultLaterPauses() public {
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(1_000);
        vault.setPaused(true);

        vm.prank(operator);
        vm.expectRevert(bytes("RewardDistributor: vault paused"));
        distributor.distribute(100e6);

        distributor.setMaxCommissionSplitBps(0);
        vm.prank(operator);
        distributor.distribute(100e6);
        assertEq(xmetro.claimable(user), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_ShortfallBelowCapSendsOnlyNeedAndEmitsGrossCommissionNet() public {
        vault.setTargetBalance(15e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(2_000); // 20% of 100 = 20, need = 15

        vm.expectCall(address(vault), abi.encodeCall(MockCommissionVault.requiredTopUp, ()), 1);
        vm.expectEmit(true, false, false, true);
        emit RewardDistributor.RewardsDistributed(operator, 85e6, uint64(block.timestamp));
        vm.expectEmit(true, true, false, true);
        emit RewardDistributor.DistributionRouted(operator, address(vault), 100e6, 15e6, 85e6, uint64(block.timestamp));
        vm.prank(operator);
        distributor.distribute(100e6);

        assertEq(usdc.balanceOf(address(vault)), 15e6);
        assertEq(xmetro.claimable(user), 85e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
        assertEq(usdc.allowance(address(distributor), address(vault)), 0);
    }

    function test_ShortfallAboveCapSendsOnlyConfiguredSlice() public {
        vault.setTargetBalance(1_000e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(2_000);

        vm.prank(operator);
        distributor.distribute(100e6);
        assertEq(usdc.balanceOf(address(vault)), 20e6);
        assertEq(xmetro.claimable(user), 80e6);
    }

    function test_PartialCoverageRollsOverThroughVaultBalanceWithoutDistributorState() public {
        vault.setTargetBalance(25e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(1_000); // cap 10 per 100 distribution

        vm.startPrank(operator);
        distributor.distribute(100e6);
        distributor.distribute(100e6);
        distributor.distribute(100e6);
        distributor.distribute(100e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 25e6);
        assertEq(xmetro.claimable(user), 375e6);
        assertEq(vault.requiredTopUp(), 0);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function test_DistributeFromBalanceUsesSameRouting() public {
        vault.setTargetBalance(40e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(5_000);
        usdc.mint(address(distributor), 100e6);

        vm.prank(operator);
        distributor.distributeFromBalance(100e6);
        assertEq(usdc.balanceOf(address(vault)), 40e6);
        assertEq(xmetro.claimable(user), 60e6);

        vm.prank(operator);
        vm.expectRevert(bytes("RewardDistributor: insufficient balance"));
        distributor.distributeFromBalance(1);
    }

    function test_OneHundredPercentSplitCanProduceZeroNetWithoutCallingDepositRewardsZero() public {
        vault.setTargetBalance(100e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(10_000);
        uint256 accBefore = xmetro.accRewardPerShare();

        vm.prank(operator);
        distributor.distribute(100e6);

        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(xmetro.accRewardPerShare(), accBefore);
        assertEq(xmetro.claimable(user), 0);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function test_RequiredTopUpFailureRollsBackPulledFunds() public {
        vault.setTargetBalance(100e6);
        vault.setRevertRequiredTopUp(true);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(1_000);
        uint256 operatorBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        vm.expectRevert(bytes("MockVault: requiredTopUp failed"));
        distributor.distribute(100e6);

        assertEq(usdc.balanceOf(operator), operatorBefore);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(xmetro.claimable(user), 0);
    }

    function test_XMetroFailureRollsBackVaultTransferAndPullAtomically() public {
        vault.setTargetBalance(20e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(2_000);
        xmetro.pause();
        uint256 operatorBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        vm.expectRevert();
        distributor.distribute(100e6);

        assertEq(usdc.balanceOf(operator), operatorBefore);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function test_VaultTokenTransferFailureRollsBackPulledFundsAtomically() public {
        RevertingVaultTransferToken badToken = new RevertingVaultTransferToken();
        xMETRO localXMetro = new xMETRO(address(this), address(metro), address(badToken), forfeitureRecipient, 20_000);
        RewardDistributor localDistributor = new RewardDistributor(address(localXMetro), address(this));
        MockCommissionVault localVault = new MockCommissionVault(address(badToken), 100e6, address(localDistributor));
        localXMetro.setRewardDistributor(address(localDistributor));
        localDistributor.setOperator(operator, true);
        localDistributor.setCommissionVault(address(localVault));
        localDistributor.setMaxCommissionSplitBps(2_000);

        badToken.mint(operator, 100e6);
        vm.prank(operator);
        badToken.approve(address(localDistributor), 100e6);
        badToken.setBlockedRecipient(address(localVault));

        vm.prank(operator);
        vm.expectRevert(bytes("RevertingToken: blocked transfer"));
        localDistributor.distribute(100e6);
        assertEq(badToken.balanceOf(operator), 100e6);
        assertEq(badToken.balanceOf(address(localDistributor)), 0);
        assertEq(badToken.balanceOf(address(localVault)), 0);
    }

    function test_ChangingVaultRoutesOnlyFutureDistributionsToReplacement() public {
        MockCommissionVault replacement = new MockCommissionVault(address(usdc), 100e6, address(distributor));
        vault.setTargetBalance(100e6);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(1_000);

        vm.prank(operator);
        distributor.distribute(100e6);
        distributor.setCommissionVault(address(replacement));
        vm.prank(operator);
        distributor.distribute(100e6);

        assertEq(usdc.balanceOf(address(vault)), 10e6);
        assertEq(usdc.balanceOf(address(replacement)), 10e6);
    }

    function test_SourceCompatibleVaultSettlementTopUpClaimAndSurplusRoundTrip() public {
        address vaultOperator = makeAddr("vault-operator");
        address affiliate = makeAddr("affiliate");
        SourceCompatibleCommissionVault sourceVault = new SourceCompatibleCommissionVault(
            address(usdc),
            address(distributor),
            vaultOperator,
            makeAddr("vault-guardian"),
            1_000e6,
            10_000e6,
            false,
            1 minutes,
            1 minutes
        );
        string[] memory codes = new string[](1);
        address[] memory payouts = new address[](1);
        uint256[] memory cumulative = new uint256[](1);
        codes[0] = "affiliate-code";
        payouts[0] = affiliate;
        cumulative[0] = 20e6;

        vm.prank(vaultOperator);
        sourceVault.proposeSettlement(codes, payouts, cumulative);
        vm.warp(sourceVault.pendingActivationTime());
        sourceVault.activateSettlement();
        assertEq(sourceVault.requiredTopUp(), 20e6);

        distributor.setCommissionVault(address(sourceVault));
        distributor.setMaxCommissionSplitBps(5_000);
        vm.prank(operator);
        distributor.distribute(100e6);

        assertEq(usdc.balanceOf(address(sourceVault)), 20e6);
        assertEq(xmetro.claimable(user), 80e6);
        assertEq(usdc.allowance(address(distributor), address(sourceVault)), 0);
        vm.prank(affiliate);
        sourceVault.claim(codes[0]);
        assertEq(usdc.balanceOf(affiliate), 20e6);

        cumulative[0] = 30e6;
        vm.prank(vaultOperator);
        sourceVault.proposeSettlement(codes, payouts, cumulative);
        vm.warp(sourceVault.pendingActivationTime());
        sourceVault.activateSettlement();
        assertEq(sourceVault.requiredTopUp(), 10e6);

        usdc.mint(address(sourceVault), 15e6);
        vm.prank(vaultOperator);
        sourceVault.processIncoming();
        assertEq(usdc.balanceOf(address(sourceVault)), 10e6);
        assertEq(usdc.balanceOf(address(distributor)), 5e6);

        vm.prank(operator);
        distributor.distributeFromBalance(5e6);
        assertEq(xmetro.claimable(user), 85e6);
        vm.prank(affiliate);
        sourceVault.claim(codes[0]);
        assertEq(usdc.balanceOf(affiliate), 30e6);
        assertEq(sourceVault.requiredReserve(), 0);
        assertEq(usdc.balanceOf(address(sourceVault)), 0);
    }

    function test_RescueOnlyOwnerAndBadRecipient() public {
        usdc.mint(address(distributor), 10e6);
        vm.prank(outsider);
        vm.expectRevert();
        distributor.rescueTokens(address(usdc), user, 1);
        vm.expectRevert(bytes("RewardDistributor: bad to"));
        distributor.rescueTokens(address(usdc), address(0), 1);

        distributor.rescueTokens(address(usdc), user, 10e6);
        assertEq(usdc.balanceOf(user), 10e6);
    }
}
