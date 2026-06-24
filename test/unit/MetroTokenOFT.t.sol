// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title MetroToken.t.sol
 * @notice Unit tests for `MetroToken`.
 */

import "forge-std/Test.sol";

import { MetroToken } from "../../src/metro.sol";

contract MetroTokenTest is Test {
    MetroToken internal metro;

    // Test addresses.
    address internal owner = address(this);
    address internal newOwner = makeAddr("newOwner");
    address internal minter = makeAddr("minter");
    address internal user = makeAddr("user");
    uint256 internal alicePk = 0xA11CE;
    address internal alice;

    function setUp() public {
        metro = new MetroToken("METRO", "METRO", owner);
        alice = vm.addr(alicePk);
    }

    function test_SetMinter_OnlyOwner() public {
        vm.prank(user);
        vm.expectRevert();
        metro.setMinter(minter, true);

        metro.setMinter(minter, true);
        assertTrue(metro.isMinter(minter));
    }

    function test_Mint_OnlyMinter() public {
        vm.expectRevert(bytes("MetroToken: not minter"));
        metro.mint(user, 1 ether);
        assertEq(metro.balanceOf(user), 0);

        vm.prank(user);
        vm.expectRevert(bytes("MetroToken: not minter"));
        metro.mint(user, 1);

        metro.setMinter(owner, true);
        metro.mint(user, 1 ether);
        assertEq(metro.balanceOf(user), 1 ether);

        metro.setMinter(minter, true);
        vm.prank(minter);
        metro.mint(user, 2 ether);
        assertEq(metro.balanceOf(user), 3 ether);
    }

    function test_Constructor_SetsOwnerAndDefaultMinter() public {
        assertEq(metro.owner(), owner);

        assertTrue(!metro.isMinter(owner));

        assertEq(metro.name(), "METRO");
        assertEq(metro.symbol(), "METRO");
        assertEq(metro.decimals(), 18);
    }

    function test_SetMinter_EmitsEvent_AndToggle() public {
        vm.expectEmit(true, false, false, true);
        emit MetroToken.MinterStatusUpdated(minter, true);
        metro.setMinter(minter, true);
        assertTrue(metro.isMinter(minter));

        vm.expectEmit(true, false, false, true);
        emit MetroToken.MinterStatusUpdated(minter, false);
        metro.setMinter(minter, false);
        assertTrue(!metro.isMinter(minter));
    }

    function test_TransferOwnership_ChangesOnlyOwnerPermissions() public {
        metro.transferOwnership(newOwner);
        assertEq(metro.owner(), newOwner);

        vm.expectRevert();
        metro.setMinter(minter, true);

        vm.prank(newOwner);
        metro.setMinter(minter, true);
        assertTrue(metro.isMinter(minter));
    }

    function test_TransferOwnership_DoesNotAutoGrantMinterToNewOwner() public {
        metro.transferOwnership(newOwner);
        assertEq(metro.owner(), newOwner);

        assertTrue(!metro.isMinter(newOwner));

        vm.prank(newOwner);
        metro.setMinter(newOwner, true);
        assertTrue(metro.isMinter(newOwner));

        vm.prank(newOwner);
        metro.mint(user, 1 ether);
        assertEq(metro.balanceOf(user), 1 ether);
    }

    function test_RenounceOwnership_DisablesOnlyOwner_ButDoesNotRevokeMinter() public {
        metro.setMinter(owner, true);
        assertTrue(metro.isMinter(owner));

        metro.renounceOwnership();
        assertEq(metro.owner(), address(0));

        vm.expectRevert();
        metro.setMinter(minter, true);

        assertTrue(metro.isMinter(owner));
        metro.mint(user, 1 ether);
        assertEq(metro.balanceOf(user), 1 ether);
    }

    function test_Permit_Success_SetsAllowance_AndIncrementsNonce() public {
        metro.setMinter(owner, true);
        metro.mint(alice, 10 ether);
        assertEq(metro.balanceOf(alice), 10 ether);

        address spender = makeAddr("spender");
        uint256 value = 3 ether;
        uint256 nonce = metro.nonces(alice);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 typehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(typehash, alice, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", metro.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        vm.prank(user);
        metro.permit(alice, spender, value, deadline, v, r, s);

        assertEq(metro.allowance(alice, spender), value);
        assertEq(metro.nonces(alice), nonce + 1);

        vm.prank(spender);
        metro.transferFrom(alice, user, value);
        assertEq(metro.balanceOf(user), value);
        assertEq(metro.balanceOf(alice), 10 ether - value);
    }

    function test_Permit_ReplaySignature_RevertsInvalidSigner() public {
        metro.setMinter(owner, true);
        metro.mint(alice, 1 ether);

        address spender = makeAddr("spender");
        uint256 value = 1 ether;
        uint256 nonce = metro.nonces(alice);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 typehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(typehash, alice, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", metro.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);

        metro.permit(alice, spender, value, deadline, v, r, s);
        assertEq(metro.nonces(alice), nonce + 1);

        bytes4 invalidSignerSelector = bytes4(keccak256("ERC2612InvalidSigner(address,address)"));
        uint256 nonce2 = metro.nonces(alice);
        bytes32 structHash2 = keccak256(abi.encode(typehash, alice, spender, value, nonce2, deadline));
        bytes32 digest2 = keccak256(abi.encodePacked("\x19\x01", metro.DOMAIN_SEPARATOR(), structHash2));
        address recoveredSigner = ecrecover(digest2, v, r, s);
        vm.expectRevert(abi.encodeWithSelector(invalidSignerSelector, recoveredSigner, alice));
        metro.permit(alice, spender, value, deadline, v, r, s);
    }

    function test_Permit_Expired_Reverts() public {
        uint256 deadline = block.timestamp - 1;
        bytes4 expiredSelector = bytes4(keccak256("ERC2612ExpiredSignature(uint256)"));

        vm.expectRevert(abi.encodeWithSelector(expiredSelector, deadline));
        metro.permit(alice, user, 1, deadline, 0, bytes32(0), bytes32(0));
    }

    function test_DomainSeparator_NotZero() public {
        assertTrue(metro.DOMAIN_SEPARATOR() != bytes32(0));
    }
}
