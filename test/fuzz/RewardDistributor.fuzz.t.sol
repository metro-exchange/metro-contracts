// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {MetroToken} from "../../src/metro.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";

contract RewardDistributorFuzzTest is Test {
    ERC20Mintable internal usdc;
    MetroToken internal metro;
    xMETRO internal xmetro;
    RewardDistributor internal distributor;
    MockCommissionVault internal vault;
    address internal operator = makeAddr("operator");
    address internal user = makeAddr("user");

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        xmetro = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);
        distributor = new RewardDistributor(address(xmetro), address(this));
        vault = new MockCommissionVault(address(usdc), 0, address(distributor));
        distributor.setOperator(operator, true);
        distributor.setCommissionVault(address(vault));
        xmetro.setRewardDistributor(address(distributor));

        metro.mint(user, 100 ether);
        vm.prank(user);
        metro.approve(address(xmetro), 100 ether);
        vm.prank(user);
        xmetro.stake(100 ether);
    }

    function testFuzz_GrossAlwaysEqualsCommissionPlusNetAndObeysBothBounds(
        uint128 grossSeed,
        uint16 bpsSeed,
        uint128 shortfallSeed
    ) public {
        uint256 gross = bound(uint256(grossSeed), 1, 1e30);
        uint16 bps = uint16(bound(uint256(bpsSeed), 0, 10_000));
        uint256 shortfall = bound(uint256(shortfallSeed), 0, 1e30);
        vault.setTargetBalance(shortfall);
        distributor.setMaxCommissionSplitBps(bps);

        uint256 cap = Math.mulDiv(gross, bps, 10_000);
        uint256 expectedCommission = Math.min(cap, shortfall);
        uint256 expectedNet = gross - expectedCommission;
        usdc.mint(operator, gross);
        vm.prank(operator);
        usdc.approve(address(distributor), gross);
        vm.prank(operator);
        distributor.distribute(gross);

        assertEq(usdc.balanceOf(address(vault)), expectedCommission);
        assertEq(usdc.balanceOf(address(xmetro)), expectedNet);
        assertEq(expectedCommission + expectedNet, gross);
        assertLe(expectedCommission, cap);
        assertLe(expectedCommission, shortfall);
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
    }

    function testFuzz_DistributeFromBalanceUsesIdenticalFormula(
        uint128 grossSeed,
        uint16 bpsSeed,
        uint128 shortfallSeed
    ) public {
        uint256 gross = bound(uint256(grossSeed), 1, 1e30);
        uint16 bps = uint16(bound(uint256(bpsSeed), 0, 10_000));
        uint256 shortfall = bound(uint256(shortfallSeed), 0, 1e30);
        vault.setTargetBalance(shortfall);
        distributor.setMaxCommissionSplitBps(bps);
        usdc.mint(address(distributor), gross);

        vm.prank(operator);
        distributor.distributeFromBalance(gross);
        uint256 expectedCommission = Math.min(Math.mulDiv(gross, bps, 10_000), shortfall);
        assertEq(usdc.balanceOf(address(vault)), expectedCommission);
        assertEq(usdc.balanceOf(address(xmetro)), gross - expectedCommission);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function testFuzz_RolloverAcrossManyDistributionsNeedsNoDistributorAccounting(
        uint96 grossSeed,
        uint16 bpsSeed,
        uint96 targetSeed,
        uint8 roundsSeed
    ) public {
        uint256 gross = bound(uint256(grossSeed), 1, 1e24);
        uint16 bps = uint16(bound(uint256(bpsSeed), 1, 10_000));
        uint256 target = bound(uint256(targetSeed), 0, 1e25);
        uint256 rounds = bound(uint256(roundsSeed), 1, 20);
        vault.setTargetBalance(target);
        distributor.setMaxCommissionSplitBps(bps);
        uint256 totalGross = gross * rounds;
        usdc.mint(operator, totalGross);
        vm.prank(operator);
        usdc.approve(address(distributor), totalGross);

        uint256 expectedVault;
        uint256 cap = Math.mulDiv(gross, bps, 10_000);
        for (uint256 i; i < rounds; i++) {
            uint256 remaining = target > expectedVault ? target - expectedVault : 0;
            expectedVault += Math.min(cap, remaining);
            vm.prank(operator);
            distributor.distribute(gross);
        }

        assertEq(usdc.balanceOf(address(vault)), expectedVault);
        assertEq(usdc.balanceOf(address(xmetro)), totalGross - expectedVault);
        assertEq(vault.requiredTopUp(), target - expectedVault);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }
}
