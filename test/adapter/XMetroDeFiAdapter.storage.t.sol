// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {XMetroDeFiAdapter} from "../../src/XMetroDeFiAdapter.sol";

contract NamespaceCode {}

contract NamespaceToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
}

contract NamespaceCore {
    address public owner;
    bool public paused = true;
    address public deFiAdapter;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAdapter(address adapter) external {
        deFiAdapter = adapter;
    }
}

contract NamespaceAdapterHarness is XMetroDeFiAdapter {
    function storageNamespace() external pure returns (bytes32) {
        return ADAPTER_STORAGE_LOCATION;
    }
}

contract XMetroDeFiAdapterStorageTest is Test {
    bytes32 internal constant EXPECTED_NAMESPACE = 0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;

    function test_Erc7201NamespaceFormulaAndHeaderCanaryAreFrozen() public {
        NamespaceCore core = new NamespaceCore(address(this));
        NamespaceToken usdc = new NamespaceToken("USD Coin", "USDC");
        NamespaceToken metro = new NamespaceToken("Metro", "METRO");
        NamespaceAdapterHarness implementation = new NamespaceAdapterHarness();
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(XMetroDeFiAdapter.initialize, (address(core), address(usdc), address(metro)))
            )
        );
        core.setAdapter(proxy);

        bytes32 derived = bytes32(
            uint256(keccak256(abi.encode(uint256(keccak256("xmetro.storage.XMetroDeFiAdapter")) - 1))) & ~uint256(0xff)
        );
        assertEq(derived, EXPECTED_NAMESPACE);
        assertEq(NamespaceAdapterHarness(proxy).storageNamespace(), EXPECTED_NAMESPACE);
        assertEq(address(uint160(uint256(vm.load(proxy, EXPECTED_NAMESPACE)))), address(core));
        assertEq(address(uint160(uint256(vm.load(proxy, bytes32(uint256(EXPECTED_NAMESPACE) + 1))))), address(usdc));

        uint256 metroAndEpoch = uint256(vm.load(proxy, bytes32(uint256(EXPECTED_NAMESPACE) + 2)));
        assertEq(address(uint160(metroAndEpoch)), address(metro));
        assertEq(uint64(metroAndEpoch >> 160), 1, "logicEpoch packing changed");
        assertEq(uint64(uint256(vm.load(proxy, bytes32(uint256(EXPECTED_NAMESPACE) + 3)))), 1, "domainRevision");
        assertEq(uint256(vm.load(proxy, bytes32(uint256(EXPECTED_NAMESPACE) + 4))), 1, "reentrancy status");

        NamespaceCode routerV2 = new NamespaceCode();
        NamespaceCode routerV3 = new NamespaceCode();
        NamespaceCode oneInchRouter = new NamespaceCode();
        NamespaceAdapterHarness(proxy).setRouters(address(routerV2), address(routerV3), address(oneInchRouter));
        assertEq(address(uint160(uint256(vm.load(proxy, bytes32(uint256(EXPECTED_NAMESPACE) + 5))))), address(routerV2));
        assertEq(address(uint160(uint256(vm.load(proxy, bytes32(uint256(EXPECTED_NAMESPACE) + 6))))), address(routerV3));
        assertEq(
            address(uint160(uint256(vm.load(proxy, bytes32(uint256(EXPECTED_NAMESPACE) + 7))))),
            address(oneInchRouter),
            "1inch Router storage position changed"
        );
    }
}
