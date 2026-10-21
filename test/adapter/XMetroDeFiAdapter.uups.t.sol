// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {XMetroDeFiAdapter} from "../../src/XMetroDeFiAdapter.sol";
import {XMetroDeFiAdapterV2} from "./XMetroDeFiAdapterV2.sol";

contract CompactProbeCode {}

contract CompactProbeCore {
    address public owner;
    bool public paused = true;
    address public deFiAdapter;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAdapter(address adapter) external {
        require(msg.sender == owner);
        deFiAdapter = adapter;
    }

    function setPaused(bool value) external {
        require(msg.sender == owner);
        paused = value;
    }

    function setOwner(address nextOwner) external {
        require(msg.sender == owner);
        owner = nextOwner;
    }
}

contract CompactAdapterV2 is Initializable, UUPSUpgradeable {
    bytes32 private constant ADAPTER_FAMILY_ID = keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    bytes32 private constant ADAPTER_STORAGE_LOCATION =
        0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;

    struct AdapterHeader {
        address xMetro;
        address usdc;
        address metro;
        uint64 logicEpoch;
        uint64 domainRevision;
    }

    constructor() {
        _disableInitializers();
    }

    function adapterFamilyId() external pure returns (bytes32) {
        return ADAPTER_FAMILY_ID;
    }

    function implementationVersion() external pure returns (uint64) {
        return 2;
    }

    function logicEpoch() external view returns (uint64) {
        return _adapterHeader().logicEpoch;
    }

    function _authorizeUpgrade(address) internal override {}

    function _adapterHeader() private pure returns (AdapterHeader storage state) {
        bytes32 location = ADAPTER_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }
}

contract CompactWrongFamilyUUPS is UUPSUpgradeable {
    function adapterFamilyId() external pure returns (bytes32) {
        return keccak256("WRONG_FAMILY");
    }

    function _authorizeUpgrade(address) internal override {}
}

contract CompactNoUUID {
    function adapterFamilyId() external pure returns (bytes32) {
        return keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    }
}

