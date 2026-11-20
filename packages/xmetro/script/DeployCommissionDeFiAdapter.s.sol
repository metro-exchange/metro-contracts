// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IXMetroDeFiAdapter} from "../src/interfaces/IXMetroDeFiAdapter.sol";
import {DeFiAdapterScriptBase, IXMetroDeFiAdapterAdmin} from "./DeFiAdapterScriptBase.sol";

interface ICommissionVaultAdapterAdmin {
    function owner() external view returns (address);
    function usdc() external view returns (address);
    function setDeFiAdapter(address adapter, address xMetro) external;
    function setPayoutStrategyAllowed(bytes32 strategyId, bool allowed) external;
}

interface IXMetroToken {
    function METRO() external view returns (address);
}

contract DeployCommissionDeFiAdapter is DeFiAdapterScriptBase {
    function run() external returns (address) {
        return
            _deploy(
                vm.envAddress("COMMISSION_VAULT"), vm.envAddress("XMETRO"), vm.envAddress("XMETRO_DEFI_ADAPTER_PROXY")
            );
    }

    function _deploy(address vaultAddress, address xMetro, address xMetroAdapter) internal returns (address proxy) {
        ICommissionVaultAdapterAdmin vault = ICommissionVaultAdapterAdmin(vaultAddress);
        address usdc = vault.usdc();
        address metro = IXMetroToken(xMetro).METRO();
        AdapterConfiguration memory routes = _requireProxyBindings(xMetroAdapter, xMetro, usdc, metro);

        vm.startBroadcast(vault.owner());
        address implementation = _deployCreationCode(_adapterCreationCode(DEFAULT_ADAPTER_ARTIFACT));
        proxy = address(
            new ERC1967Proxy(
                implementation, abi.encodeCall(IXMetroDeFiAdapterAdmin.initialize, (vaultAddress, usdc, metro))
            )
        );
        vault.setDeFiAdapter(proxy, xMetro);
        IXMetroDeFiAdapterAdmin adapter = IXMetroDeFiAdapterAdmin(proxy);
        adapter.setRouters(routes.routerV2, routes.routerV3, routes.oneInchRouter);
        adapter.setSwapMetroConfig(true, true);
        vault.setPayoutStrategyAllowed(_strategyId(IXMetroDeFiAdapter.StrategyKind.SwapMetro, metro), true);
        vm.stopBroadcast();

        _requireImplementation(implementation, 2);
        _requireProxySlots(proxy, implementation);
        _requireProxyBindings(proxy, vaultAddress, usdc, metro);
    }
}
