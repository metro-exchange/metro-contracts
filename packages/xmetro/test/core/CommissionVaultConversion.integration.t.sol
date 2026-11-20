// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {xMETRO} from "../../src/xMETRO.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {CommissionVault} from "../fork-v2/mainnet/vendor/CommissionVault.sol";
import {CoreCode, CoreFlowToken, CoreV2Router, ICoreAdapterConfiguration} from "./XMetroCore.adapter.t.sol";

contract CommissionVaultConversionIntegrationTest is Test {
    CoreFlowToken metro;
    CoreFlowToken usdc;
    CoreFlowToken output;
    xMETRO core;
    CommissionVault vault;
    IXMetroDeFiAdapter adapter;
    bytes32 swapMetroId;
    bytes32 autoSwapId;

    address operator = makeAddr("operator");
    address affiliate1 = makeAddr("affiliate1");
    address affiliate2 = makeAddr("affiliate2");

    function setUp() public {
        metro = new CoreFlowToken("Metro", "METRO", 18);
        usdc = new CoreFlowToken("USD Coin", "USDC", 6);
        output = new CoreFlowToken("Output", "OUT", 6);
        core = xMETRO(
            _create(
                abi.encodePacked(
                    vm.getCode("xMETRO.sol:xMETRO"),
                    abi.encode(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000)
                )
            )
        );
        vault = new CommissionVault(
            address(usdc), makeAddr("distributor"), operator, makeAddr("guardian"), 1e12, 1e13, false, 1 hours, 1 hours
        );

        address implementation = _create(
            vm.parseJsonBytes(
                vm.readFile("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"), ".bytecode.object"
            )
        );
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)", address(vault), address(usdc), address(metro)
        );
        adapter = IXMetroDeFiAdapter(address(new ERC1967Proxy(implementation, initData)));
        vault.setDeFiAdapter(address(adapter), address(core));

        ICoreAdapterConfiguration configuration = ICoreAdapterConfiguration(address(adapter));
        configuration.setRouters(address(new CoreV2Router()), address(new CoreCode()), address(new CoreCode()));
        configuration.setSwapMetroConfig(true, true);
        autoSwapId = configuration.setSwapTokenConfig(address(output), true, true);
        swapMetroId = keccak256(
            abi.encode(
                block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), IXMetroDeFiAdapter.StrategyKind.SwapMetro, metro
            )
        );
        vault.setPayoutStrategyAllowed(swapMetroId, true);
        vault.setPayoutStrategyAllowed(autoSwapId, true);

        _settle(affiliate1, affiliate2, 100e6, 60e6);
        usdc.mint(address(vault), 160e6);
    }

    function test_convertEligible_swapMetro_paysXMetro() public {
        _optIn(swapMetroId);
        vm.prank(operator);
        vault.convertEligible(swapMetroId, _codes(), 1, block.timestamp + 1, _route(address(metro)));

        assertEq(core.balanceOf(affiliate1), 100e6);
        assertEq(core.balanceOf(affiliate2), 60e6);
        assertEq(vault.totalClaimed(), 160e6);
        _assertVaultHoldsNothing();
    }

    function test_convertEligible_autoSwap_adapterPaysAccounts() public {
        _optIn(autoSwapId);
        vm.prank(operator);
        vault.convertEligible(autoSwapId, _codes(), 1, block.timestamp + 1, _route(address(output)));

        assertEq(output.balanceOf(affiliate1), 100e6);
        assertEq(output.balanceOf(affiliate2), 60e6);
        assertEq(vault.totalClaimed(), 160e6);
        _assertVaultHoldsNothing();
    }

    function test_claimConverted_swapMetro() public {
        _optIn(swapMetroId);
        vm.prank(affiliate1);
        vault.claimConverted("CODE_A", 1, block.timestamp + 1, _route(address(metro)));

        assertEq(core.balanceOf(affiliate1), 100e6);
        assertEq(vault.totalClaimed(), 100e6);
        _assertVaultHoldsNothing();
    }

    function test_adapterRejectsCallerOtherThanVault() public {
        _expectGateRejects(address(this));
    }

    function test_adapterRejectsVaultOnceRebound() public {
        vault.setDeFiAdapter(address(new CoreCode()), address(core));
        _expectGateRejects(address(vault));
    }

    function _expectGateRejects(address caller) private {
        usdc.mint(address(adapter), 1e6);
        IXMetroDeFiAdapter.ManualExecution memory request = IXMetroDeFiAdapter.ManualExecution(
            swapMetroId, affiliate1, 1e6, 1, block.timestamp + 1, _route(address(metro))
        );
        vm.prank(caller);
        vm.expectRevert(bytes4(keccak256("AccessStateFailure()")));
        adapter.execute(request);
    }

    function _settle(address payout1, address payout2, uint256 amount1, uint256 amount2) private {
        address[] memory payouts = new address[](2);
        payouts[0] = payout1;
        payouts[1] = payout2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount1;
        amounts[1] = amount2;
        vm.prank(operator);
        vault.proposeSettlement(_codes(), payouts, amounts);
        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();
    }

    function _codes() private pure returns (string[] memory codes) {
        codes = new string[](2);
        codes[0] = "CODE_A";
        codes[1] = "CODE_B";
    }

    function _optIn(bytes32 strategyId) private {
        vm.prank(affiliate1);
        vault.setPayoutStrategy("CODE_A", strategyId);
        vm.prank(affiliate2);
        vault.setPayoutStrategy("CODE_B", strategyId);
    }

    function _route(address tokenOut) private view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = tokenOut;
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), type(uint256).max, abi.encode(path));
    }

    function _assertVaultHoldsNothing() private view {
        assertEq(metro.balanceOf(address(vault)), 0);
        assertEq(core.balanceOf(address(vault)), 0);
        assertEq(output.balanceOf(address(vault)), 0);
        assertEq(metro.allowance(address(vault), address(core)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
    }
}
