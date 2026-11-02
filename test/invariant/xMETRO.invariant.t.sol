// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {MetroToken} from "../../src/metro.sol";
import {xMETRO as XMetroCore} from "../../src/xMETRO.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";

contract xMETROInvariantTest is StdInvariant, Test {
    MetroToken internal metro;
    ERC20Mintable internal usdc;
    XMetroCore internal xmetro;
    xMETROHandlerV2 internal handler;

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        xmetro = new XMetroCore(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);

        address[] memory actors = new address[](4);
        for (uint256 i; i < actors.length; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
        }
        actors[0] = xmetro.migrationRewardExcludedAddress();
        handler = new xMETROHandlerV2(xmetro, metro, usdc, actors);

        usdc.transferOwnership(address(handler));
        metro.setMinter(address(handler), true);
        metro.setMinter(address(xmetro), true);
        xmetro.setMigrationEscrow(address(handler));
        xmetro.setRewardDistributor(address(handler));
        xmetro.setContributor(address(handler), true);
        xmetro.transferOwnership(address(handler));
        vm.prank(address(handler));
        xmetro.acceptOwnership();
        assertEq(xmetro.pendingOwner(), address(0));
        assertEq(xmetro.owner(), address(handler));

        handler.setYThorRewardWeight(10_000);
        assertEq(xmetro.yThorRewardWeightBps(), 10_000);

        // Seed successful excluded migrations and both exit modes before random operations.
        handler.creditThor(0, 100 ether);
        handler.creditYThor(0, 100 ether);
        handler.stake(0, 10 ether);
        handler.stake(1, 10 ether);
        handler.depositRewards(20e6);
        handler.claimRewards(0);
        handler.advanceTime(120 days);
        handler.exitThor(0, 0, false);
        handler.exitYThor(0, 0, true);
        handler.creditThor(0, 10 ether);
        handler.creditYThor(0, 10 ether);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.creditThor.selector;
        selectors[2] = handler.creditYThor.selector;
        selectors[3] = handler.stakeContributor.selector;
        selectors[4] = handler.transferShares.selector;
        selectors[5] = handler.requestFreeUnstake.selector;
        selectors[6] = handler.exitThor.selector;
        selectors[7] = handler.exitYThor.selector;
        selectors[8] = handler.claimContributorAsShares.selector;
        selectors[9] = handler.requestContributor.selector;
        selectors[10] = handler.withdrawQueues.selector;
        selectors[11] = handler.depositRewards.selector;
        selectors[12] = handler.advanceTime.selector;
        selectors[13] = handler.claimRewards.selector;
        selectors[14] = handler.setYThorRewardWeight.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_GlobalAndPerUserRewardWeightFormulaAlwaysHolds() public view {
        uint256 sumShares;
        uint256 sumLocked;
        uint256 sumActiveYThor;
        uint256 excludedThor;
        uint256 excludedYThor;
        uint256 weightBps = xmetro.yThorRewardWeightBps();
        for (uint256 i; i < handler.actorsLength(); i++) {
            address actor = handler.actorAt(i);
            uint256 activePrincipal = _activeYThorPrincipal(actor);
            bool excluded = actor == xmetro.migrationRewardExcludedAddress();
            uint256 activeThor;
            if (excluded) {
                for (uint256 id; id < xmetro.thorPositionCount(actor); ++id) {
                    (uint128 principal,,, bool exited) = xmetro.thorPositions(actor, id);
                    if (!exited) activeThor += principal;
                }
                excludedThor += activeThor;
                excludedYThor += activePrincipal;
                assertLe(activeThor + activePrincipal, xmetro.lockedShares(actor));
            }
            assertEq(
                xmetro.rewardWeightOf(actor),
                xmetro.balanceOf(actor) + xmetro.lockedShares(actor) - activePrincipal - activeThor
                    + (excluded ? 0 : activePrincipal * weightBps / 10_000)
            );
            sumShares += xmetro.totalSharesOf(actor);
            sumLocked += xmetro.lockedShares(actor);
            sumActiveYThor += activePrincipal;
        }
        assertEq(xmetro.totalShares(), xmetro.totalSupply() + xmetro.totalLockedShares());
        assertEq(xmetro.totalShares(), sumShares);
        assertEq(xmetro.totalLockedShares(), sumLocked);
        assertEq(
            xmetro.totalRewardWeight(),
            xmetro.totalShares() - sumActiveYThor - excludedThor + (sumActiveYThor - excludedYThor) * weightBps / 10_000
        );
    }

    function invariant_PositionCountsMatchSuccessfulCredits() public view {
        for (uint256 i; i < handler.actorsLength(); i++) {
            address actor = handler.actorAt(i);
            assertEq(xmetro.thorPositionCount(actor), handler.thorCredits(actor));
            assertEq(xmetro.yThorPositionCount(actor), handler.yThorCredits(actor));
        }
    }

    function invariant_RealMetroBackingEqualsSharesPlusOutstandingCooldowns() public view {
        uint256 outstanding;
        for (uint256 i; i < handler.actorsLength(); i++) {
            address actor = handler.actorAt(i);
            outstanding += _outstandingFree(actor);
            outstanding += _outstandingThor(actor);
            outstanding += _outstandingYThor(actor);
            outstanding += _outstandingContributor(actor);
        }
        assertEq(metro.balanceOf(address(xmetro)), xmetro.totalShares() + outstanding);
    }

    function invariant_MetroSupplyNeverExceedsCap() public view {
        assertLe(metro.totalSupply(), metro.cap());
    }

    function invariant_ClaimedRewardsAndContractBalanceMatchDeposits() public view {
        assertGt(handler.totalRewardsDeposited(), 0);
        assertGt(handler.totalRewardsClaimed(), 0);
        uint256 payableRewards;
        for (uint256 i; i < handler.actorsLength(); ++i) {
            payableRewards += xmetro.claimable(handler.actorAt(i));
        }
        assertLe(payableRewards, usdc.balanceOf(address(xmetro)));
        assertEq(handler.unexpectedClaimFailures(), 0);
        assertLe(handler.totalRewardsClaimed(), handler.totalRewardsDeposited());
        assertEq(handler.totalRewardsDeposited(), handler.totalRewardsClaimed() + usdc.balanceOf(address(xmetro)));
    }

    function invariant_EachMigrationPositionCanExitAtMostOnce() public view {
        for (uint256 i; i < handler.actorsLength(); i++) {
            address actor = handler.actorAt(i);
            for (uint256 j; j < xmetro.thorPositionCount(actor); ++j) {
                (,,, bool exited) = xmetro.thorPositions(actor, j);
                assertEq(handler.thorExitSuccesses(actor, j), exited ? 1 : 0);
            }
            for (uint256 j; j < xmetro.yThorPositionCount(actor); ++j) {
                (,,, bool exited) = xmetro.yThorPositions(actor, j);
                assertEq(handler.yThorExitSuccesses(actor, j), exited ? 1 : 0);
            }
        }
        assertEq(handler.unexpectedExitFailures(), 0);
    }

    function _activeYThorPrincipal(address actor) internal view returns (uint256 total) {
        for (uint256 i; i < xmetro.yThorPositionCount(actor); ++i) {
            (uint128 principal,,, bool exited) = xmetro.yThorPositions(actor, i);
            if (!exited) total += principal;
        }
    }

    function _outstandingFree(address actor) internal view returns (uint256 amount) {
        for (uint256 i = xmetro.unstakeCursorFree(actor); i < xmetro.unstakeRequestCountFree(actor); i++) {
            amount += xmetro.unstakeRequestFree(actor, i).amount;
        }
    }

    function _outstandingThor(address actor) internal view returns (uint256 amount) {
        for (uint256 i = xmetro.unstakeCursorThor(actor); i < xmetro.unstakeRequestCountThor(actor); i++) {
            amount += xmetro.unstakeRequestThor(actor, i).amount;
        }
    }

    function _outstandingYThor(address actor) internal view returns (uint256 amount) {
        for (uint256 i = xmetro.unstakeCursorYThor(actor); i < xmetro.unstakeRequestCountYThor(actor); i++) {
            amount += xmetro.unstakeRequestYThor(actor, i).amount;
        }
    }

    function _outstandingContributor(address actor) internal view returns (uint256 amount) {
        for (uint256 i = xmetro.unstakeCursorContributor(actor); i < xmetro.unstakeRequestCountContributor(actor); i++) {
            amount += xmetro.unstakeRequestContributor(actor, i).amount;
        }
    }
}

