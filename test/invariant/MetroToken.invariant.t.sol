// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {MetroToken} from "../../src/metro.sol";

contract MetroTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant CAP = 100_000_000 ether;
    MetroToken internal metro;
    MetroTokenHandler internal handler;

    function setUp() public {
        metro = new MetroToken("METRO", "METRO", address(this));
        address[] memory actors = new address[](4);
        for (uint256 i; i < actors.length; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        handler = new MetroTokenHandler(metro, actors);
        metro.transferOwnership(address(handler));
        targetContract(address(handler));
    }

    function invariant_TotalSupplyNeverExceedsImmutableCap() public view {
        assertLe(metro.totalSupply(), metro.cap());
        assertEq(metro.cap(), CAP);
    }

    function invariant_TotalSupplyEqualsTrackedActorBalances() public view {
        uint256 total;
        for (uint256 i; i < handler.actorsLength(); i++) {
            total += metro.balanceOf(handler.actorAt(i));
        }
        assertEq(metro.totalSupply(), total);
    }
}

contract MetroTokenHandler is Test {
    MetroToken internal immutable metro;
    address[] internal actors;
    mapping(address => bool) internal allowed;

    constructor(MetroToken metro_, address[] memory actors_) {
        metro = metro_;
        actors = actors_;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function setMinter(uint256 seed, bool value) external {
        address actor = actors[seed % actors.length];
        if (allowed[actor] == value) return;
        metro.setMinter(actor, value);
        allowed[actor] = value;
    }

    function mint(uint256 minterSeed, uint256 recipientSeed, uint256 amountSeed) external {
        address minter = actors[minterSeed % actors.length];
        if (!allowed[minter]) return;
        uint256 remaining = metro.cap() - metro.totalSupply();
        if (remaining == 0) return;
        uint256 amount = bound(amountSeed, 1, remaining);
        vm.prank(minter);
        metro.mint(actors[recipientSeed % actors.length], amount);
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        if (from == to || metro.balanceOf(from) == 0) return;
        uint256 amount = bound(amountSeed, 0, metro.balanceOf(from));
        vm.prank(from);
        metro.transfer(to, amount);
    }
}
