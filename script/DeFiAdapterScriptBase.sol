// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IXMetroDeFiAdapter} from "../src/interfaces/IXMetroDeFiAdapter.sol";

interface IXMetroDeFiAdapterAdmin is IXMetroDeFiAdapter {
    struct AaveV3Config {
        address pool;
        address aToken;
        uint16 referralCode;
    }

    struct AaveV4Config {
        address spoke;
        uint256 reserveId;
    }

    struct MapleConfig {
        address router;
        address syrupToken;
        bytes32 depositData;
    }

    function initialize(address xMetro, address usdc, address metro) external;

    function configuration()
        external
        view
        returns (
            address core,
            address usdc,
            address metro,
            bytes32 family,
            uint64 epoch,
            address routerV2,
            address routerV3,
            address oneInchRouter,
            AaveV3Config memory aaveV3,
            AaveV4Config memory aaveV4,
            MapleConfig memory maple
        );

    function setRouters(address routerV2, address routerV3, address oneInchRouter) external;
    function setSwapMetroConfig(bool enabled, bool autoEnabled) external;
    function setSwapTokenConfig(address tokenOut, bool enabled, bool autoEnabled) external returns (bytes32);

    function setAaveV3Config(address pool, address aToken, uint16 referralCode, bool enabled, bool autoEnabled)
        external
        returns (bytes32);

    function setAaveV4Config(address spoke, address giver, uint256 reserveId, bool enabled, bool autoEnabled) external;
    function aaveV4Giver() external view returns (address);

    function setMapleConfig(address router, bytes32 depositData, bool enabled, bool autoEnabled)
        external
        returns (bytes32);

    function UPGRADE_INTERFACE_VERSION() external view returns (string memory);
    function proxiableUUID() external view returns (bytes32);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

abstract contract DeFiAdapterScriptBase is Script {
    bytes32 internal constant ADAPTER_FAMILY_ID = keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    bytes32 internal constant STRATEGY_DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 internal constant ADAPTER_STORAGE_NAMESPACE =
        0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;
    uint256 internal constant EIP170_LIMIT = 24_576;
    string internal constant DEFAULT_ADAPTER_ARTIFACT = "out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json";

    struct AdapterConfiguration {
        address core;
        address usdc;
        address metro;
        bytes32 family;
        uint64 epoch;
        address routerV2;
        address routerV3;
        address oneInchRouter;
        IXMetroDeFiAdapterAdmin.AaveV3Config aaveV3;
        IXMetroDeFiAdapterAdmin.AaveV4Config aaveV4;
        IXMetroDeFiAdapterAdmin.MapleConfig maple;
        address aaveV4Giver;
    }

    function _adapterCreationCode(string memory artifactPath) internal view returns (bytes memory) {
        string memory artifact = vm.readFile(artifactPath);
        bytes memory creationCode = vm.parseJsonBytes(artifact, ".bytecode.object");
        require(creationCode.length != 0, "AdapterScript: empty artifact");
        return creationCode;
    }

    function _deployCreationCode(bytes memory creationCode) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 32), mload(creationCode))
        }
        require(deployed != address(0), "AdapterScript: CREATE failed");
    }

    function _requireImplementation(address implementation, uint64 minimumVersion)
        internal
        view
        returns (uint64 version)
    {
        require(implementation.code.length != 0, "AdapterScript: implementation no code");
        require(implementation.code.length < EIP170_LIMIT, "AdapterScript: implementation EIP-170");

        IXMetroDeFiAdapterAdmin candidate = IXMetroDeFiAdapterAdmin(implementation);
        require(candidate.adapterFamilyId() == ADAPTER_FAMILY_ID, "AdapterScript: family mismatch");
        require(candidate.proxiableUUID() == IMPLEMENTATION_SLOT, "AdapterScript: UUID mismatch");
        require(
            keccak256(bytes(candidate.UPGRADE_INTERFACE_VERSION())) == keccak256(bytes("5.0.0")),
            "AdapterScript: UUPS interface mismatch"
        );
        version = candidate.implementationVersion();
        require(version >= minimumVersion, "AdapterScript: version too old");
    }

    function _proxyImplementation(address proxy) internal view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    function _requireProxySlots(address proxy, address implementation) internal view {
        require(_proxyImplementation(proxy) == implementation, "AdapterScript: implementation slot");
        require(vm.load(proxy, ADMIN_SLOT) == bytes32(0), "AdapterScript: nonzero admin slot");
        require(vm.load(proxy, BEACON_SLOT) == bytes32(0), "AdapterScript: nonzero beacon slot");
    }

    function _readConfiguration(address proxy) internal view returns (AdapterConfiguration memory config) {
        (bool ok, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("configuration()"));
        require(ok && data.length == 512, "AdapterScript: bad configuration ABI");
        // Keep the configuration() ABI stable and read the added Giver getter separately.
        config = abi.decode(
            abi.encodePacked(data, bytes32(uint256(uint160(IXMetroDeFiAdapterAdmin(proxy).aaveV4Giver())))),
            (AdapterConfiguration)
        );
    }

    function _requireProxyBindings(address proxy, address core, address usdc, address metro)
        internal
        view
        returns (AdapterConfiguration memory config)
    {
        config = _readConfiguration(proxy);
        require(
            config.core == core && config.usdc == usdc && config.metro == metro && config.family == ADAPTER_FAMILY_ID
                && config.epoch != 0,
            "AdapterScript: proxy binding mismatch"
        );
    }

    function _strategyId(IXMetroDeFiAdapter.StrategyKind kind, address outputToken) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, STRATEGY_DOMAIN, kind, outputToken));
    }

    function _requireNoAllowance(address token, address holder, address spender) internal view {
        if (spender != address(0)) {
            require(IERC20(token).allowance(holder, spender) == 0, "AdapterScript: residual allowance");
        }
    }
}