contract CompactBadUUID {
    function adapterFamilyId() external pure returns (bytes32) {
        return keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    }

    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

contract CompactUUPSDeploymentTest is Test {
    uint256 internal constant EIP170_LIMIT = 24_576;
    uint256 internal constant PROJECT_LIMIT = 23_552;
    uint256 internal constant EXPECTED_RUNTIME = 20_487;
    uint256 internal constant EXPECTED_INITCODE = 20_690;
    uint256 internal constant EXPECTED_PROXY_RUNTIME = 77;
    uint256 internal constant ETHEREUM_PINNED_BLOCK = 25_838_112;
    uint256 internal constant BASE_PINNED_BLOCK = 50_555_256;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_Local_CreateProxyInitializeAndUpgrade() public {
        _deployAndUpgrade();
    }

    function test_EthereumPinned_CreateProxyInitializeAndUpgrade() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, ETHEREUM_PINNED_BLOCK);
        assertEq(block.chainid, 1);
        _deployAndUpgrade();
    }

    function test_BasePinned_CreateProxyInitializeAndUpgrade() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, BASE_PINNED_BLOCK);
        assertEq(block.chainid, 8453);
        _deployAndUpgrade();
    }

    function test_FailedUpgradeMatrixRollsBackSlotAndLogicEpoch() public {
        (
            address implementation,
            CompactProbeCore core,
            CompactProbeCode usdc,
            CompactProbeCode metro,
            address proxy,
            XMetroDeFiAdapter adapter
        ) = _deployV1();
        bytes32 originalSlot = vm.load(proxy, IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(originalSlot))), implementation);
        address wrongFamily = address(new CompactWrongFamilyUUPS());
        address noUuid = address(new CompactNoUUID());
        address badUuid = address(new CompactBadUUID());

        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        XMetroDeFiAdapter(implementation).initialize(address(core), address(usdc), address(metro));

        core.setPaused(false);
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert(XMetroDeFiAdapter.AccessStateFailure.selector);
        adapter.upgradeToAndCall(wrongFamily, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.upgradeToAndCall(wrongFamily, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.upgradeToAndCall(implementation, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.upgradeToAndCall(wrongFamily, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.upgradeToAndCall(makeAddr("implementation-eoa"), bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        vm.expectRevert();
        adapter.upgradeToAndCall(noUuid, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        vm.expectRevert();
        adapter.upgradeToAndCall(badUuid, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        vm.expectRevert();
        adapter.upgradeToAndCall(proxy, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        bytes memory replacementInit =
            abi.encodeCall(XMetroDeFiAdapter.initialize, (address(core), address(usdc), address(metro)));
        address replacement = address(new ERC1967Proxy(implementation, replacementInit));
        core.setAdapter(replacement);
        address fullV2 = address(new XMetroDeFiAdapterV2());
        vm.expectRevert(XMetroDeFiAdapter.AccessStateFailure.selector);
        adapter.upgradeToAndCall(fullV2, bytes(""));
        _assertUpgradeUnchanged(proxy, adapter, originalSlot);

        core.setAdapter(proxy);
        adapter.upgradeToAndCall(fullV2, bytes(""));
        assertEq(adapter.logicEpoch(), 2);
        assertEq(adapter.implementationVersion(), 2);
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), fullV2);
        assertEq(adapter.xMETRO(), address(core));
        assertEq(adapter.USDC(), address(usdc));
        assertEq(adapter.METRO(), address(metro));
    }

    function _deployAndUpgrade() internal {
        bytes memory implementationInitCode = vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter");
        bytes memory implementationRuntime = vm.getDeployedCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter");
        assertEq(implementationInitCode.length, EXPECTED_INITCODE);
        assertEq(implementationRuntime.length, EXPECTED_RUNTIME);
        assertLe(implementationRuntime.length, PROJECT_LIMIT);
        assertLt(implementationRuntime.length, EIP170_LIMIT);

        address implementation = _create(implementationInitCode);
        assertTrue(implementation != address(0));
        assertEq(implementation.code.length, EXPECTED_RUNTIME);

        CompactProbeCore core = new CompactProbeCore(address(this));
        CompactProbeCode usdc = new CompactProbeCode();
        CompactProbeCode metro = new CompactProbeCode();
        bytes memory initData =
            abi.encodeCall(XMetroDeFiAdapter.initialize, (address(core), address(usdc), address(metro)));
        bytes memory proxyInitCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));
        address proxy = _create(proxyInitCode);
        assertTrue(proxy != address(0));
        core.setAdapter(proxy);
        core.setPaused(false);

        XMetroDeFiAdapter adapter = XMetroDeFiAdapter(proxy);
        assertEq(adapter.xMETRO(), address(core));
        assertEq(adapter.USDC(), address(usdc));
        assertEq(adapter.METRO(), address(metro));
        assertEq(adapter.logicEpoch(), 1);
        assertEq(adapter.implementationVersion(), 1);

        CompactProbeCode routerV2 = new CompactProbeCode();
        CompactProbeCode routerV3 = new CompactProbeCode();
        CompactProbeCode oneInchRouter = new CompactProbeCode();
        adapter.setRouters(address(routerV2), address(routerV3), address(oneInchRouter));

        bytes memory v2InitCode = vm.getCode("XMetroDeFiAdapter.uups.t.sol:CompactAdapterV2");
        address v2 = _create(v2InitCode);
        assertTrue(v2 != address(0));
        adapter.upgradeToAndCall(v2, bytes(""));
        assertFalse(core.paused());
        assertEq(adapter.logicEpoch(), 2);
        assertEq(adapter.implementationVersion(), 2);
        assertEq(proxy.code.length, EXPECTED_PROXY_RUNTIME);
        bytes32 namespace = 0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;
        assertEq(address(uint160(uint256(vm.load(proxy, bytes32(uint256(namespace) + 5))))), address(routerV2));
        assertEq(address(uint160(uint256(vm.load(proxy, bytes32(uint256(namespace) + 6))))), address(routerV3));
        assertEq(address(uint160(uint256(vm.load(proxy, bytes32(uint256(namespace) + 7))))), address(oneInchRouter));
    }

    function _deployV1()
        internal
        returns (
            address implementation,
            CompactProbeCore core,
            CompactProbeCode usdc,
            CompactProbeCode metro,
            address proxy,
            XMetroDeFiAdapter adapter
        )
    {
        implementation = _create(vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter"));
        core = new CompactProbeCore(address(this));
        usdc = new CompactProbeCode();
        metro = new CompactProbeCode();
        bytes memory initData =
            abi.encodeCall(XMetroDeFiAdapter.initialize, (address(core), address(usdc), address(metro)));
        proxy = address(new ERC1967Proxy(implementation, initData));
        core.setAdapter(proxy);
        adapter = XMetroDeFiAdapter(proxy);
    }

    function _assertUpgradeUnchanged(address proxy, XMetroDeFiAdapter adapter, bytes32 expectedImplementationSlot)
        internal
        view
    {
        assertEq(vm.load(proxy, IMPLEMENTATION_SLOT), expectedImplementationSlot);
        assertEq(adapter.logicEpoch(), 1);
        assertEq(adapter.implementationVersion(), 1);
    }

    function _create(bytes memory initCode) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
    }
}
