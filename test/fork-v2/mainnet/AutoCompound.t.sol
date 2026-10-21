// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase, IUniswapV2RouterMainnet} from "./MainnetForkBase.sol";

contract AutoCompoundMainnetTest is MainnetForkBase {
    address private alice;
    address private bob;
    address private carol;
    address private outsider;
    address private pair;

    event AutoCompounded(address indexed user, uint256 usdcIn, uint256 metroOut);
    event AutocompoundBatchExecuted(address indexed operator, uint256 totalUsdcIn, uint256 totalMetroOut);

    function setUp() public {
        _fork();
        _deploySystem();
        _configureSwaps();
        core.unpause();
        pair = _createMetroPool(10_000 ether, 10_000e6);
        alice = makeAddr("compound-alice");
        bob = makeAddr("compound-bob");
        carol = makeAddr("compound-carol");
        outsider = makeAddr("compound-outsider");
    }

    function _route() internal view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(metro);
        return abi.encode(uint8(0), abi.encode(path));
    }

    function _quote(uint256 amount) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(metro);
        return IUniswapV2RouterMainnet(V2_ROUTER).getAmountsOut(amount, path)[1];
    }

    function _one(address user) internal pure returns (address[] memory users) {
        users = new address[](1);
        users[0] = user;
    }

    function _three() internal view returns (address[] memory users) {
        users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
    }

    function _prepareThree() internal {
        _mintAndStake(alice, 20 ether);
        _mintAndStake(bob, 30 ether);
        _mintAndStake(carol, 50 ether);
        vm.prank(alice);
        core.enableAutocompound();
        vm.prank(bob);
        core.enableAutocompound();
        vm.prank(carol);
        core.enableAutocompound();
        _distribute(100e6);
        assertEq(core.claimable(alice), 20e6);
        assertEq(core.claimable(bob), 30e6);
        assertEq(core.claimable(carol), 50e6);
    }

    /// E-07.01/.04: Tests manual real V2 and backing event allowance.
    function test_E07_ManualRealV2AndBackingEventAllowance() public {
        _mintAndStake(alice, 100 ether);
        _distribute(100e6);
        uint256 expected = _quote(100e6);
        uint256 sharesBefore = core.balanceOf(alice);
        uint256 coreMetroBefore = metro.balanceOf(address(core));
        uint256 pairUsdcBefore = IERC20(USDC).balanceOf(pair);
        vm.expectEmit(true, false, false, true, address(core));
        emit AutoCompounded(alice, 100e6, expected);
        vm.prank(alice);
        uint256 received = core.autocompound(expected, block.timestamp + 1 hours, _route());
        assertEq(received, expected);
        assertEq(core.balanceOf(alice) - sharesBefore, received);
        assertEq(metro.balanceOf(address(core)) - coreMetroBefore, received);
        assertEq(IERC20(USDC).balanceOf(pair) - pairUsdcBefore, 100e6);
        assertEq(core.claimable(alice), 0);
        assertEq(IERC20(USDC).balanceOf(proxy), 0);
        assertEq(metro.balanceOf(proxy), 0);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
    }

    /// E-07.02: Tests manual independent of auto preference.
    function test_E07_ManualIndependentOfAutoPreference() public {
        _mintAndStake(alice, 100 ether);
        _distribute(30e6);
        assertFalse(core.autocompoundEnabled(alice));
        uint256 firstQuote = _quote(30e6);
        vm.prank(alice);
        assertEq(core.autocompound(firstQuote, block.timestamp + 1 hours, _route()), firstQuote);
        assertFalse(core.autocompoundEnabled(alice));
        vm.prank(alice);
        core.enableAutocompound();
        uint256 shares = core.balanceOf(alice);
        uint256 secondScaled = shares * (20e6 * 1e24 / shares);
        uint256 secondPending = secondScaled / 1e24;
        _distribute(20e6);
        assertEq(core.claimable(alice), secondPending);
        uint256 secondQuote = _quote(secondPending);
        vm.prank(alice);
        assertEq(core.autocompound(secondQuote, block.timestamp + 1 hours, _route()), secondQuote);
        assertTrue(core.autocompoundEnabled(alice));
        vm.prank(alice);
        core.disableAutocompound();
        shares = core.balanceOf(alice);
        uint256 thirdPending = (secondScaled % 1e24 + shares * (10e6 * 1e24 / shares)) / 1e24;
        _distribute(10e6);
        assertEq(core.claimable(alice), thirdPending);
        assertEq(IERC20(USDC).balanceOf(address(core)), 30e6 - secondPending);
        assertLe(thirdPending, IERC20(USDC).balanceOf(address(core)));
        uint256 thirdQuote = _quote(thirdPending);
        vm.prank(alice);
        assertEq(core.autocompound(thirdQuote, block.timestamp + 1 hours, _route()), thirdQuote);
        assertFalse(core.autocompoundEnabled(alice));
        assertEq(core.claimable(alice), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 30e6 - secondPending - thirdPending);
    }

    /// E-07.03: Tests enable disable and mutual preference.
    function test_E07_EnableDisableAndMutualPreference() public {
        bytes32 swapUsdt = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(USDT, true, true);
        vm.prank(alice);
        core.enableAutocompound();
        assertTrue(core.autocompoundEnabled(alice));
        bytes32 compoundId =
            keccak256(abi.encode(block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), uint8(1), address(metro)));
        assertEq(core.getAutoStrategyPreference(alice).strategyId, compoundId);
        vm.prank(alice);
        core.enableAutoStrategy(swapUsdt);
        assertFalse(core.autocompoundEnabled(alice));
        assertEq(core.getAutoStrategyPreference(alice).strategyId, swapUsdt);
        vm.prank(alice);
        core.enableAutocompound();
        assertTrue(core.autocompoundEnabled(alice));
        core.pause();
        vm.prank(alice);
        vm.expectRevert();
        core.enableAutocompound();
        vm.prank(alice);
        core.disableAutocompound();
        assertFalse(core.autocompoundEnabled(alice));
        assertEq(core.getAutoStrategyPreference(alice).strategyId, bytes32(0));
    }

    /// E-07.05: Tests manual failures preserve pending and funds.
    function test_E07_ManualFailuresPreservePendingAndFunds() public {
        _mintAndStake(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert();
        core.autocompound(1, block.timestamp + 1 hours, _route());
        _distribute(100e6);
        uint256 beforeCore = IERC20(USDC).balanceOf(address(core));
        vm.prank(alice);
        vm.expectRevert();
        core.autocompound(type(uint256).max, block.timestamp + 1 hours, _route());
        vm.prank(alice);
        vm.expectRevert();
        core.autocompound(1, block.timestamp, _route());
        address[] memory wrong = new address[](2);
        wrong[0] = address(metro);
        wrong[1] = USDC;
        vm.prank(alice);
        vm.expectRevert();
        core.autocompound(1, block.timestamp + 1 hours, abi.encode(uint8(0), abi.encode(wrong)));
        assertEq(core.claimable(alice), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), beforeCore);
        assertEq(IERC20(USDC).balanceOf(proxy), 0);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
        assertEq(core.balanceOf(alice), 100 ether);
    }

    /// E-08.01: Tests keeper grant and revoke.
    function test_E08_KeeperGrantAndRevoke() public {
        _prepareThree();
        vm.prank(outsider);
        vm.expectRevert();
        core.autocompoundBatch(_three(), 1, block.timestamp + 1 hours, _route());
        core.setAutoCompoundOperator(address(this), false);
        vm.expectRevert();
        core.autocompoundBatch(_three(), 1, block.timestamp + 1 hours, _route());
        assertEq(core.claimable(alice), 20e6);
        core.setAutoCompoundOperator(address(this), true);
        uint256 expected = _quote(100e6);
        assertEq(core.autocompoundBatch(_three(), 1, block.timestamp + 1 hours, _route()), expected);
    }

    /// E-08.02/.04: Tests one real swap pro rata and largest remainder.
    function test_E08_OneRealSwapProRataAndLargestRemainder() public {
        _prepareThree();
        uint256 expected = _quote(100e6);
        uint256 beforeCoreMetro = metro.balanceOf(address(core));
        uint256 beforeAlice = core.balanceOf(alice);
        uint256 beforeBob = core.balanceOf(bob);
        uint256 beforeCarol = core.balanceOf(carol);
        vm.recordLogs();
        uint256 received = core.autocompoundBatch(_three(), expected, block.timestamp + 1 hours, _route());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(received, expected);
        uint256 aliceAdded = core.balanceOf(alice) - beforeAlice;
        uint256 bobAdded = core.balanceOf(bob) - beforeBob;
        uint256 carolAdded = core.balanceOf(carol) - beforeCarol;
        assertEq(aliceAdded, received * 20 / 100);
        assertEq(bobAdded, received * 30 / 100);
        assertEq(carolAdded, received - aliceAdded - bobAdded);
        assertEq(aliceAdded + bobAdded + carolAdded, received);
        assertEq(metro.balanceOf(address(core)) - beforeCoreMetro, received);
        assertEq(core.claimable(alice) + core.claimable(bob) + core.claimable(carol), 0);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
        uint256 pairSwapCount;
        uint256 autoEventCount;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == pair && logs[i].topics.length != 0
                    && logs[i].topics[0] == keccak256("Swap(address,uint256,uint256,uint256,uint256,address)")
            ) ++pairSwapCount;
            if (
                logs[i].emitter == address(core) && logs[i].topics.length != 0
                    && logs[i].topics[0] == AutoCompounded.selector
            ) ++autoEventCount;
        }
        assertEq(pairSwapCount, 1);
        assertEq(autoEventCount, 3);
        assertEq(_batchEventTotal(logs), received);
    }

    /// E-08.03: Tests filter candidates and version expiry.
    function test_E08_FilterCandidatesAndVersionExpiry() public {
        _mintAndStake(alice, 20 ether);
        _mintAndStake(bob, 30 ether);
        _mintAndStake(carol, 50 ether);
        _mintAndStake(outsider, 10 ether);
        vm.prank(alice);
        core.enableAutocompound();
        vm.prank(bob);
        core.enableAutocompound();
        vm.prank(carol);
        core.enableAutocompound();
        _distribute(110e6);
        address[] memory candidates = new address[](8);
        candidates[0] = address(0);
        candidates[1] = alice;
        candidates[2] = alice;
        candidates[3] = bob;
        candidates[4] = carol;
        candidates[5] = makeAddr("zero-pending");
        candidates[6] = outsider;
        candidates[7] = address(0);
        uint256 expected = _quote(100e6);
        assertEq(core.autocompoundBatch(candidates, 1, block.timestamp + 1 hours, _route()), expected);
        assertEq(core.claimable(alice), 0);
        assertEq(core.claimable(bob), 0);
        assertEq(core.claimable(carol), 0);
        assertEq(core.claimable(outsider), 10e6);
        vm.expectRevert();
        core.autocompoundBatch(new address[](0), 1, block.timestamp + 1 hours, _route());
        vm.expectRevert();
        core.autocompoundBatch(_three(), 1, block.timestamp + 1 hours, _route());
        _distribute(110e6);
        uint256 pendingAlice = core.claimable(alice);
        uint256 pendingBob = core.claimable(bob);
        uint256 pendingCarol = core.claimable(carol);
        IXMetroAdapterAdminFork(proxy).setSwapMetroConfig(false, false);
        IXMetroAdapterAdminFork(proxy).setSwapMetroConfig(true, true);
        vm.expectRevert();
        core.autocompoundBatch(_three(), 1, block.timestamp + 1 hours, _route());
        assertEq(core.claimable(alice), pendingAlice);
        assertEq(core.claimable(bob), pendingBob);
        assertEq(core.claimable(carol), pendingCarol);
    }

    /// E-08.04: Tests zero rounded share reverts atomically.
    function test_E08_ZeroRoundedShareRevertsAtomically() public {
        // Use a new pool with little METRO and ample real USDC so one micro-USDC yields under one wei.
        _fork();
        _deploySystem();
        _configureSwaps();
        core.unpause();
        address tinyPair = _createMetroPool(1e9, 10_000e6);
        assertGt(tinyPair.code.length, 0);
        _mintAndStake(alice, 1e12);
        _mintAndStake(bob, 100 ether);
        vm.prank(alice);
        core.enableAutocompound();
        vm.prank(bob);
        core.enableAutocompound();
        _distribute(100e6 + 1);
        assertEq(core.claimable(alice), 1);
        assertEq(core.claimable(bob), 100e6);
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        uint256 pairBefore = IERC20(USDC).balanceOf(tinyPair);
        vm.expectRevert();
        core.autocompoundBatch(users, 1, block.timestamp + 1 hours, _route());
        assertEq(core.claimable(alice), 1);
        assertEq(core.claimable(bob), 100e6);
        assertEq(IERC20(USDC).balanceOf(tinyPair), pairBefore);
    }

    /// E-08.05: Tests batch rollback and single user equivalence.
    function test_E08_BatchRollbackAndSingleUserEquivalence() public {
        _mintAndStake(alice, 100 ether);
        vm.prank(alice);
        core.enableAutocompound();
        _distribute(100e6);
        vm.expectRevert();
        core.autocompoundBatch(_one(alice), type(uint256).max, block.timestamp + 1 hours, _route());
        assertEq(core.claimable(alice), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
        uint256 snapshot = vm.snapshotState();
        uint256 batchOut = core.autocompoundBatch(_one(alice), 1, block.timestamp + 1 hours, _route());
        assertTrue(vm.revertToState(snapshot));
        vm.prank(alice);
        uint256 manualOut = core.autocompound(1, block.timestamp + 1 hours, _route());
        assertEq(batchOut, manualOut);
    }

    function test_E08_ThreeUserFailureLeavesEveryPendingUntouched() public {
        _prepareThree();
        uint256 pairUsdcBefore = IERC20(USDC).balanceOf(pair);
        uint256 aliceShares = core.balanceOf(alice);
        uint256 bobShares = core.balanceOf(bob);
        uint256 carolShares = core.balanceOf(carol);
        vm.expectRevert();
        core.autocompoundBatch(_three(), type(uint256).max, block.timestamp + 1 hours, _route());
        assertEq(core.claimable(alice), 20e6);
        assertEq(core.claimable(bob), 30e6);
        assertEq(core.claimable(carol), 50e6);
        assertEq(core.balanceOf(alice), aliceShares);
        assertEq(core.balanceOf(bob), bobShares);
        assertEq(core.balanceOf(carol), carolShares);
        assertEq(IERC20(USDC).balanceOf(pair), pairUsdcBefore);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(USDC).balanceOf(proxy), 0);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
    }

    function _batchEventTotal(Vm.Log[] memory logs) private view returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(core) && logs[i].topics.length != 0
                    && logs[i].topics[0] == AutocompoundBatchExecuted.selector
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(this));
                (uint256 totalUsdc, uint256 totalMetro) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(totalUsdc, 100e6);
                return totalMetro;
            }
        }
        revert("batch event missing");
    }
}