contract xMETROHandlerV2 is Test {
    XMetroCore internal immutable xmetro;
    MetroToken internal immutable metro;
    ERC20Mintable internal immutable usdc;
    address[] internal actors;
    uint256 public totalRewardsDeposited;
    uint256 public totalRewardsClaimed;
    mapping(address => mapping(uint256 => uint256)) public thorExitSuccesses;
    mapping(address => mapping(uint256 => uint256)) public yThorExitSuccesses;
    mapping(address => uint256) public thorCredits;
    mapping(address => uint256) public yThorCredits;
    uint256 public unexpectedClaimFailures;
    uint256 public unexpectedExitFailures;

    constructor(XMetroCore xmetro_, MetroToken metro_, ERC20Mintable usdc_, address[] memory actors_) {
        xmetro = xmetro_;
        metro = metro_;
        usdc = usdc_;
        actors = actors_;
        usdc.approve(address(xmetro_), type(uint256).max);
        metro.approve(address(xmetro_), type(uint256).max);
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function xMETRO() external view returns (address) {
        return address(xmetro);
    }

    function rewardToken() external view returns (address) {
        return address(usdc);
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 actorSeed, uint96 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(amountSeed), 1, 1_000 ether);
        metro.mint(actor, amount);
        vm.prank(actor);
        metro.approve(address(xmetro), amount);
        vm.prank(actor);
        xmetro.stake(amount);
    }

    function creditThor(uint256 actorSeed, uint96 amountSeed) external {
        address actor = _actor(actorSeed);
        if (xmetro.thorPositionCount(actor) >= 20) return;
        thorCredits[actor]++;
        xmetro.creditThorFromMigration(actor, bound(uint256(amountSeed), 1, 1_000 ether));
    }

    function creditYThor(uint256 actorSeed, uint96 amountSeed) external {
        address actor = _actor(actorSeed);
        if (xmetro.yThorPositionCount(actor) >= 20) return;
        yThorCredits[actor]++;
        uint256 amount = bound(uint256(amountSeed), 1, 1_000 ether);
        xmetro.creditYThorFromMigration(actor, amount);
    }

    function stakeContributor(uint256 actorSeed, uint96 amountSeed) external {
        address receiver = _actor(actorSeed);
        if (xmetro.contributorVestingCount(receiver) >= 20) return;
        uint256 amount = bound(uint256(amountSeed), 1, 1_000 ether);
        metro.mint(address(this), amount);
        xmetro.stakeContributor(amount, receiver);
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint96 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = xmetro.balanceOf(from);
        if (from == to || balance == 0) return;
        uint256 amount = bound(uint256(amountSeed), 0, balance);
        vm.prank(from);
        xmetro.transfer(to, amount);
    }

    function requestFreeUnstake(uint256 actorSeed, uint96 amountSeed) external {
        address actor = _actor(actorSeed);
        if (xmetro.unstakeRequestCountFree(actor) >= 30) return;
        uint256 balance = xmetro.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, balance);
        vm.prank(actor);
        xmetro.requestUnstake(amount);
    }

    function exitThor(uint256 actorSeed, uint256 positionSeed, bool stakeMode) external {
        address actor = _actor(actorSeed);
        uint256 count = xmetro.thorPositionCount(actor);
        if (count == 0) return;
        uint256 id = positionSeed % count;
        (bool eligible,,,,) = xmetro.previewThorExit(actor, id);
        if (!eligible) return;
        vm.prank(actor);
        bool ok;
        if (stakeMode) (ok,) = address(xmetro).call(abi.encodeCall(XMetroCore.exitAndStakeThor, (id)));
        else (ok,) = address(xmetro).call(abi.encodeCall(XMetroCore.requestThorExit, (id)));
        if (ok) thorExitSuccesses[actor][id]++;
        else unexpectedExitFailures++;
    }

    function exitYThor(uint256 actorSeed, uint256 positionSeed, bool stakeMode) external {
        address actor = _actor(actorSeed);
        uint256 count = xmetro.yThorPositionCount(actor);
        if (count == 0) return;
        uint256 id = positionSeed % count;
        (bool eligible,,,,) = xmetro.previewYThorExit(actor, id);
        if (!eligible) return;
        vm.prank(actor);
        bool ok;
        (ok,) = address(xmetro)
            .call(
                abi.encodeCall(
                    XMetroCore.exitYThor, (id, stakeMode ? XMetroCore.ExitMode.Stake : XMetroCore.ExitMode.Liquid)
                )
            );
        if (ok) yThorExitSuccesses[actor][id]++;
        else unexpectedExitFailures++;
    }

    function claimContributorAsShares(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        address(xmetro).call(abi.encodeCall(XMetroCore.claimAndStakeUnlockedContributor, (uint256(0))));
    }

    function requestContributor(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (xmetro.unstakeRequestCountContributor(actor) >= 30) return;
        vm.prank(actor);
        address(xmetro).call(abi.encodeCall(XMetroCore.requestWithdrawUnlockedContributor, (uint256(0))));
    }

    function withdrawQueues(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.startPrank(actor);
        address(xmetro).call(abi.encodeCall(XMetroCore.withdrawFree, (uint256(0))));
        address(xmetro).call(abi.encodeCall(XMetroCore.withdrawThor, (uint256(0))));
        address(xmetro).call(abi.encodeCall(XMetroCore.withdrawYThor, (uint256(0))));
        address(xmetro).call(abi.encodeCall(XMetroCore.withdrawContributor, (uint256(0))));
        vm.stopPrank();
    }

    function depositRewards(uint96 amountSeed) external {
        if (xmetro.totalRewardWeight() == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, 1_000_000e6);
        if (amount * 1e24 < xmetro.totalRewardWeight()) return;
        usdc.mint(address(this), amount);
        xmetro.depositRewards(amount);
        totalRewardsDeposited += amount;
    }

    function claimRewards(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try xmetro.claimRewards() returns (uint256 paid) {
            totalRewardsClaimed += paid;
        } catch {
            unexpectedClaimFailures++;
        }
    }

    function setYThorRewardWeight(uint16 weightSeed) external {
        xmetro.setYThorRewardWeightBps(bound(uint256(weightSeed), 0, 50_000));
    }

    function advanceTime(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(uint256(secondsSeed), 0, 200 days));
    }
}
