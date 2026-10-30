// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    CompactAdapterFlowBase,
    CompactV2Router,
    CompactV3Router,
    CompactOneInchRouter,
    CompactOneInchExecutor,
    CompactPermissiveOneInchRouter,
    CompactFlowToken
} from "./XMetroDeFiAdapter.flows.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOneInchAggregationRouterV6, XMetroDeFiAdapter} from "../../src/XMetroDeFiAdapter.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";

contract CompactAdapterFuzzTest is CompactAdapterFlowBase {
    CompactV2Router internal routerV2;
    CompactV3Router internal routerV3;
    CompactOneInchRouter internal oneInch;
    CompactFlowToken internal output;
    bytes32 internal strategy;

    function setUp() public override {
        super.setUp();
        routerV2 = new CompactV2Router();
        routerV3 = new CompactV3Router();
        oneInch = new CompactOneInchRouter();
        output = new CompactFlowToken("Fuzz Output", "FOUT", 6);
        adapter.setRouters(address(routerV2), address(routerV3), address(oneInch));
        strategy = adapter.setSwapTokenConfig(address(output), true, true);
        core.setPaused(false);
    }

    function testFuzz_SwapRewardInputCapBoundary(uint96 seed, uint8 dexSeed, uint8 boundarySeed) public {
        uint256 amount = bound(uint256(seed), 2, 1e24);
        uint8 dex = dexSeed % 3;
        uint8 boundary = boundarySeed % 3;
        uint256 cap = boundary == 0 ? amount - 1 : boundary == 1 ? amount : amount + 1;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
        bytes memory route = dex == 0
            ? abi.encode(path)
            : dex == 1 ? abi.encodePacked(address(usdc), uint24(500), address(output)) : _validOneInchRoute(amount);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: makeAddr("cap-boundary"),
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(dex, cap, route)
        });
        usdc.mint(address(core), amount);
        usdc.mint(address(adapter), 13);
        output.mint(address(adapter), 17);
        if (boundary == 0) vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        assertEq(usdc.balanceOf(address(core)), boundary == 0 ? amount : 0);
        assertEq(output.balanceOf(request.account), boundary == 0 ? 0 : amount);
        assertEq(usdc.balanceOf(address(adapter)), 13);
        assertEq(output.balanceOf(address(adapter)), 17);
        assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
        assertEq(usdc.allowance(address(adapter), address(routerV3)), 0);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function testFuzz_BatchDistributionPreservesDonationsAndConservesEveryUnit(
        uint96 firstSeed,
        uint96 secondSeed,
        uint96 thirdSeed,
        uint64 inputDonationSeed,
        uint64 outputDonationSeed
    ) public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = bound(uint256(firstSeed), 1, 1e24);
        amounts[1] = bound(uint256(secondSeed), 1, 1e24);
        amounts[2] = bound(uint256(thirdSeed), 1, 1e24);
        uint256 total = amounts[0] + amounts[1] + amounts[2];
        uint256 inputDonation = bound(uint256(inputDonationSeed), 0, 1e18);
        uint256 outputDonation = bound(uint256(outputDonationSeed), 0, 1e18);

        address[] memory users = new address[](3);
        users[0] = makeAddr("fuzz-a");
        users[1] = makeAddr("fuzz-b");
        users[2] = makeAddr("fuzz-c");
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);

        usdc.mint(address(adapter), inputDonation);
        output.mint(address(adapter), outputDonation);
        usdc.mint(address(core), total);
        IXMetroDeFiAdapter.BatchExecution memory request = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: users,
            amountsIn: amounts,
            minTotalAmountOut: total,
            minUserAmountsOut: new uint256[](0),
            deadline: block.timestamp + 1,
            executionData: _swapData(0, total, abi.encode(path))
        });
        IXMetroDeFiAdapter.ExecutionResult memory result = core.runBatch(usdc, request);

        assertEq(result.amountIn, total);
        assertEq(result.amountOut, total);
        assertEq(output.balanceOf(users[0]), amounts[0]);
        assertEq(output.balanceOf(users[1]), amounts[1]);
        assertEq(output.balanceOf(users[2]), amounts[2]);
        assertEq(usdc.balanceOf(address(adapter)), inputDonation);
        assertEq(output.balanceOf(address(adapter)), outputDonation);
        assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
    }

    function testFuzz_StrategyRevisionAdvancesExactlyOncePerSemanticToggle(uint8 toggleSeed) public {
        core.setPaused(true);
        uint256 toggles = bound(uint256(toggleSeed), 1, 32);
        bool enabled = true;
        for (uint256 i; i < toggles; ++i) {
            enabled = !enabled;
            adapter.setSwapTokenConfig(address(output), enabled, enabled);
        }
        IXMetroDeFiAdapter.StrategyInfo memory info = adapter.strategyInfo(strategy);
        assertEq(info.strategyRevision, 1 + toggles);
        assertEq(info.enabled, enabled);
        assertEq(info.autoEnabled, enabled);
        assertEq(info.logicEpoch, 1);
        assertEq(info.domainRevision, 2);
    }

    /// @dev A non-1:1 quote exercises integer remainders, largest-user dust allocation and token decimals.
    function testFuzz_BatchUnequalQuoteDistributesEveryOutputUnit(
        uint64 distributionSeed,
        uint8 countSeed,
        uint16 rateSeed,
        uint8 decimalsSeed
    ) public {
        uint256 count = bound(uint256(countSeed), 2, 8);
        uint256 rate = bound(uint256(rateSeed), 200, 9_900);
        uint8 decimals = decimalsSeed % 3 == 0 ? 6 : decimalsSeed % 3 == 1 ? 8 : 18;
        CompactFlowToken variedOutput = new CompactFlowToken("Varied Output", "VOUT", decimals);
        bytes32 variedStrategy = adapter.setSwapTokenConfig(address(variedOutput), true, true);
        CompactOneInchExecutor executor = new CompactOneInchExecutor();
        oneInch.setBehavior(10_000, rate, 0, address(0));

        address[] memory accounts = new address[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 totalIn;
        uint256 largest;
        for (uint256 i; i < count; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode(distributionSeed, i))) | 1));
            amounts[i] = bound(uint256(keccak256(abi.encode(distributionSeed, i, "amount"))), 100_000, 1e10);
            if (amounts[i] > amounts[largest]) largest = i;
            totalIn += amounts[i];
        }
        uint256 totalOut = Math.mulDiv(totalIn, rate, 10_000);
        uint256 donation = 17;
        variedOutput.mint(address(adapter), donation);
        usdc.mint(address(core), totalIn);

        IOneInchAggregationRouterV6.SwapDescription memory description = IOneInchAggregationRouterV6.SwapDescription({
            srcToken: IERC20(address(usdc)),
            dstToken: IERC20(address(variedOutput)),
            srcReceiver: payable(address(executor)),
            dstReceiver: payable(address(adapter)),
            amount: totalIn,
            minReturnAmount: 1,
            flags: 0
        });
        IXMetroDeFiAdapter.BatchExecution memory request = IXMetroDeFiAdapter.BatchExecution({
            strategyId: variedStrategy,
            accounts: accounts,
            amountsIn: amounts,
            minTotalAmountOut: 1,
            minUserAmountsOut: new uint256[](0),
            deadline: block.timestamp + 1,
            executionData: _swapData(
                2,
                totalIn,
                abi.encodeWithSelector(
                    IOneInchAggregationRouterV6.swap.selector, address(executor), description, hex"01"
                )
            )
        });
        IXMetroDeFiAdapter.ExecutionResult memory result = core.runBatch(usdc, request);
        assertEq(result.amountIn, totalIn);
        assertEq(result.amountOut, totalOut);
        uint256 distributed;
        for (uint256 i; i < count; ++i) {
            if (i != largest) distributed += Math.mulDiv(totalOut, amounts[i], totalIn);
        }
        for (uint256 i; i < count; ++i) {
            uint256 expected = i == largest ? totalOut - distributed : Math.mulDiv(totalOut, amounts[i], totalIn);
            assertEq(variedOutput.balanceOf(accounts[i]), expected);
        }
        assertEq(variedOutput.balanceOf(address(adapter)), donation);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function test_BatchRejectsZeroOutputForDustUserAtomically() public {
        CompactOneInchExecutor executor = new CompactOneInchExecutor();
        oneInch.setBehavior(10_000, 100, 0, address(0));
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("dust-user");
        accounts[1] = makeAddr("large-user");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1e6;
        uint256 total = amounts[0] + amounts[1];
        IOneInchAggregationRouterV6.SwapDescription memory description = IOneInchAggregationRouterV6.SwapDescription({
            srcToken: IERC20(address(usdc)),
            dstToken: IERC20(address(output)),
            srcReceiver: payable(address(executor)),
            dstReceiver: payable(address(adapter)),
            amount: total,
            minReturnAmount: 1,
            flags: 0
        });
        IXMetroDeFiAdapter.BatchExecution memory request = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: accounts,
            amountsIn: amounts,
            minTotalAmountOut: 1,
            minUserAmountsOut: new uint256[](0),
            deadline: block.timestamp + 1,
            executionData: _swapData(
                2,
                total,
                abi.encodeWithSelector(
                    IOneInchAggregationRouterV6.swap.selector, address(executor), description, hex"01"
                )
            )
        });
        usdc.mint(address(core), total);
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runBatch(usdc, request);
        assertEq(usdc.balanceOf(address(core)), total);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(output.balanceOf(accounts[0]) + output.balanceOf(accounts[1]), 0);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function testFuzz_OneInchTruncatedHeaderNeverReachesRouter(uint16 cutSeed) public {
        CompactPermissiveOneInchRouter permissive = new CompactPermissiveOneInchRouter(usdc, output);
        adapter.setRouters(address(routerV2), address(routerV3), address(permissive));
        bytes memory route = _validOneInchRoute(100e6);
        uint256 cut = bound(uint256(cutSeed), 0, 4 + 9 * 32 - 1);
        assembly ("memory-safe") { mstore(route, cut) }
        _assertMalformedOneInchAtomic(route, permissive);
    }

    function testFuzz_OneInchOverflowingDynamicOffsetNeverReachesRouter(uint64 offsetSeed, bool overflow) public {
        CompactPermissiveOneInchRouter permissive = new CompactPermissiveOneInchRouter(usdc, output);
        adapter.setRouters(address(routerV2), address(routerV3), address(permissive));
        bytes memory route = _validOneInchRoute(100e6);
        uint256 offset = overflow ? type(uint256).max - uint256(offsetSeed) : route.length + uint256(offsetSeed) + 1;
        assembly ("memory-safe") { mstore(add(add(route, 32), 260), offset) }
        _assertMalformedOneInchAtomic(route, permissive);
    }

    function _validOneInchRoute(uint256 amount) private returns (bytes memory) {
        CompactOneInchExecutor executor = new CompactOneInchExecutor();
        IOneInchAggregationRouterV6.SwapDescription memory description = IOneInchAggregationRouterV6.SwapDescription({
            srcToken: IERC20(address(usdc)),
            dstToken: IERC20(address(output)),
            srcReceiver: payable(address(executor)),
            dstReceiver: payable(address(adapter)),
            amount: amount,
            minReturnAmount: amount,
            flags: 0
        });
        return
            abi.encodeWithSelector(IOneInchAggregationRouterV6.swap.selector, address(executor), description, hex"01");
    }

    function _assertMalformedOneInchAtomic(bytes memory route, CompactPermissiveOneInchRouter permissive) private {
        uint256 amount = 100e6;
        address account = makeAddr("malformed-fuzz-user");
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: account,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: _swapData(2, amount, route)
        });
        vm.expectRevert();
        core.runManual(usdc, request);
        assertEq(usdc.balanceOf(address(core)), amount);
        assertEq(usdc.balanceOf(address(permissive)), 0);
        assertEq(output.balanceOf(account), 0);
        assertEq(usdc.allowance(address(adapter), address(permissive)), 0);
    }
}
