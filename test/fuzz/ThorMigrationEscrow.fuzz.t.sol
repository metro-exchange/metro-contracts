// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ThorMigrationEscrow} from "../../src/ThorMigrationEscrow.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";

contract MockXMetroMigrationFuzzV2 {
    address public thorUser;
    uint256 public thorPrincipal;
    address public yThorUser;
    uint256 public yThorPrincipal;

    function creditThorFromMigration(address user, uint256 principal) external {
        thorUser = user;
        thorPrincipal = principal;
    }

    function creditYThorFromMigration(address user, uint256 principal) external {
        yThorUser = user;
        yThorPrincipal = principal;
    }
}

contract ThorMigrationEscrowFuzzTest is Test {
    ERC20Mintable internal thor;
    ERC20Mintable internal yThor;
    MockXMetroMigrationFuzzV2 internal xmetro;
    ThorMigrationEscrow internal escrow;
    address internal user = makeAddr("user");

    function setUp() public {
        thor = new ERC20Mintable("THOR", "THOR", 18);
        yThor = new ERC20Mintable("yTHOR", "yTHOR", 18);
        xmetro = new MockXMetroMigrationFuzzV2();
        escrow = new ThorMigrationEscrow(address(this), address(xmetro), address(thor), address(yThor), block.timestamp);
        escrow.setCaps(1_000_000 ether, 1_000_000 ether);
        escrow.setRatios(1e18, 1e18);
        escrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
    }

    function testFuzz_UnifiedThorMigrationPrincipalAndOnce(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000 ether);
        thor.mint(user, amount * 2);
        vm.prank(user);
        thor.approve(address(escrow), type(uint256).max);

        vm.prank(user);
        escrow.migrateThor(amount);
        assertEq(escrow.migratedThor(), amount);
        assertEq(xmetro.thorUser(), user);
        assertEq(xmetro.thorPrincipal(), amount);
        assertTrue(escrow.hasMigratedThor(user));

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: thor already migrated"));
        escrow.migrateThor(amount);
    }

    function testFuzz_RandomAmountAndRatioUseFullPrecisionMath(uint128 amountSeed, uint128 ratioSeed, bool migrateY)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 1, 1e30);
        uint256 ratio = bound(uint256(ratioSeed), 1, 1e30);
        uint256 principal = Math.mulDiv(amount, ratio, 1e18);
        vm.assume(principal > 0 && principal <= type(uint128).max);

        ThorMigrationEscrow fresh =
            new ThorMigrationEscrow(address(this), address(xmetro), address(thor), address(yThor), block.timestamp);
        fresh.setCaps(principal, principal);
        fresh.setRatios(ratio, ratio);
        fresh.setDeadlines(block.timestamp + 1 days, block.timestamp + 1 days);

        ERC20Mintable token = migrateY ? yThor : thor;
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(fresh), amount);
        vm.prank(user);
        if (migrateY) fresh.migrateYThor(amount);
        else fresh.migrateThor(amount);

        if (migrateY) {
            assertEq(fresh.migratedYThor(), principal);
            assertEq(xmetro.yThorPrincipal(), principal);
        } else {
            assertEq(fresh.migratedThor(), principal);
            assertEq(xmetro.thorPrincipal(), principal);
        }
    }

    function testFuzz_YThorCapCountsPrincipal(uint96 rawPrincipal) public {
        uint256 principal = bound(uint256(rawPrincipal), 1, 1_000_000 ether);
        escrow.setCaps(1_000_000 ether, principal);
        yThor.mint(user, principal);
        vm.prank(user);
        yThor.approve(address(escrow), principal);
        vm.prank(user);
        escrow.migrateYThor(principal);

        assertEq(escrow.migratedYThor(), principal);
        assertEq(escrow.capYThor(), principal);
        assertEq(xmetro.yThorPrincipal(), principal);
    }

    function testFuzz_CapFailureLeavesBalanceCountersAndOnceFlagUnchanged(uint96 capSeed, uint96 extraSeed) public {
        uint256 cap = bound(uint256(capSeed), 1, 1_000_000 ether);
        uint256 extra = bound(uint256(extraSeed), 1, 1_000_000 ether);
        escrow.setCaps(cap, 1_000_000 ether);
        uint256 amount = cap + extra;
        thor.mint(user, amount);
        vm.prank(user);
        thor.approve(address(escrow), amount);

        vm.prank(user);
        vm.expectRevert(bytes("ThorEscrow: thor cap"));
        escrow.migrateThor(amount);
        assertEq(escrow.migratedThor(), 0);
        assertFalse(escrow.hasMigratedThor(user));
        assertEq(thor.balanceOf(user), amount);
        assertEq(thor.balanceOf(address(escrow)), 0);
    }
}
