// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

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

    function _approveAndFund(address account, ERC20Mintable token, uint256 amount) internal {
        token.mint(account, amount);
        vm.prank(account);
        token.approve(address(escrow), amount);
    }

    function test_ConstructorRejectsInvalidInputs() public {
        vm.expectRevert(bytes("ThorEscrow: zero xMETRO"));
        new ThorMigrationEscrow(owner, address(0), address(thor), address(yThor), block.timestamp);

        vm.expectRevert(bytes("ThorEscrow: zero token"));
        new ThorMigrationEscrow(owner, address(xmetro), address(0), address(yThor), block.timestamp);

        vm.warp(100);
        vm.expectRevert(bytes("ThorEscrow: bad start time"));
        new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp - 1);
    }

    function test_BaseQaZeroStartUsesDeploymentTimestamp() public {
        ThorMigrationEscrow immediate =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), 0);
        assertEq(immediate.migrationStartTime(), block.timestamp);
        immediate.setDeadlines(block.timestamp + 1 days, block.timestamp + 2 days);
        assertEq(immediate.deadlineThor(), block.timestamp + 1 days);
        assertEq(immediate.deadlineYThor(), block.timestamp + 2 days);
    }

    function test_ConfigurationPermissionsValidationAndEvents() public {
        ThorMigrationEscrow fresh =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp + 10);

        vm.prank(user);
        vm.expectRevert();
        fresh.setCaps(1, 1);

        vm.expectRevert(bytes("ThorEscrow: bad cap"));
        fresh.setCaps(0, 1);
        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.CapsUpdated(10, 20);
        fresh.setCaps(10, 20);

        vm.expectRevert(bytes("ThorEscrow: bad ratio"));
        fresh.setRatios(0, 1e18);
        vm.expectEmit(false, false, false, true);
        emit ThorMigrationEscrow.RatiosUpdated(2e18, 3e18);
        fresh.setRatios(2e18, 3e18);
        vm.expectRevert(bytes("ThorEscrow: ratios locked"));
        fresh.setRatios(1e18, 1e18);

        vm.expectRevert(bytes("ThorEscrow: deadline before start"));
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
        vm.expectRevert(bytes("ThorEscrow: ythor cap"));
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

        vm.expectRevert(bytes("ThorEscrow: not started"));
        future.migrateThor(1);

        vm.expectRevert(bytes("ThorEscrow: zero amount"));
        escrow.migrateThor(0);
        vm.expectRevert(bytes("ThorEscrow: zero amount"));
        escrow.migrateYThor(0);

        ThorMigrationEscrow noConfig =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp);
        vm.expectRevert(bytes("ThorEscrow: thor config not set"));
        noConfig.migrateThor(1);

        ThorMigrationEscrow tinyRatio =
            new ThorMigrationEscrow(owner, address(xmetro), address(thor), address(yThor), block.timestamp);
        tinyRatio.setCaps(1 ether, 1 ether);
        tinyRatio.setRatios(1, 1);
        tinyRatio.setDeadlines(block.timestamp + 1 days, block.timestamp + 1 days);
        thor.mint(user, 1);
        vm.prank(user);
        thor.approve(address(tinyRatio), 1);
        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: zero mint"));
        tinyRatio.migrateThor(1);

        escrow.setCaps(1 ether, 1 ether);
        _approveAndFund(user, thor, 2 ether);
        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: thor cap"));
        escrow.migrateThor(2 ether);

        uint256 deadline = block.timestamp + 1;
        escrow.setDeadlines(deadline, deadline);
        vm.warp(deadline + 1);
        vm.prank(user2);
        vm.expectRevert(bytes("ThorEscrow: thor expired"));
        escrow.migrateThor(1);
        vm.prank(user2);
        vm.expectRevert(bytes("ThorEscrow: ythor expired"));
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
        vm.expectRevert(bytes("ThorEscrow: cannot rescue migration tokens"));
        escrow.rescueTokens(address(thor), user, 1);
        vm.expectRevert(bytes("ThorEscrow: cannot rescue migration tokens"));
        escrow.rescueTokens(address(yThor), user, 1);
        vm.expectRevert(bytes("ThorEscrow: bad to"));
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
