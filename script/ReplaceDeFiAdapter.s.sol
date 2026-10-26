// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IXMetroDeFiAdapter} from "../src/interfaces/IXMetroDeFiAdapter.sol";
import {DeFiAdapterScriptBase, IXMetroDeFiAdapterAdmin} from "./DeFiAdapterScriptBase.sol";

interface IXMetroReplacementCore {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function deFiAdapter() external view returns (address);
    function deFiAdapterEpoch() external view returns (uint64);
    function METRO() external view returns (address);
    function rewardToken() external view returns (address);
    function setDeFiAdapter(address adapter) external;
}

/// @notice Disaster recovery path that replaces the complete Adapter Proxy.
contract ReplaceDeFiAdapter is DeFiAdapterScriptBase {
    using stdJson for string;

    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "Replace: wrong chainId");
        address coreAddress = vm.envAddress("XMETRO");
        address oldProxy = vm.envAddress("DEFI_ADAPTER_PROXY");
        IXMetroReplacementCore core = IXMetroReplacementCore(coreAddress);
        require(coreAddress.code.length != 0 && oldProxy.code.length != 0, "Replace: no code");
        require(core.deFiAdapter() == oldProxy, "Replace: inactive proxy");
        require(core.paused(), "Replace: core must be paused");

        address owner = core.owner();
        uint256 callerPk = vm.envOr("REPLACEMENT_CALLER_PRIVATE_KEY", uint256(0));
        address caller = callerPk == 0 ? vm.envOr("REPLACEMENT_CALLER", owner) : vm.addr(callerPk);
        require(caller == owner, "Replace: caller not owner");
        uint64 oldAdapterEpoch = core.deFiAdapterEpoch();

        AdapterConfiguration memory oldConfig =
            _requireProxyBindings(oldProxy, coreAddress, core.rewardToken(), core.METRO());
        string memory deploymentPath = vm.envString("DEPLOYMENT_JSON");
        string memory deploymentJson = vm.readFile(deploymentPath);
        require(
            deploymentJson.readUint(".chainId") == block.chainid && deploymentJson.readAddress(".xMETRO") == coreAddress
                && deploymentJson.readAddress(".deFiAdapterProxy") == oldProxy,
            "Replace: deployment manifest mismatch"
        );
        address[] memory defaultOutputs = _defaultOutputTokens(deploymentJson);
        address[] memory outputTokens = vm.envOr("SWAP_OUTPUT_TOKENS", ",", defaultOutputs);
        _requireInventoryClean(oldProxy, oldConfig, outputTokens);

        address oldImplementation = _proxyImplementation(oldProxy);
        uint64 oldVersion = _requireImplementation(oldImplementation, 1);
        string memory artifactPath = vm.envString("REPLACEMENT_ADAPTER_ARTIFACT");
        bytes memory implementationCreationCode = _adapterCreationCode(artifactPath);
        bytes32 expectedInitcodeHash = vm.envBytes32("EXPECTED_REPLACEMENT_IMPLEMENTATION_INITCODE_HASH");
        require(expectedInitcodeHash != bytes32(0), "Replace: missing approved initcode hash");
        require(keccak256(implementationCreationCode) == expectedInitcodeHash, "Replace: artifact initcode hash");
        uint256 deployerPk = vm.envOr("REPLACEMENT_DEPLOYER_PRIVATE_KEY", uint256(0));
        address replacementDeployer = deployerPk == 0 ? vm.envOr("REPLACEMENT_DEPLOYER", caller) : vm.addr(deployerPk);
        uint256 deploymentNonce = vm.getNonce(replacementDeployer);
        address predictedImplementation = vm.computeCreateAddress(replacementDeployer, deploymentNonce);
        address predictedProxy = vm.computeCreateAddress(replacementDeployer, deploymentNonce + 1);
        require(
            predictedImplementation.code.length == 0 && predictedProxy.code.length == 0,
            "Replace: predicted address occupied"
        );

        if (deployerPk == 0) vm.startBroadcast(replacementDeployer);
        else vm.startBroadcast(deployerPk);
        address newImplementation = _deployCreationCode(implementationCreationCode);
        bytes memory initData =
            abi.encodeCall(IXMetroDeFiAdapterAdmin.initialize, (coreAddress, core.rewardToken(), core.METRO()));
        address newProxy = address(new ERC1967Proxy(newImplementation, initData));
        vm.stopBroadcast();
        require(
            newImplementation == predictedImplementation && newProxy == predictedProxy,
            "Replace: CREATE address mismatch"
        );
        uint64 newVersion = _requireImplementation(newImplementation, oldVersion);
        _requireProxySlots(newProxy, newImplementation);
        _requireProxyBindings(newProxy, coreAddress, core.rewardToken(), core.METRO());

        if (callerPk == 0) vm.startBroadcast(caller);
        else vm.startBroadcast(callerPk);
        core.setDeFiAdapter(newProxy);
        _copyConfiguration(oldProxy, newProxy, oldConfig, outputTokens);
        _requireOldProxyDisabled(oldProxy, newImplementation, oldConfig);
        vm.stopBroadcast();

        require(core.deFiAdapter() == newProxy && core.paused(), "Replace: activation/pause failed");
        require(core.deFiAdapterEpoch() == oldAdapterEpoch + 1, "Replace: adapter epoch");
        AdapterConfiguration memory newConfig =
            _requireProxyBindings(newProxy, coreAddress, core.rewardToken(), core.METRO());
        _requireEquivalent(oldProxy, newProxy, oldConfig, newConfig, outputTokens);
        _requireInventoryClean(oldProxy, oldConfig, outputTokens);
        _requireInventoryClean(newProxy, newConfig, outputTokens);
        _writeActiveConfiguration(deploymentPath, newProxy, newConfig);
        _writeEvidence(
            deploymentPath,
            oldProxy,
            newProxy,
            oldImplementation,
            newImplementation,
            owner,
            replacementDeployer,
            deploymentNonce,
            oldAdapterEpoch,
            core.deFiAdapterEpoch(),
            oldVersion,
            newVersion
        );
    }

    function _copyConfiguration(
        address oldProxy,
        address newProxy,
        AdapterConfiguration memory config,
        address[] memory outputTokens
    ) internal {
        IXMetroDeFiAdapterAdmin oldAdapter = IXMetroDeFiAdapterAdmin(oldProxy);
        IXMetroDeFiAdapterAdmin newAdapter = IXMetroDeFiAdapterAdmin(newProxy);
        if (config.routerV2 != address(0)) {
            newAdapter.setRouters(config.routerV2, config.routerV3, config.oneInchRouter);
        }

        bytes32 swapMetroId = _strategyId(IXMetroDeFiAdapter.StrategyKind.SwapMetro, config.metro);
        IXMetroDeFiAdapter.StrategyInfo memory swapMetro = oldAdapter.strategyInfo(swapMetroId);
        if (swapMetro.enabled || swapMetro.autoEnabled) {
            newAdapter.setSwapMetroConfig(swapMetro.enabled, swapMetro.autoEnabled);
        }

        for (uint256 i; i < outputTokens.length; ++i) {
            address token = outputTokens[i];
            if (token == address(0)) continue;
            bytes32 id = _strategyId(IXMetroDeFiAdapter.StrategyKind.AutoSwap, token);
            IXMetroDeFiAdapter.StrategyInfo memory info = oldAdapter.strategyInfo(id);
            if (info.kind != IXMetroDeFiAdapter.StrategyKind.AutoSwap) continue;
            newAdapter.setSwapTokenConfig(token, true, info.enabled && info.autoEnabled);
            if (!info.enabled) newAdapter.setSwapTokenConfig(token, false, false);
        }

        if (config.aaveV3.pool != address(0)) {
            bytes32 id = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV3, config.aaveV3.aToken);
            IXMetroDeFiAdapter.StrategyInfo memory info = oldAdapter.strategyInfo(id);
            if (info.enabled) {
                newAdapter.setAaveV3Config(
                    config.aaveV3.pool, config.aaveV3.aToken, config.aaveV3.referralCode, true, info.autoEnabled
                );
            }
        }
        if (config.aaveV4.spoke != address(0)) {
            bytes32 id = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
            IXMetroDeFiAdapter.StrategyInfo memory info = oldAdapter.strategyInfo(id);
            if (info.enabled) {
                newAdapter.setAaveV4Config(
                    config.aaveV4.spoke, config.aaveV4Giver, config.aaveV4.reserveId, true, info.autoEnabled
                );
            }
        }
        if (config.maple.router != address(0)) {
            bytes32 id = _strategyId(IXMetroDeFiAdapter.StrategyKind.Maple, config.maple.syrupToken);
            IXMetroDeFiAdapter.StrategyInfo memory info = oldAdapter.strategyInfo(id);
            if (info.enabled) {
                newAdapter.setMapleConfig(config.maple.router, config.maple.depositData, true, info.autoEnabled);
            }
        }
    }

    function _requireEquivalent(
        address oldProxy,
        address newProxy,
        AdapterConfiguration memory oldConfig,
        AdapterConfiguration memory newConfig,
        address[] memory outputTokens
    ) internal view {
        bytes32 aaveV3Id = oldConfig.aaveV3.aToken == address(0)
            ? bytes32(0)
            : _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV3, oldConfig.aaveV3.aToken);
        bytes32 aaveV4Id = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        bytes32 mapleId = oldConfig.maple.syrupToken == address(0)
            ? bytes32(0)
            : _strategyId(IXMetroDeFiAdapter.StrategyKind.Maple, oldConfig.maple.syrupToken);
        bool aaveV3Enabled = aaveV3Id != bytes32(0) && IXMetroDeFiAdapter(oldProxy).strategyInfo(aaveV3Id).enabled;
        bool aaveV4Enabled = IXMetroDeFiAdapter(oldProxy).strategyInfo(aaveV4Id).enabled;
        bool mapleEnabled = mapleId != bytes32(0) && IXMetroDeFiAdapter(oldProxy).strategyInfo(mapleId).enabled;

        require(
            oldConfig.core == newConfig.core && oldConfig.usdc == newConfig.usdc && oldConfig.metro == newConfig.metro
                && oldConfig.family == newConfig.family && oldConfig.routerV2 == newConfig.routerV2
                && oldConfig.routerV3 == newConfig.routerV3 && oldConfig.oneInchRouter == newConfig.oneInchRouter
                && (aaveV3Enabled
                        ? keccak256(abi.encode(oldConfig.aaveV3)) == keccak256(abi.encode(newConfig.aaveV3))
                        : newConfig.aaveV3.pool == address(0) && newConfig.aaveV3.aToken == address(0)
                        && newConfig.aaveV3.referralCode == 0)
                && (aaveV4Enabled
                        ? keccak256(abi.encode(oldConfig.aaveV4, oldConfig.aaveV4Giver))
                            == keccak256(abi.encode(newConfig.aaveV4, newConfig.aaveV4Giver))
                        : newConfig.aaveV4.spoke == address(0) && newConfig.aaveV4.reserveId == 0
                        && newConfig.aaveV4Giver == address(0))
                && (mapleEnabled
                        ? keccak256(abi.encode(oldConfig.maple)) == keccak256(abi.encode(newConfig.maple))
                        : newConfig.maple.router == address(0) && newConfig.maple.syrupToken == address(0)
                        && newConfig.maple.depositData == bytes32(0)),
            "Replace: configuration mismatch"
        );
        _requireStrategyEquivalent(
            oldProxy, newProxy, _strategyId(IXMetroDeFiAdapter.StrategyKind.SwapMetro, oldConfig.metro)
        );
        for (uint256 i; i < outputTokens.length; ++i) {
            if (outputTokens[i] != address(0)) {
                _requireStrategyEquivalent(
                    oldProxy, newProxy, _strategyId(IXMetroDeFiAdapter.StrategyKind.AutoSwap, outputTokens[i])
                );
            }
        }
        if (aaveV3Id != bytes32(0)) {
            if (aaveV3Enabled) _requireStrategyEquivalent(oldProxy, newProxy, aaveV3Id);
            else _requireStrategyDisabled(newProxy, aaveV3Id);
        }
        if (aaveV4Enabled) _requireStrategyEquivalent(oldProxy, newProxy, aaveV4Id);
        else _requireStrategyDisabled(newProxy, aaveV4Id);
        if (mapleId != bytes32(0)) {
            if (mapleEnabled) _requireStrategyEquivalent(oldProxy, newProxy, mapleId);
            else _requireStrategyDisabled(newProxy, mapleId);
        }
    }

    function _requireStrategyEquivalent(address oldProxy, address newProxy, bytes32 id) internal view {
        IXMetroDeFiAdapter.StrategyInfo memory oldInfo = IXMetroDeFiAdapter(oldProxy).strategyInfo(id);
        IXMetroDeFiAdapter.StrategyInfo memory newInfo = IXMetroDeFiAdapter(newProxy).strategyInfo(id);
        require(
            oldInfo.kind == newInfo.kind && oldInfo.enabled == newInfo.enabled
                && oldInfo.autoEnabled == newInfo.autoEnabled && oldInfo.outputToken == newInfo.outputToken,
            "Replace: strategy mismatch"
        );
    }

    function _requireStrategyDisabled(address proxy, bytes32 id) internal view {
        IXMetroDeFiAdapter.StrategyInfo memory info = IXMetroDeFiAdapter(proxy).strategyInfo(id);
        require(!info.enabled && !info.autoEnabled, "Replace: strategy unexpectedly enabled");
    }

    function _requireInventoryClean(address proxy, AdapterConfiguration memory config, address[] memory outputTokens)
        internal
        view
    {
        require(
            IERC20(config.usdc).balanceOf(proxy) == 0 && IERC20(config.metro).balanceOf(proxy) == 0,
            "Replace: core token balance"
        );
        for (uint256 i; i < outputTokens.length; ++i) {
            if (outputTokens[i] != address(0)) {
                require(IERC20(outputTokens[i]).balanceOf(proxy) == 0, "Replace: output balance");
            }
        }
        if (config.aaveV3.aToken != address(0)) {
            require(IERC20(config.aaveV3.aToken).balanceOf(proxy) == 0, "Replace: aToken balance");
        }
        if (config.maple.syrupToken != address(0)) {
            require(IERC20(config.maple.syrupToken).balanceOf(proxy) == 0, "Replace: syrup balance");
        }
        _requireNoAllowance(config.usdc, config.core, proxy);
        _requireNoAllowance(config.usdc, proxy, config.routerV2);
        _requireNoAllowance(config.usdc, proxy, config.routerV3);
        _requireNoAllowance(config.usdc, proxy, config.oneInchRouter);
        _requireNoAllowance(config.usdc, proxy, config.aaveV3.pool);
        _requireNoAllowance(config.usdc, proxy, config.aaveV4.spoke);
        _requireNoAllowance(config.usdc, proxy, config.aaveV4Giver);
        _requireNoAllowance(config.usdc, proxy, config.maple.router);
    }

    function _requireOldProxyDisabled(
        address oldProxy,
        address validDifferentImplementation,
        AdapterConfiguration memory oldConfig
    ) internal {
        bytes memory configCall = oldConfig.routerV2 == address(0)
            ? abi.encodeCall(IXMetroDeFiAdapterAdmin.setSwapMetroConfig, (true, true))
            : abi.encodeCall(
                IXMetroDeFiAdapterAdmin.setRouters, (oldConfig.routerV3, oldConfig.routerV2, oldConfig.oneInchRouter)
            );
        (bool configOk,) = oldProxy.call(configCall);
        require(!configOk, "Replace: old proxy still configurable");
        (bool upgradeOk,) = oldProxy.call(
            abi.encodeCall(IXMetroDeFiAdapterAdmin.upgradeToAndCall, (validDifferentImplementation, bytes("")))
        );
        require(!upgradeOk, "Replace: old proxy still upgradeable");
    }

    function _defaultOutputTokens(string memory json) internal pure returns (address[] memory tokens) {
        tokens = new address[](5);
        tokens[0] = json.readAddress(".tokenOutUsdt");
        tokens[1] = json.readAddress(".tokenOutWbtc");
        tokens[2] = json.readAddress(".tokenOutGho");
        tokens[3] = json.readAddress(".tokenOutXaut");
        tokens[4] = json.readAddress(".tokenOutSyrupUsdc");
    }

    function _writeActiveConfiguration(
        string memory deploymentPath,
        address newProxy,
        AdapterConfiguration memory config
    ) internal {
        IXMetroDeFiAdapter adapter = IXMetroDeFiAdapter(newProxy);
        bytes32 aaveV3Id = config.aaveV3.aToken == address(0)
            ? bytes32(0)
            : _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV3, config.aaveV3.aToken);
        bytes32 aaveV4Id = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        bytes32 mapleId = config.maple.syrupToken == address(0)
            ? bytes32(0)
            : _strategyId(IXMetroDeFiAdapter.StrategyKind.Maple, config.maple.syrupToken);
        bool aaveV3Enabled = aaveV3Id != bytes32(0) && adapter.strategyInfo(aaveV3Id).enabled;
        bool aaveV4Enabled = adapter.strategyInfo(aaveV4Id).enabled;
        bool mapleEnabled = mapleId != bytes32(0) && adapter.strategyInfo(mapleId).enabled;

        _writeAddress(deploymentPath, ".aaveV3Pool", config.aaveV3.pool);
        _writeAddress(deploymentPath, ".aaveV3AUsdc", config.aaveV3.aToken);
        vm.writeJson(vm.toString(config.aaveV3.referralCode), deploymentPath, ".aaveV3ReferralCode");
        vm.writeJson(aaveV3Enabled ? "true" : "false", deploymentPath, ".aaveV3Enabled");
        _writeBytes32(deploymentPath, ".aaveV3StrategyId", aaveV3Id);

        _writeAddress(deploymentPath, ".aaveV4Spoke", config.aaveV4.spoke);
        _writeAddress(deploymentPath, ".aaveV4Giver", config.aaveV4Giver);
        vm.writeJson(vm.toString(config.aaveV4.reserveId), deploymentPath, ".aaveV4UsdcReserveId");
        vm.writeJson(aaveV4Enabled ? "true" : "false", deploymentPath, ".aaveV4Enabled");
        _writeBytes32(deploymentPath, ".aaveV4StrategyId", aaveV4Id);

        _writeAddress(deploymentPath, ".mapleSyrupRouter", config.maple.router);
        _writeAddress(deploymentPath, ".mapleSyrupUsdc", config.maple.syrupToken);
        _writeBytes32(deploymentPath, ".mapleDepositData", config.maple.depositData);
        vm.writeJson(mapleEnabled ? "true" : "false", deploymentPath, ".mapleEnabled");
        _writeBytes32(deploymentPath, ".mapleStrategyId", mapleId);
    }

    function _writeAddress(string memory path, string memory key, address value) internal {
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), path, key);
    }

    function _writeBytes32(string memory path, string memory key, bytes32 value) internal {
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), path, key);
    }

    function _writeEvidence(
        string memory deploymentPath,
        address oldProxy,
        address newProxy,
        address oldImplementation,
        address newImplementation,
        address owner,
        address replacementDeployer,
        uint256 deploymentNonce,
        uint64 oldEpoch,
        uint64 newEpoch,
        uint64 oldVersion,
        uint64 newVersion
    ) internal {
        AdapterConfiguration memory activeConfig = _readConfiguration(newProxy);
        bytes32 activeAaveV4Id = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        bytes32 activeMapleId = activeConfig.maple.syrupToken == address(0)
            ? bytes32(0)
            : _strategyId(IXMetroDeFiAdapter.StrategyKind.Maple, activeConfig.maple.syrupToken);
        AdapterConfiguration memory previousConfig = _readConfiguration(oldProxy);
        bool requiresAaveV4Reauthorization = IXMetroDeFiAdapter(newProxy).strategyInfo(activeAaveV4Id).enabled
            && (previousConfig.aaveV4.spoke != activeConfig.aaveV4.spoke
                || previousConfig.aaveV4Giver != activeConfig.aaveV4Giver);
        bool requiresMapleReauthorization =
            activeMapleId != bytes32(0) && IXMetroDeFiAdapter(newProxy).strategyInfo(activeMapleId).enabled;

        string memory object = "replacement";
        string memory json = vm.serializeUint(object, "chainId", block.chainid);
        json = vm.serializeAddress(object, "owner", owner);
        json = vm.serializeAddress(object, "replacementDeployer", replacementDeployer);
        json = vm.serializeUint(object, "deploymentNonce", deploymentNonce);
        json = vm.serializeAddress(object, "oldProxy", oldProxy);
        json = vm.serializeAddress(object, "newProxy", newProxy);
        json = vm.serializeAddress(object, "oldImplementation", oldImplementation);
        json = vm.serializeAddress(object, "newImplementation", newImplementation);
        json = vm.serializeBytes32(object, "newImplementationCodehash", newImplementation.codehash);
        json = vm.serializeBytes32(object, "newProxyCodehash", newProxy.codehash);
        json = vm.serializeUint(object, "oldAdapterEpoch", oldEpoch);
        json = vm.serializeUint(object, "newAdapterEpoch", newEpoch);
        json = vm.serializeUint(object, "oldImplementationVersion", oldVersion);
        json = vm.serializeUint(object, "newImplementationVersion", newVersion);
        json = vm.serializeBool(object, "requiresAaveV4Reauthorization", requiresAaveV4Reauthorization);
        json = vm.serializeBool(object, "requiresMapleReauthorization", requiresMapleReauthorization);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), "/adapter-replacement.json"));

        vm.writeJson(string.concat("\"", vm.toString(newProxy), "\""), deploymentPath, ".deFiAdapterProxy");
        vm.writeJson(
            string.concat("\"", vm.toString(newProxy.codehash), "\""), deploymentPath, ".deFiAdapterProxyCodehash"
        );
        vm.writeJson(
            string.concat("\"", vm.toString(newImplementation), "\""), deploymentPath, ".deFiAdapterImplementation"
        );
        vm.writeJson(
            string.concat("\"", vm.toString(newImplementation.codehash), "\""),
            deploymentPath,
            ".deFiAdapterImplementationCodehash"
        );
        vm.writeJson(
            string.concat("\"", vm.toString(newImplementation), "\""), deploymentPath, ".proxyImplementationReadback"
        );
        vm.writeJson(vm.toString(newEpoch), deploymentPath, ".adapterEpoch");
        vm.writeJson(vm.toString(IXMetroDeFiAdapter(newProxy).logicEpoch()), deploymentPath, ".adapterLogicEpoch");
        vm.writeJson(vm.toString(newVersion), deploymentPath, ".adapterImplementationVersion");

        console2.log("=== Adapter Proxy Replacement ===");
        console2.log("Old Proxy:", oldProxy);
        console2.log("New Proxy:", newProxy);
        console2.log("New Implementation:", newImplementation);
        console2.log("Adapter epoch:", newEpoch);
        if (requiresAaveV4Reauthorization) {
            console2.log("Aave V4 users must authorize the configured Giver on the new Spoke.");
        }
        if (requiresMapleReauthorization) console2.log("Maple must authorize the new Proxy address.");
    }
}
