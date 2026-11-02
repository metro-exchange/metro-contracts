// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IXMetroDeFiAdapter} from "../src/interfaces/IXMetroDeFiAdapter.sol";
import {DeFiAdapterScriptBase, IXMetroDeFiAdapterAdmin} from "./DeFiAdapterScriptBase.sol";

interface IXMetroUpgradeCore {
    function owner() external view returns (address);
    function deFiAdapter() external view returns (address);
    function METRO() external view returns (address);
    function rewardToken() external view returns (address);
}

/// @notice Strict UUPS upgrade runbook for the active Adapter Proxy.
contract UpgradeDeFiAdapter is DeFiAdapterScriptBase {
    using stdJson for string;

    struct Snapshot {
        bytes32 configurationHash;
        bytes32 strategiesHash;
        bytes32 balancesHash;
        bytes32 allowancesHash;
        uint64 logicEpoch;
        uint64 implementationVersion;
    }

    function run() external {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "Upgrade: wrong chainId");
        address coreAddress = vm.envAddress("XMETRO");
        address proxy = vm.envAddress("DEFI_ADAPTER_PROXY");
        IXMetroUpgradeCore core = IXMetroUpgradeCore(coreAddress);
        require(coreAddress.code.length != 0 && proxy.code.length != 0, "Upgrade: no code");
        require(core.deFiAdapter() == proxy, "Upgrade: inactive proxy");

        address owner = core.owner();
        uint256 callerPk = vm.envOr("UPGRADE_CALLER_PRIVATE_KEY", uint256(0));
        address caller = callerPk == 0 ? vm.envOr("UPGRADE_CALLER", owner) : vm.addr(callerPk);
        require(caller == owner, "Upgrade: caller not owner");

        address oldImplementation = _proxyImplementation(proxy);
        uint64 oldVersion = _requireImplementation(oldImplementation, 1);
        AdapterConfiguration memory oldConfig =
            _requireProxyBindings(proxy, coreAddress, core.rewardToken(), core.METRO());
        string memory deploymentJsonPath = vm.envString("DEPLOYMENT_JSON");
        string memory deploymentJson = vm.readFile(deploymentJsonPath);
        require(
            deploymentJson.readUint(".chainId") == block.chainid && deploymentJson.readAddress(".xMETRO") == coreAddress
                && deploymentJson.readAddress(".deFiAdapterProxy") == proxy,
            "Upgrade: deployment manifest mismatch"
        );
        address[] memory outputTokens = _outputTokens(deploymentJson);
        bytes32[] memory strategyIds = _strategyIds(oldConfig, outputTokens);
        address[] memory trackedTokens = _trackedTokens(outputTokens, oldConfig);
        address[] memory spenders = _spenders(oldConfig);
        Snapshot memory beforeState = _snapshot(proxy, oldConfig, strategyIds, trackedTokens, spenders);
        require(beforeState.implementationVersion == oldVersion, "Upgrade: old version mismatch");

        string memory artifactPath = vm.envString("NEW_ADAPTER_ARTIFACT");
        bytes memory creationCode = _adapterCreationCode(artifactPath);
        bytes32 expectedInitcodeHash = vm.envBytes32("EXPECTED_NEW_IMPLEMENTATION_INITCODE_HASH");
        require(expectedInitcodeHash != bytes32(0), "Upgrade: missing approved initcode hash");
        require(keccak256(creationCode) == expectedInitcodeHash, "Upgrade: artifact initcode hash");
        uint256 deployerPk = vm.envOr("IMPLEMENTATION_DEPLOYER_PRIVATE_KEY", uint256(0));
        address implementationDeployer =
            deployerPk == 0 ? vm.envOr("IMPLEMENTATION_DEPLOYER", caller) : vm.addr(deployerPk);
        uint256 implementationNonce = vm.getNonce(implementationDeployer);
        address predictedImplementation = vm.computeCreateAddress(implementationDeployer, implementationNonce);
        require(predictedImplementation.code.length == 0, "Upgrade: predicted address occupied");

        if (deployerPk == 0) vm.startBroadcast(implementationDeployer);
        else vm.startBroadcast(deployerPk);
        address newImplementation = _deployCreationCode(creationCode);
        vm.stopBroadcast();
        require(newImplementation == predictedImplementation, "Upgrade: CREATE address mismatch");
        uint64 newVersion = _requireImplementation(newImplementation, oldVersion + 1);
        require(newImplementation != oldImplementation, "Upgrade: same implementation");
        require(
            IXMetroDeFiAdapter(newImplementation).xMETRO() == address(0)
                && IERC20(core.rewardToken()).balanceOf(newImplementation) == 0
                && IERC20(core.METRO()).balanceOf(newImplementation) == 0,
            "Upgrade: implementation state/balance"
        );

        bytes memory migrationData = vm.envOr("ADAPTER_MIGRATION_DATA", bytes(""));
        if (callerPk == 0) vm.startBroadcast(caller);
        else vm.startBroadcast(callerPk);
        IXMetroDeFiAdapterAdmin(proxy).upgradeToAndCall(newImplementation, migrationData);
        vm.stopBroadcast();

        _requireProxySlots(proxy, newImplementation);
        AdapterConfiguration memory newConfig =
            _requireProxyBindings(proxy, coreAddress, core.rewardToken(), core.METRO());
        Snapshot memory afterState = _snapshot(proxy, newConfig, strategyIds, trackedTokens, spenders);
        require(afterState.logicEpoch == beforeState.logicEpoch + 1, "Upgrade: epoch increment");
        require(afterState.implementationVersion == newVersion, "Upgrade: version readback");
        require(afterState.configurationHash == beforeState.configurationHash, "Upgrade: configuration changed");
        require(afterState.strategiesHash == beforeState.strategiesHash, "Upgrade: strategy changed");
        require(afterState.balancesHash == beforeState.balancesHash, "Upgrade: balance changed");
        require(afterState.allowancesHash == beforeState.allowancesHash, "Upgrade: allowance changed");
        require(core.deFiAdapter() == proxy && core.owner() == owner, "Upgrade: core changed");

        _writeEvidence(
            deploymentJsonPath,
            oldImplementation,
            newImplementation,
            proxy,
            owner,
            implementationDeployer,
            implementationNonce,
            beforeState.logicEpoch,
            afterState.logicEpoch,
            oldVersion,
            newVersion
        );
    }

    function _snapshot(
        address proxy,
        AdapterConfiguration memory config,
        bytes32[] memory strategyIds,
        address[] memory trackedTokens,
        address[] memory spenders
    ) internal view returns (Snapshot memory state) {
        state.logicEpoch = config.epoch;
        state.implementationVersion = IXMetroDeFiAdapter(proxy).implementationVersion();
        state.configurationHash = keccak256(
            abi.encode(
                config.core,
                config.usdc,
                config.metro,
                config.family,
                config.routerV2,
                config.routerV3,
                config.oneInchRouter,
                config.aaveV3,
                config.aaveV4,
                config.aaveV4Giver,
                config.maple
            )
        );

        bytes32 strategies;
        for (uint256 i; i < strategyIds.length; ++i) {
            bytes32 id = strategyIds[i];
            if (id == bytes32(0)) continue;
            IXMetroDeFiAdapter.StrategyInfo memory info = IXMetroDeFiAdapter(proxy).strategyInfo(id);
            require(info.logicEpoch == state.logicEpoch, "Upgrade: stale strategy epoch");
            strategies = keccak256(
                abi.encode(
                    strategies,
                    id,
                    info.kind,
                    info.enabled,
                    info.autoEnabled,
                    info.domainRevision,
                    info.strategyRevision,
                    info.outputToken
                )
            );
        }
        state.strategiesHash = strategies;

        bytes32 balances;
        for (uint256 i; i < trackedTokens.length; ++i) {
            address token = trackedTokens[i];
            if (token != address(0)) balances = keccak256(abi.encode(balances, token, IERC20(token).balanceOf(proxy)));
        }
        state.balancesHash = balances;

        bytes32 allowances = keccak256(abi.encode(IERC20(config.usdc).allowance(config.core, proxy)));
        for (uint256 i; i < spenders.length; ++i) {
            address spender = spenders[i];
            if (spender != address(0)) {
                allowances = keccak256(abi.encode(allowances, spender, IERC20(config.usdc).allowance(proxy, spender)));
            }
        }
        state.allowancesHash = allowances;
    }

    function _strategyIds(AdapterConfiguration memory config, address[] memory outputTokens)
        internal
        view
        returns (bytes32[] memory ids)
    {
        ids = new bytes32[](outputTokens.length + 4);
        ids[0] = _strategyId(IXMetroDeFiAdapter.StrategyKind.SwapMetro, config.metro);
        for (uint256 i; i < outputTokens.length; ++i) {
            if (outputTokens[i] != address(0)) {
                ids[i + 1] = _strategyId(IXMetroDeFiAdapter.StrategyKind.AutoSwap, outputTokens[i]);
            }
        }
        ids[outputTokens.length + 1] = config.aaveV3.aToken == address(0)
            ? bytes32(0)
            : _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV3, config.aaveV3.aToken);
        ids[outputTokens.length + 2] = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        ids[outputTokens.length + 3] = config.maple.syrupToken == address(0)
            ? bytes32(0)
            : _strategyId(IXMetroDeFiAdapter.StrategyKind.Maple, config.maple.syrupToken);
    }

    function _outputTokens(string memory json) internal view returns (address[] memory tokens) {
        address[] memory defaults = new address[](5);
        defaults[0] = json.readAddress(".tokenOutUsdt");
        defaults[1] = json.readAddress(".tokenOutWbtc");
        defaults[2] = json.readAddress(".tokenOutGho");
        defaults[3] = json.readAddress(".tokenOutXaut");
        defaults[4] = json.readAddress(".tokenOutSyrupUsdc");
        tokens = vm.envOr("SWAP_OUTPUT_TOKENS", ",", defaults);
    }

    function _trackedTokens(address[] memory outputTokens, AdapterConfiguration memory config)
        internal
        pure
        returns (address[] memory tokens)
    {
        tokens = new address[](outputTokens.length + 4);
        tokens[0] = config.usdc;
        tokens[1] = config.metro;
        for (uint256 i; i < outputTokens.length; ++i) {
            tokens[i + 2] = outputTokens[i];
        }
        tokens[outputTokens.length + 2] = config.aaveV3.aToken;
        tokens[outputTokens.length + 3] = config.maple.syrupToken;
    }

    function _spenders(AdapterConfiguration memory config) internal pure returns (address[] memory spenders) {
        spenders = new address[](7);
        spenders[0] = config.routerV2;
        spenders[1] = config.routerV3;
        spenders[2] = config.oneInchRouter;
        spenders[3] = config.aaveV3.pool;
        spenders[4] = config.aaveV4.spoke;
        spenders[5] = config.maple.router;
        spenders[6] = config.aaveV4Giver;
    }

    function _writeEvidence(
        string memory deploymentPath,
        address oldImplementation,
        address newImplementation,
        address proxy,
        address owner,
        address implementationDeployer,
        uint256 implementationNonce,
        uint64 oldEpoch,
        uint64 newEpoch,
        uint64 oldVersion,
        uint64 newVersion
    ) internal {
        string memory object = "upgrade";
        string memory json = vm.serializeUint(object, "chainId", block.chainid);
        json = vm.serializeAddress(object, "proxy", proxy);
        json = vm.serializeAddress(object, "owner", owner);
        json = vm.serializeAddress(object, "implementationDeployer", implementationDeployer);
        json = vm.serializeUint(object, "implementationNonce", implementationNonce);
        json = vm.serializeAddress(object, "oldImplementation", oldImplementation);
        json = vm.serializeBytes32(object, "oldImplementationCodehash", oldImplementation.codehash);
        json = vm.serializeAddress(object, "newImplementation", newImplementation);
        json = vm.serializeBytes32(object, "newImplementationCodehash", newImplementation.codehash);
        json = vm.serializeUint(object, "oldLogicEpoch", oldEpoch);
        json = vm.serializeUint(object, "newLogicEpoch", newEpoch);
        json = vm.serializeUint(object, "oldImplementationVersion", oldVersion);
        json = vm.serializeUint(object, "newImplementationVersion", newVersion);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), "/adapter-upgrade.json"));

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
        vm.writeJson(vm.toString(newEpoch), deploymentPath, ".adapterLogicEpoch");
        vm.writeJson(vm.toString(newVersion), deploymentPath, ".adapterImplementationVersion");

        console2.log("=== Adapter UUPS Upgrade ===");
        console2.log("Proxy:", proxy);
        console2.log("Old Implementation:", oldImplementation);
        console2.log("New Implementation:", newImplementation);
        console2.log("Logic epoch:", newEpoch);
    }
}
