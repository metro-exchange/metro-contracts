// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {xMETRO} from "../../src/xMETRO.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {DeployCommissionDeFiAdapter} from "../../script/DeployCommissionDeFiAdapter.s.sol";
import {IXMetroDeFiAdapterAdmin} from "../../script/DeFiAdapterScriptBase.sol";
import {CommissionVault} from "../fork-v2/mainnet/vendor/CommissionVault.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";

contract DeployCommissionDeFiAdapterTest is Test {
    function test_deploy_bindsAdapterToVaultAndEnablesXMetroPayouts() public {
        ERC20Mintable metro = new ERC20Mintable("Metro", "METRO", 18);
        ERC20Mintable usdc = new ERC20Mintable("USD Coin", "USDC", 6);
        xMETRO core = xMETRO(
            _create(
                abi.encodePacked(
                    vm.getCode("xMETRO.sol:xMETRO"),
                    abi.encode(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000)
                )
            )
        );
        address implementation = _create(
            vm.parseJsonBytes(
                vm.readFile("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"), ".bytecode.object"
            )
        );
        IXMetroDeFiAdapterAdmin xMetroAdapter = IXMetroDeFiAdapterAdmin(
            address(
                new ERC1967Proxy(
                    implementation,
                    abi.encodeCall(IXMetroDeFiAdapterAdmin.initialize, (address(core), address(usdc), address(metro)))
                )
            )
        );
        core.setDeFiAdapter(address(xMetroAdapter));
        address routerV2 = address(new ERC20Mintable("V2", "V2", 18));
        address routerV3 = address(new ERC20Mintable("V3", "V3", 18));
        address oneInch = address(new ERC20Mintable("1INCH", "1INCH", 18));
        xMetroAdapter.setRouters(routerV2, routerV3, oneInch);
        CommissionVault vault = new CommissionVault(
            address(usdc),
            makeAddr("distributor"),
            makeAddr("operator"),
            makeAddr("guardian"),
            1,
            1,
            false,
            1 hours,
            1 hours
        );

        address proxy = new DeployCommissionDeFiAdapter().deploy(address(vault), address(core), address(xMetroAdapter));

        bytes32 swapMetroId = keccak256(
            abi.encode(
                block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), IXMetroDeFiAdapter.StrategyKind.SwapMetro, metro
            )
        );
        assertEq(vault.deFiAdapter(), proxy);
        assertEq(vault.xMetro(), address(core));
        assertTrue(vault.payoutStrategyAllowed(swapMetroId));
        IXMetroDeFiAdapter.StrategyInfo memory info = IXMetroDeFiAdapter(proxy).strategyInfo(swapMetroId);
        assertTrue(info.enabled && info.autoEnabled);
        (address boundCore,,,,, address boundV2, address boundV3, address boundOneInch,,,) =
            IXMetroDeFiAdapterAdmin(proxy).configuration();
        assertEq(boundCore, address(vault));
        assertEq(boundV2, routerV2);
        assertEq(boundV3, routerV3);
        assertEq(boundOneInch, oneInch);
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
    }
}
