// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";

import {MetroToken} from "../../src/metro.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";

contract MetroTokenFuzzTest is Test {
    uint256 internal constant CAP = 100_000_000 ether;
    address internal minterA = makeAddr("minterA");
    address internal minterB = makeAddr("minterB");
    address internal user = makeAddr("user");

    function testFuzz_ImmutableCapAndMultipleMintersNeverExceedIt(uint128 firstSeed) public {
        uint256 first = bound(uint256(firstSeed), 0, CAP);
        MetroToken metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(minterA, true);
        metro.setMinter(minterB, true);

        if (first != 0) {
            vm.prank(minterA);
            metro.mint(user, first);
        }
        uint256 remaining = CAP - first;
        if (remaining != 0) {
            vm.prank(minterB);
            metro.mint(user, remaining);
        }

        assertEq(metro.cap(), CAP);
        assertEq(metro.totalSupply(), CAP);
        vm.prank(minterA);
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, CAP + 1, CAP));
        metro.mint(user, 1);
        assertLe(metro.totalSupply(), metro.cap());
    }

    function testFuzz_MintRespectsAllowlist(address minter, address to, uint96 amount, bool allowed) public {
        vm.assume(minter != address(0));
        vm.assume(to != address(0));
        uint256 value = bound(uint256(amount), 1, CAP);
        MetroToken metro = new MetroToken("METRO", "METRO", address(this));
        if (allowed) metro.setMinter(minter, true);

        vm.prank(minter);
        if (!allowed) {
            vm.expectRevert(MetroToken.UnauthorizedMinter.selector);
            metro.mint(to, value);
            return;
        }
        metro.mint(to, value);
        assertEq(metro.balanceOf(to), value);
    }

    function test_DeadAddressTransferNeverRestoresMintCapacity() public {
        MetroToken metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        metro.mint(user, CAP);
        vm.prank(user);
        metro.transfer(0x000000000000000000000000000000000000dEaD, CAP);

        assertEq(metro.totalSupply(), CAP);
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, CAP + 1, CAP));
        metro.mint(user, 1);
    }
}
