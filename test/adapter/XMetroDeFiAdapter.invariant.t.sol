// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    CompactFlowToken,
    CompactFlowCore,
    CompactV2Router,
    CompactV3Router,
    CompactOneInchRouter
} from "./XMetroDeFiAdapter.flows.t.sol";
import {XMetroDeFiAdapter} from "../../src/XMetroDeFiAdapter.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";

contract CompactAdapterInvariantHandler is Test {
    CompactFlowToken public immutable usdc;
    CompactFlowToken public immutable output;
    CompactFlowCore public immutable core;
    IXMetroDeFiAdapter public immutable adapter;
    bytes32 public immutable strategy;
    address[3] internal users;
    uint256 public totalInput;
    uint256 public totalOutput;
    uint256 internal operationCount;

    constructor(
        CompactFlowToken usdc_,
        CompactFlowToken output_,
        CompactFlowCore core_,
        IXMetroDeFiAdapter adapter_,
        bytes32 strategy_
    ) {
        usdc = usdc_;
        output = output_;
        core = core_;
        adapter = adapter_;
        strategy = strategy_;
        users[0] = makeAddr("invariant-a");
        users[1] = makeAddr("invariant-b");
        users[2] = makeAddr("invariant-c");
    }

    function manual(uint96 amountSeed) external {
        uint256 amount = bound(uint256(amountSeed), 1, 1e24);
        address account = users[operationCount % users.length];
        ++operationCount;
        address[] memory path = _path();
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: account,
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), amount, abi.encode(path))
        });
        core.runManual(usdc, request);
        totalInput += amount;
        totalOutput += amount;
    }

    function batch(uint64 firstSeed, uint64 secondSeed, uint64 thirdSeed) external {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = bound(uint256(firstSeed), 1, 1e18);
        amounts[1] = bound(uint256(secondSeed), 1, 1e18);
        amounts[2] = bound(uint256(thirdSeed), 1, 1e18);
        uint256 total = amounts[0] + amounts[1] + amounts[2];
        address[] memory accounts = new address[](3);
        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = users[i];
        }
        address[] memory path = _path();
        usdc.mint(address(core), total);
        IXMetroDeFiAdapter.BatchExecution memory request = IXMetroDeFiAdapter.BatchExecution({
            strategyId: strategy,
            accounts: accounts,
            amountsIn: amounts,
            minTotalAmountOut: total,
            minUserAmountsOut: new uint256[](0),
            deadline: block.timestamp + 1,
            executionData: abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), total, abi.encode(path))
        });
        core.runBatch(usdc, request);
        totalInput += total;
        totalOutput += total;
    }

    function staleQuoteThenRetry(uint96 amountSeed) external {
        uint256 amount = bound(uint256(amountSeed), 2, 1e24);
        usdc.mint(address(core), amount);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution({
            strategyId: strategy,
            account: users[0],
            amountIn: amount,
            minAmountOut: amount,
            deadline: block.timestamp + 1,
            executionData: abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), amount - 1, abi.encode(_path()))
        });
        uint256 coreBefore = usdc.balanceOf(address(core));
        vm.expectRevert(XMetroDeFiAdapter.InvalidExecutionRequest.selector);
        core.runManual(usdc, request);
        assertEq(usdc.balanceOf(address(core)), coreBefore);
        request.executionData = abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), amount, abi.encode(_path()));
        core.runManual(usdc, request);
        totalInput += amount;
        totalOutput += amount;
    }

    function user(uint256 index) external view returns (address) {
        return users[index];
    }

    function _path() private view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(output);
    }
}

contract CompactAdapterInvariantTest is StdInvariant, Test {
    uint256 internal constant INPUT_DONATION = 13e6;
    uint256 internal constant OUTPUT_DONATION = 17e6;

    CompactFlowToken internal usdc;
    CompactFlowToken internal metro;
    CompactFlowToken internal output;
    CompactFlowCore internal core;
    CompactV2Router internal routerV2;
    XMetroDeFiAdapter internal adapter;
    CompactAdapterInvariantHandler internal handler;
    bytes32 internal strategy;

    function setUp() public {
        usdc = new CompactFlowToken("USD Coin", "USDC", 6);
        metro = new CompactFlowToken("Metro", "METRO", 18);
        output = new CompactFlowToken("Invariant Output", "IOUT", 6);
        core = new CompactFlowCore(address(this));
        routerV2 = new CompactV2Router();
        CompactV3Router routerV3 = new CompactV3Router();
        CompactOneInchRouter oneInch = new CompactOneInchRouter();

        bytes memory implementationInit = vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter");
        address implementation = _create(implementationInit);
        bytes memory initData =
            abi.encodeCall(XMetroDeFiAdapter.initialize, (address(core), address(usdc), address(metro)));
        address proxy = address(new ERC1967Proxy(implementation, initData));
        core.setAdapter(proxy);
        adapter = XMetroDeFiAdapter(proxy);
        adapter.setRouters(address(routerV2), address(routerV3), address(oneInch));
        strategy = adapter.setSwapTokenConfig(address(output), true, true);
        usdc.mint(proxy, INPUT_DONATION);
        output.mint(proxy, OUTPUT_DONATION);
        core.setPaused(false);

        handler = new CompactAdapterInvariantHandler(usdc, output, core, adapter, strategy);
        targetContract(address(handler));
    }

    function invariant_AdapterBalancesAndAllowanceReturnToTheirPreexistingBaselines() public view {
        assertEq(usdc.balanceOf(address(adapter)), INPUT_DONATION);
        assertEq(output.balanceOf(address(adapter)), OUTPUT_DONATION);
        assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
    }

    function invariant_AllSuccessfulInputAndOutputUnitsAreConserved() public view {
        assertEq(handler.totalInput(), handler.totalOutput());
        assertEq(usdc.balanceOf(address(routerV2)), handler.totalInput());
        uint256 userOutput;
        for (uint256 i; i < 3; ++i) {
            userOutput += output.balanceOf(handler.user(i));
        }
        assertEq(userOutput, handler.totalOutput());
    }

    function invariant_BindingsAndStrategyVersionNeverDriftDuringExecution() public view {
        assertEq(adapter.xMETRO(), address(core));
        assertEq(adapter.USDC(), address(usdc));
        assertEq(adapter.METRO(), address(metro));
        assertEq(adapter.logicEpoch(), 1);
        IXMetroDeFiAdapter.StrategyInfo memory info = adapter.strategyInfo(strategy);
        assertTrue(info.enabled);
        assertTrue(info.autoEnabled);
        assertEq(info.domainRevision, 2);
        assertEq(info.strategyRevision, 1);
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        require(deployed != address(0));
    }
}
