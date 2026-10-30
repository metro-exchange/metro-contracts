// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import {MaliciousERC20} from "../mocks/MaliciousERC20.sol";

import {ThorMigrationEscrow} from "../../src/ThorMigrationEscrow.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";

contract MockXMetroMigrationV2 {
    address public lastThorUser;
    uint256 public lastThorPrincipal;
    address public lastYThorUser;
    uint256 public lastYThorPrincipal;
    uint256 public thorCredits;
    uint256 public yThorCredits;
    bool public revertCredits;

    function setRevertCredits(bool value) external {
        revertCredits = value;
    }

    function creditThorFromMigration(address user, uint256 principal) external {
        require(!revertCredits, "MockXMetro: rejected");
        lastThorUser = user;
        lastThorPrincipal = principal;
        thorCredits++;
    }

    function creditYThorFromMigration(address user, uint256 principal) external {
        require(!revertCredits, "MockXMetro: rejected");
        lastYThorUser = user;
        lastYThorPrincipal = principal;
        yThorCredits++;
    }
}

contract ThorMigrationEscrowUnitTest is Test {
    ERC20Mintable internal thor;
    ERC20Mintable internal yThor;
    ERC20Mintable internal other;
    MockXMetroMigrationV2 internal xmetro;
    ThorMigrationEscrow internal escrow;

    address internal owner = address(this);
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    uint256 internal constant RATIO_THOR = 11e17;
    uint256 internal constant RATIO_YTHOR = 8e17;
    uint256 internal constant CAP_THOR = 1_000_000 ether;
    uint256 internal constant CAP_YTHOR = 500_000 ether;

    function setUp() public {
        thor = new ERC20Mintable("THOR", "THOR", 18);
        yThor = new ERC20Mintable("yTHOR", "yTHOR", 18);
        other = new ERC20Mintable("OTHER", "OTHER", 18);
        xmetro = new MockXMetroMigrationV2();

        escrow = new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp);
        escrow.setCaps(CAP_THOR, CAP_YTHOR);
        escrow.setRatios(RATIO_THOR, RATIO_YTHOR);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
    }

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function test_TwoStepOwnershipAcceptReplaceCancelAndPermissions() public {
        address next = makeAddr("pending-owner");
        address replaced = makeAddr("replacement-owner");
        assertEq(escrow.owner(), address(this));
        assertEq(escrow.pendingOwner(), address(0));
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        escrow.acceptOwnership();
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        escrow.transferOwnership(replaced);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit OwnershipTransferStarted(address(this), next);
        escrow.transferOwnership(next);
        assertEq(escrow.owner(), address(this));
        assertEq(escrow.pendingOwner(), next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        escrow.setCaps(CAP_THOR, CAP_YTHOR);
        escrow.setCaps(CAP_THOR, CAP_YTHOR);
        escrow.transferOwnership(replaced);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", next));
        escrow.acceptOwnership();
        escrow.transferOwnership(address(0));
        assertEq(escrow.owner(), address(this));
        assertEq(escrow.pendingOwner(), address(0));
        vm.prank(replaced);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", replaced));
        escrow.acceptOwnership();
        escrow.transferOwnership(next);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit OwnershipTransferred(address(this), next);
        vm.prank(next);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), next);
        assertEq(escrow.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        escrow.setCaps(CAP_THOR, CAP_YTHOR);
        vm.prank(next);
        escrow.setCaps(CAP_THOR, CAP_YTHOR);
        vm.prank(next);
        escrow.transferOwnership(replaced);
        vm.prank(next);
        escrow.renounceOwnership();
        assertEq(escrow.owner(), address(0));
        assertEq(escrow.pendingOwner(), address(0));
        vm.prank(replaced);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", replaced));
        escrow.acceptOwnership();
    }

    function test_PausedRenounceRejectedAndOwnershipCanStillBeAccepted() public {
        address next = makeAddr("paused-next-owner");
        escrow.pause();
        escrow.transferOwnership(next);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        escrow.renounceOwnership();
        assertEq(escrow.owner(), address(this));
        assertEq(escrow.pendingOwner(), next);
        assertTrue(escrow.paused());
        escrow.transferOwnership(address(0));
        assertEq(escrow.pendingOwner(), address(0));
        escrow.transferOwnership(next);
        vm.prank(next);
        escrow.acceptOwnership();
        assertTrue(escrow.paused());
        vm.prank(next);
        escrow.unpause();
        assertFalse(escrow.paused());
    }

    function _approveAndFund(address account, ERC20Mintable token, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(escrow), amount);
    }

    function testFuzz_TransientGuardProtectsBothMigrationCallbacksAndRecovers(bool yThorPath, bool crossFunction)
        public
    {
        MaliciousERC20 token = new MaliciousERC20("Malicious migration", "MMIG", 18);
        ThorMigrationEscrow guarded = new ThorMigrationEscrow(
            address(this),
            address(xmetro),
            yThorPath ? address(thor) : address(token),
            yThorPath ? address(token) : address(yThor),
            block.timestamp
        );
        guarded.setRatios(1 ether, 1 ether);
        guarded.setCaps(100 ether, 100 ether);
        guarded.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        token.mint(user, 30 ether);
        vm.prank(user);
        token.approve(address(guarded), type(uint256).max);
        bool nestedYThor = crossFunction ? !yThorPath : yThorPath;
        bytes memory nested = nestedYThor
            ? abi.encodeCall(ThorMigrationEscrow.migrateYThor, (1))
            : abi.encodeCall(ThorMigrationEscrow.migrateThor, (1));
        for (uint256 i; i < 2; ++i) {
            token.setAttack(address(guarded), nested, true);
            vm.prank(user);
            if (yThorPath) guarded.migrateYThor(10 ether);
            else guarded.migrateThor(10 ether);
            assertTrue(token.attackAttempted());
            assertFalse(token.attackSucceeded());
            assertEq(token.attackRevertData(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        }
        token.setAttack(address(guarded), nested, false);
        xmetro.setRevertCredits(true);
        vm.prank(user);
        vm.expectRevert(bytes("MockXMetro: rejected"));
        if (yThorPath) guarded.migrateYThor(1 ether);
        else guarded.migrateThor(1 ether);
        assertEq(token.balanceOf(address(guarded)), 20 ether);
        assertEq(xmetro.thorCredits() + xmetro.yThorCredits(), 2);
        xmetro.setRevertCredits(false);
        vm.prank(user);
        if (yThorPath) guarded.migrateYThor(1 ether);
        else guarded.migrateThor(1 ether);
        assertEq(token.balanceOf(address(guarded)), 21 ether);
        assertEq(xmetro.thorCredits() + xmetro.yThorCredits(), 3);
    }

    function test_ConstructorRejectsInvalidInputs() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new ThorMigrationEscrow(address(0), address(xmetro), address(thor), address(yThor), block.timestamp);
        vm.expectRevert(ThorMigrationEscrow.ZeroXMetro.selector);
        new ThorMigrationEscrow(owner, address(0), address(thor), address(yThor), block.timestamp);

        vm.expectRevert(ThorMigrationEscrow.ZeroMigrationToken.selector);
        new ThorMigrationEscrow(owner, address(xmetro), address(0), address(yThor), block.timestamp);

        vm.expectRevert(ThorMigrationEscrow.InvalidMigrationStartTime.selector);
        new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp - 1);
    }

    function test_CustomErrorsCoverBothConfigurationOperands() public {
        vm.expectRevert(ThorMigrationEscrow.ZeroMigrationToken.selector);
        new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(0), block.timestamp);
        vm.expectRevert(ThorMigrationEscrow.InvalidMigrationCap.selector);
        escrow.setCaps(1 ether, 0);
        vm.expectRevert(ThorMigrationEscrow.InvalidMigrationRatio.selector);
        escrow.setRatios(1 ether, 0);
        vm.expectRevert(ThorMigrationEscrow.InvalidMigrationDeadline.selector);
        escrow.setDeadlines(block.timestamp + 10, block.timestamp - 1);
        vm.expectRevert(ThorMigrationEscrow.DeadlineNotAfterMigrationStart.selector);
        escrow.setDeadlines(block.timestamp + 10, block.timestamp);
        vm.expectRevert(ThorMigrationEscrow.InvalidMigrationStartTime.selector);
        escrow.setMigrationStartTime(block.timestamp - 1);
    }

    function test_ConfigurationPermissionsValidationAndEvents() public {
        ThorMigrationEscrow fresh =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp + 10);

        vm.prank(user);
        vm.expectRevert();
        fresh.setCaps(1, 1);

        vm.expectRevert(ThorMigrationEscrow.InvalidMigrationCap.selector);
        fresh.setCaps(0, 1);
        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.CapsUpdated(10, 20);
        fresh.setCaps(10, 20);

        vm.expectRevert(ThorMigrationEscrow.InvalidMigrationRatio.selector);
        fresh.setRatios(0, 1e18);
        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.RatiosUpdated(2e18, 3e18);
        fresh.setRatios(2e18, 3e18);
        vm.expectRevert(ThorMigrationEscrow.MigrationRatiosLocked.selector);
        fresh.setRatios(1e18, 1e18);

        vm.expectRevert(ThorMigrationEscrow.DeadlineNotAfterMigrationStart.selector);
        fresh.setDeadlines(block.timestamp + 5, block.timestamp + 20);
        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.DeadlinesUpdated(block.timestamp + 20, block.timestamp + 30);
        fresh.setDeadlines(block.timestamp + 20, block.timestamp + 30);

        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.MigrationStartTimeUpdated(block.timestamp + 20);
        fresh.setMigrationStartTime(block.timestamp + 20);

        // Preserve the audited baseline: the owner may reschedule to a future timestamp even after the old start.
        vm.warp(block.timestamp + 20);
        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.MigrationStartTimeUpdated(block.timestamp + 1);
        fresh.setMigrationStartTime(block.timestamp + 1);
    }

    function test_MigrateThorUsesUnifiedRatioAndCreatesIndependentCredits() public {
        uint256 amountIn = 100 ether;
        uint256 principal = amountIn * RATIO_THOR / 1e18;
        _approveAndFund(user, thor, amountIn * 2);

        vm.expectEmit(true, false, false, true);
        emit ThorMigrationEscrow.MigratedThor(user, amountIn, principal);
        vm.prank(user);
        escrow.migrateThor(amountIn);

        assertEq(thor.balanceOf(address(escrow)), amountIn);
        assertEq(escrow.migratedThor(), principal);
        assertEq(xmetro.lastThorUser(), user);
        assertEq(xmetro.lastThorPrincipal(), principal);
        assertEq(xmetro.thorCredits(), 1);

        vm.prank(user);
        escrow.migrateThor(amountIn);
        assertEq(escrow.migratedThor(), principal * 2);
        assertEq(thor.balanceOf(address(escrow)), amountIn * 2);
        assertEq(xmetro.thorCredits(), 2);
    }

    function test_MigrateYThorUsesPrincipalCapAndCreditsPrincipal() public {
        escrow.setCaps(CAP_THOR, 100 ether);
        uint256 amountIn = 125 ether;
        uint256 principal = 100 ether;
        _approveAndFund(user, yThor, amountIn);

        vm.expectEmit(true, false, false, true);
        emit ThorMigrationEscrow.MigratedYThor(user, amountIn, principal);
        vm.prank(user);
        escrow.migrateYThor(amountIn);

        assertEq(escrow.migratedYThor(), principal);
        assertEq(escrow.capYThor(), principal);
        assertEq(xmetro.lastYThorUser(), user);
        assertEq(xmetro.lastYThorPrincipal(), principal);

        vm.prank(user);
        vm.expectRevert(ThorMigrationEscrow.YThorCapExceeded.selector);
        escrow.migrateYThor(1 ether);
        assertEq(xmetro.yThorCredits(), 1);
    }

    function test_ThorAndYThorRepeatedMigrationsAreIndependent() public {
        _approveAndFund(user, thor, 20 ether);
        _approveAndFund(user, yThor, 20 ether);
        for (uint256 i; i < 2; ++i) {
            vm.prank(user);
            escrow.migrateThor(10 ether);
            vm.prank(user);
            escrow.migrateYThor(10 ether);
        }
        assertEq(xmetro.thorCredits(), 2);
        assertEq(xmetro.yThorCredits(), 2);
        assertEq(escrow.migratedThor(), 22 ether);
        assertEq(escrow.migratedYThor(), 16 ether);
    }

    function test_DifferentAddressesHaveIndependentCredits() public {
        _approveAndFund(user, thor, 1 ether);
        _approveAndFund(user2, thor, 2 ether);

        vm.prank(user);
        escrow.migrateThor(1 ether);
        vm.prank(user2);
        escrow.migrateThor(2 ether);

        assertEq(xmetro.thorCredits(), 2);
    }

    function test_MigrationIsAllowedExactlyAtStartAndDeadline() public {
        uint256 startTime = block.timestamp + 1 days;
        uint256 deadline = startTime + 1 days;
        ThorMigrationEscrow bounded =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), startTime);
        bounded.setCaps(10 ether, 10 ether);
        bounded.setRatios(1e18, 1e18);
        bounded.setDeadlines(deadline, deadline);

        thor.mint(user, 1 ether);
        yThor.mint(user2, 1 ether);
        vm.prank(user);
        thor.approve(address(bounded), 1 ether);
        vm.prank(user2);
        yThor.approve(address(bounded), 1 ether);

        vm.warp(startTime);
        vm.prank(user);
        bounded.migrateThor(1 ether);
        assertEq(bounded.migratedThor(), 1 ether);

        vm.warp(deadline);
        vm.prank(user2);
        bounded.migrateYThor(1 ether);
        assertEq(bounded.migratedYThor(), 1 ether);
    }

    function test_FailedTokenTransferDoesNotConsumeCreditOrCap() public {
        thor.mint(user, 10 ether);

        vm.prank(user);
        vm.expectRevert();
        escrow.migrateThor(10 ether);

        assertEq(xmetro.thorCredits(), 0);
        assertEq(escrow.migratedThor(), 0);
        assertEq(thor.balanceOf(address(escrow)), 0);
    }

    function test_FailedXMetroCreditRollsBackTokensCreditAndCap() public {
        _approveAndFund(user, yThor, 10 ether);
        xmetro.setRevertCredits(true);

        vm.prank(user);
        vm.expectRevert(bytes("MockXMetro: rejected"));
        escrow.migrateYThor(10 ether);

        assertEq(xmetro.yThorCredits(), 0);
        assertEq(escrow.migratedYThor(), 0);
        assertEq(yThor.balanceOf(user), 10 ether);
        assertEq(yThor.balanceOf(address(escrow)), 0);
    }

    function test_MigrationValidationStartDeadlineCapZeroAndZeroMint() public {
        ThorMigrationEscrow future =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp + 1 days);
        future.setCaps(1 ether, 1 ether);
        future.setRatios(1e18, 1e18);
        future.setDeadlines(block.timestamp + 2 days, block.timestamp + 2 days);

        vm.expectRevert(ThorMigrationEscrow.MigrationNotStarted.selector);
        future.migrateThor(1);
        vm.expectRevert(ThorMigrationEscrow.MigrationNotStarted.selector);
        future.migrateYThor(0);

        vm.expectRevert(ThorMigrationEscrow.ZeroAmount.selector);
        escrow.migrateThor(0);
        vm.expectRevert(ThorMigrationEscrow.ZeroAmount.selector);
        escrow.migrateYThor(0);

        ThorMigrationEscrow noConfig =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp);
        vm.expectRevert(ThorMigrationEscrow.ThorConfigurationMissing.selector);
        noConfig.migrateThor(1);
        vm.expectRevert(ThorMigrationEscrow.YThorConfigurationMissing.selector);
        noConfig.migrateYThor(1);

        ThorMigrationEscrow tinyRatio =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp);
        tinyRatio.setCaps(1 ether, 1 ether);
        tinyRatio.setRatios(1, 1);
        tinyRatio.setDeadlines(block.timestamp + 1 days, block.timestamp + 1 days);
        thor.mint(user, 1);
        vm.prank(user);
        thor.approve(address(tinyRatio), 1);
        vm.prank(user);
        vm.expectRevert(ThorMigrationEscrow.ZeroMintAmount.selector);
        tinyRatio.migrateThor(1);
        vm.expectRevert(ThorMigrationEscrow.ZeroMintAmount.selector);
        tinyRatio.migrateYThor(1);

        escrow.setCaps(1 ether, 1 ether);
        _approveAndFund(user, thor, 2 ether);
        vm.prank(user);
        vm.expectRevert(ThorMigrationEscrow.ThorCapExceeded.selector);
        escrow.migrateThor(2 ether);

        uint256 deadline = block.timestamp + 1;
        escrow.setDeadlines(deadline, deadline);
        vm.warp(deadline + 1);
        vm.prank(user2);
        vm.expectRevert(ThorMigrationEscrow.ThorMigrationExpired.selector);
        escrow.migrateThor(1);
        vm.prank(user2);
        vm.expectRevert(ThorMigrationEscrow.YThorMigrationExpired.selector);
        escrow.migrateYThor(1);
        assertEq(xmetro.yThorCredits(), 0);
    }

    function test_CapsRemainOwnerConfigurableAfterMigration() public {
        _approveAndFund(user, thor, 10 ether);
        vm.prank(user);
        escrow.migrateThor(10 ether);

        uint256 migrated = escrow.migratedThor();
        escrow.setCaps(migrated - 1, CAP_YTHOR);
        assertEq(escrow.capThor(), migrated - 1);
        assertEq(escrow.migratedThor(), migrated);
    }

    function test_PauseAndRescueProtections() public {
        vm.prank(user);
        vm.expectRevert();
        escrow.pause();

        escrow.pause();
        _approveAndFund(user, thor, 1 ether);
        vm.prank(user);
        vm.expectRevert();
        escrow.migrateThor(1 ether);
        escrow.unpause();

        other.mint(address(escrow), 100);
        vm.expectRevert(ThorMigrationEscrow.MigrationTokenRescueForbidden.selector);
        escrow.rescueTokens(address(thor), user, 1);
        vm.expectRevert(ThorMigrationEscrow.MigrationTokenRescueForbidden.selector);
        escrow.rescueTokens(address(yThor), user, 1);
        vm.expectRevert(ThorMigrationEscrow.InvalidRecipient.selector);
        escrow.rescueTokens(address(other), address(0), 1);

        vm.expectEmit(true, true, false, true);
        emit ThorMigrationEscrow.TokensRescued(address(other), user, 40);
        escrow.rescueTokens(address(other), user, 40);
        assertEq(other.balanceOf(user), 40);
    }

    function test_FailedLaterCreditPreservesEarlierMigration() public {
        _approveAndFund(user, thor, 20 ether);
        vm.prank(user);
        escrow.migrateThor(10 ether);
        xmetro.setRevertCredits(true);
        vm.prank(user);
        vm.expectRevert(bytes("MockXMetro: rejected"));
        escrow.migrateThor(10 ether);
        assertEq(xmetro.thorCredits(), 1);
        assertEq(escrow.migratedThor(), 11 ether);
        assertEq(thor.balanceOf(user), 10 ether);
        assertEq(thor.balanceOf(address(escrow)), 10 ether);
    }
}
