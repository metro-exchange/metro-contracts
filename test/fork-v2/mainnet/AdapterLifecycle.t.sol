// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IXMetroDeFiAdapter} from "../../../src/interfaces/IXMetroDeFiAdapter.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase, IUniswapV2RouterMainnet} from "./MainnetForkBase.sol";

interface IAdapterLifecycleMainnet {
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
    function aaveV4Giver() external view returns (address);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function proxiableUUID() external view returns (bytes32);
}

interface ISpokeLifecycleMainnet {
    function setUserPositionManager(address manager, bool approved) external;
    function isPositionManagerActive(address manager) external view returns (bool);
    function isPositionManager(address user, address manager) external view returns (bool);
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
}

interface IMapleRouterLifecycleMainnet {
    function nonces(address lender) external view returns (uint256);
    function poolManager() external view returns (address);
    function poolPermissionManager() external view returns (address);
}

interface IMaplePermissionsLifecycleMainnet {
    function hasPermission(address manager, address lender, bytes32 permission) external view returns (bool);
}

contract WrongUUIDImplementation {
    function adapterFamilyId() external pure returns (bytes32) {
        return keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    }

    function proxiableUUID() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

contract WrongFamilyImplementation {
    function adapterFamilyId() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }
}

/// @notice E-21/E-22: Production Adapter Proxy configuration, permissions, versioning, and replacement.
contract AdapterLifecycleMainnetTest is MainnetForkBase {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADAPTER_NAMESPACE = 0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;
    bytes32 private constant P_DEPOSIT = bytes32("P:deposit");
    bytes32 private constant STRATEGY_DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant SUSHI_V2_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address private constant FOREX_SPOKE = 0xD8B93635b8C6d0fF98CbE90b5988E3F2d1Cd9da1;
    address private alice;
    address private bob;

    function setUp() public {
        _fork();
        _deploySystem();
        alice = makeAddr("lifecycle-alice");
        bob = makeAddr("lifecycle-bob");
    }

    function _strategy(IXMetroDeFiAdapter.StrategyKind kind, address output) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, STRATEGY_DOMAIN, kind, output));
    }

    function _route(address out, uint256 cap) private pure returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = out;
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), cap, abi.encode(path));
    }

    function _one(address user) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = user;
    }

    function _oneMinimum() private pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = 1;
    }

    function _newImplementation() private returns (address) {
        return _create(_artifact("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"));
    }

    function _newProxy() private returns (address newProxy) {
        address newImpl = _newImplementation();
        newProxy = address(
            new ERC1967Proxy(
                newImpl,
                abi.encodeWithSignature("initialize(address,address,address)", address(core), USDC, address(metro))
            )
        );
        assertGt(newProxy.code.length, 0);
        assertEq(address(uint160(uint256(vm.load(newProxy, IMPLEMENTATION_SLOT)))), newImpl);
    }

    function _mapleAuthorization(string memory path) private view returns (bytes memory) {
        string memory fixture = vm.readFile(path);
        return abi.encode(
            vm.parseJsonUint(fixture, ".bitmap"),
            vm.parseJsonUint(fixture, ".deadline"),
            uint8(vm.parseJsonUint(fixture, ".v")),
            vm.parseJsonBytes32(fixture, ".r"),
            vm.parseJsonBytes32(fixture, ".s")
        );
    }

    function _configureAll() private returns (bytes32 swapId, bytes32 v3Id, bytes32 v4Id, bytes32 mapleId) {
        _configureSwaps();
        swapId = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        v3Id = IXMetroAdapterAdminFork(proxy).setAaveV3Config(AAVE_V3_POOL, A_USDC, 37, true, true);
        IXMetroAdapterAdminFork(proxy).setAaveV4Config(V4_SPOKE, V4_GIVER, 7, true, true);
        v4Id = _strategy(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        mapleId = IXMetroAdapterAdminFork(proxy).setMapleConfig(MAPLE_ROUTER, bytes32(0), true, true);
    }

    function _assertAllConfigured(address target, uint64 expectedEpoch) private view {
        (
            address configuredCore,
            address usdc,
            address token,
            bytes32 family,
            uint64 epoch,
            address routerV2,
            address routerV3,
            address oneInch,
            IAdapterLifecycleMainnet.AaveV3Config memory v3,
            IAdapterLifecycleMainnet.AaveV4Config memory v4,
            IAdapterLifecycleMainnet.MapleConfig memory maple
        ) = IAdapterLifecycleMainnet(target).configuration();
        assertEq(configuredCore, address(core));
        assertEq(usdc, USDC);
        assertEq(token, address(metro));
        assertEq(family, adapter.adapterFamilyId());
        assertEq(epoch, expectedEpoch);
        assertEq(routerV2, V2_ROUTER);
        assertEq(routerV3, V3_ROUTER);
        assertEq(oneInch, ONEINCH_ROUTER);
        assertEq(v3.pool, AAVE_V3_POOL);
        assertEq(v3.aToken, A_USDC);
        assertEq(v3.referralCode, 37);
        assertEq(v4.spoke, V4_SPOKE);
        assertEq(v4.reserveId, 7);
        assertEq(IAdapterLifecycleMainnet(target).aaveV4Giver(), V4_GIVER);
        assertEq(maple.router, MAPLE_ROUTER);
        assertEq(maple.syrupToken, SYRUP_USDC);
        assertEq(maple.depositData, bytes32(0));
    }

    /// E-21.01/.02: Tests live config readback and revision rules.
    function test_E21_LiveConfigReadbackAndRevisionRules() public {
        core.unpause();
        (bytes32 swapId, bytes32 v3Id, bytes32 v4Id, bytes32 mapleId) = _configureAll();
        assertFalse(core.paused());
        (
            address configuredCore,
            address usdc,
            address token,
            bytes32 family,
            uint64 epoch,
            address routerV2,
            address routerV3,
            address oneInch,
            IAdapterLifecycleMainnet.AaveV3Config memory v3,
            IAdapterLifecycleMainnet.AaveV4Config memory v4,
            IAdapterLifecycleMainnet.MapleConfig memory maple
        ) = IAdapterLifecycleMainnet(proxy).configuration();
        assertEq(configuredCore, address(core));
        assertEq(usdc, USDC);
        assertEq(token, address(metro));
        assertEq(family, adapter.adapterFamilyId());
        assertEq(epoch, 1);
        assertEq(routerV2, V2_ROUTER);
        assertEq(routerV3, V3_ROUTER);
        assertEq(oneInch, ONEINCH_ROUTER);
        assertEq(v3.pool, AAVE_V3_POOL);
        assertEq(v3.aToken, A_USDC);
        assertEq(v3.referralCode, 37);
        assertEq(v4.spoke, V4_SPOKE);
        assertEq(v4.reserveId, 7);
        assertEq(IAdapterLifecycleMainnet(proxy).aaveV4Giver(), V4_GIVER);
        assertEq(maple.router, MAPLE_ROUTER);
        assertEq(maple.syrupToken, SYRUP_USDC);
        assertEq(maple.depositData, bytes32(0));
        assertTrue(adapter.strategyInfo(swapId).enabled);
        assertTrue(adapter.strategyInfo(v3Id).enabled);
        assertTrue(adapter.strategyInfo(v4Id).enabled);
        assertTrue(adapter.strategyInfo(mapleId).enabled);
        vm.expectRevert();
        IXMetroAdapterAdminFork(proxy).setRouters(V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        vm.expectRevert();
        IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        vm.expectRevert();
        IXMetroAdapterAdminFork(proxy).setAaveV3Config(AAVE_V3_POOL, A_USDC, 37, true, true);
        vm.expectRevert();
        IXMetroAdapterAdminFork(proxy).setAaveV4Config(V4_SPOKE, V4_GIVER, 7, true, true);
        vm.expectRevert();
        IXMetroAdapterAdminFork(proxy).setMapleConfig(MAPLE_ROUTER, bytes32(0), true, true);
    }

    /// E-21.02/.03: Tests disable deposit strategies advances own revisions.
    function test_E21_DisableDepositStrategiesAdvancesOwnRevisions() public {
        (, bytes32 v3Id, bytes32 v4Id, bytes32 mapleId) = _configureAll();
        uint64 v3Revision = adapter.strategyInfo(v3Id).strategyRevision;
        uint64 v4Revision = adapter.strategyInfo(v4Id).strategyRevision;
        uint64 mapleRevision = adapter.strategyInfo(mapleId).strategyRevision;
        IXMetroAdapterAdminFork(proxy).setAaveV3Config(address(0), address(0), 0, false, false);
        IXMetroAdapterAdminFork(proxy).setAaveV3Config(address(0), address(0), 0, false, false);
        IXMetroAdapterAdminFork(proxy).setAaveV4Config(address(0), address(0), 0, false, false);
        IXMetroAdapterAdminFork(proxy).setAaveV4Config(address(0), address(0), 0, false, false);
        IXMetroAdapterAdminFork(proxy).setMapleConfig(address(0), bytes32(0), false, false);
        IXMetroAdapterAdminFork(proxy).setMapleConfig(address(0), bytes32(0), false, false);
        assertEq(adapter.strategyInfo(v3Id).strategyRevision, v3Revision + 2);
        assertEq(adapter.strategyInfo(v4Id).strategyRevision, v4Revision + 2);
        assertEq(adapter.strategyInfo(mapleId).strategyRevision, mapleRevision + 2);
        assertFalse(adapter.strategyInfo(v3Id).enabled);
        assertFalse(adapter.strategyInfo(v4Id).enabled);
        assertFalse(adapter.strategyInfo(mapleId).enabled);
    }

    /// E-21.04: Tests only current operational core can execute.
    function test_E21_OnlyCurrentOperationalCoreCanExecute() public {
        _configureAll();
        core.unpause();
        IXMetroDeFiAdapter.ManualExecution memory manual = IXMetroDeFiAdapter.ManualExecution({
            strategyId: _strategy(IXMetroDeFiAdapter.StrategyKind.AutoSwap, WETH),
            account: alice,
            amountIn: 1,
            minAmountOut: 1,
            deadline: block.timestamp + 1 hours,
            executionData: _route(WETH, 1)
        });
        IXMetroDeFiAdapter.BatchExecution memory batch = IXMetroDeFiAdapter.BatchExecution({
            strategyId: manual.strategyId,
            accounts: _one(alice),
            amountsIn: new uint256[](1),
            minTotalAmountOut: 1,
            minUserAmountsOut: new uint256[](0),
            deadline: block.timestamp + 1 hours,
            executionData: _route(WETH, 1)
        });
        batch.amountsIn[0] = 1;
        vm.prank(alice);
        vm.expectRevert();
        adapter.execute(manual);
        vm.prank(bob);
        vm.expectRevert();
        adapter.executeBatch(batch);
        core.pause();
        vm.prank(address(core));
        vm.expectRevert();
        adapter.execute(manual);
        vm.prank(address(core));
        vm.expectRevert();
        adapter.executeBatch(batch);
        core.unpause();
        vm.prank(address(core));
        vm.expectRevert(); // Authority is valid, but the Adapter has no USDC input.
        adapter.execute(manual);
        assertEq(IERC20(USDC).balanceOf(proxy), 0);
    }

    /// E-21.05: Tests single step owner authority and upgrade.
    function test_E21_SingleStepOwnerAuthorityAndUpgrade() public {
        address nextOwner = makeAddr("lifecycle-next-owner");
        address nextImpl = _newImplementation();
        core.transferOwnership(nextOwner);
        assertEq(core.owner(), nextOwner);
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(nextImpl, "");
        vm.expectRevert();
        IXMetroAdapterAdminFork(proxy).setRouters(V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        vm.prank(nextOwner);
        IXMetroAdapterAdminFork(proxy).setRouters(V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        vm.prank(nextOwner);
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(nextImpl, "");
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), nextImpl);
        assertEq(adapter.logicEpoch(), 2);
    }

    /// E-21.06/.07: Tests manual auto flags and preference separation.
    function test_E21_ManualAutoFlagsAndPreferenceSeparation() public {
        _configureSwaps();
        bytes32 swap = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, false);
        core.unpause();
        _mintAndStake(alice, 1 ether);
        _distribute(100e6);
        vm.prank(alice);
        vm.expectRevert();
        core.enableAutoStrategy(swap);
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            swap, _one(alice), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 100e6)
        );
        vm.prank(alice);
        (uint256 used, uint256 wethOut) = core.claimAndExecute(swap, 1, block.timestamp + 1 hours, _route(WETH, 100e6));
        assertEq(used, 100e6);
        assertGt(wethOut, 0);
        assertEq(core.getAutoStrategyPreference(alice).strategyId, bytes32(0));
        IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, false, false);
        _distribute(100e6);
        vm.prank(alice);
        vm.expectRevert();
        core.claimAndExecute(swap, 1, block.timestamp + 1 hours, _route(WETH, 100e6));
        IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        vm.prank(alice);
        core.enableAutocompound();
        assertTrue(core.autocompoundEnabled(alice));
        vm.prank(alice);
        core.disableAutoStrategy();
        assertTrue(core.autocompoundEnabled(alice));
        vm.prank(alice);
        core.enableAutoStrategy(swap);
        assertFalse(core.autocompoundEnabled(alice));
        assertEq(core.getAutoStrategyPreference(alice).strategyId, swap);
        vm.prank(alice);
        core.disableAutocompound();
        assertEq(core.getAutoStrategyPreference(alice).strategyId, swap);
        vm.prank(alice);
        core.claimAndExecute(swap, 1, block.timestamp + 1 hours, _route(WETH, 100e6));
        assertEq(core.getAutoStrategyPreference(alice).strategyId, swap);
    }

    /// E-21.08: Tests strategy and router revision expire only affected users.
    function test_E21_StrategyAndRouterRevisionExpireOnlyAffectedUsers() public {
        _configureSwaps();
        bytes32 weth = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        bytes32 usdt = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(USDT, true, true);
        core.unpause();
        _mintAndStake(alice, 1 ether);
        _mintAndStake(bob, 1 ether);
        vm.prank(alice);
        core.enableAutoStrategy(weth);
        vm.prank(bob);
        core.enableAutoStrategy(usdt);
        _distribute(100e6);
        uint64 bobRevision = core.getAutoStrategyPreference(bob).strategyRevision;
        IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, false);
        assertEq(core.getAutoStrategyPreference(bob).strategyRevision, bobRevision);
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            weth, _one(alice), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 50e6)
        );
        assertEq(core.claimable(alice), 50e6);
        uint256 quote = IUniswapV2RouterMainnet(V2_ROUTER).getAmountsOut(50e6, _directUsdt())[1];
        (uint256 input, uint256 output) = core.executeAutoStrategyBatch(
            usdt, _one(bob), 1, new uint256[](0), block.timestamp + 1 hours, _route(USDT, 50e6)
        );
        assertEq(input, 50e6);
        assertEq(output, quote);
        _distribute(100e6);
        // Advance the domain revision with another real Router set without changing strategy revisions.
        IXMetroAdapterAdminFork(proxy).setRouters(V3_ROUTER, V2_ROUTER, ONEINCH_ROUTER);
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            usdt, _one(bob), 1, new uint256[](0), block.timestamp + 1 hours, _route(USDT, 50e6)
        );
        assertEq(core.claimable(bob), 50e6);
        assertEq(core.claimable(alice), 100e6);
    }

    /// E-21.08: Tests logic epoch invalidates auto but manual still executes.
    function test_E21_LogicEpochInvalidatesAutoButManualStillExecutes() public {
        _configureSwaps();
        bytes32 swap = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        core.unpause();
        _mintAndStake(alice, 1 ether);
        vm.prank(alice);
        core.enableAutoStrategy(swap);
        _distribute(100e6);
        uint64 priorEpoch = adapter.logicEpoch();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(_newImplementation(), "");
        assertEq(adapter.logicEpoch(), priorEpoch + 1);
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            swap, _one(alice), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 100e6)
        );
        assertEq(core.claimable(alice), 100e6);
        vm.prank(alice);
        (uint256 input, uint256 output) = core.claimAndExecute(swap, 1, block.timestamp + 1 hours, _route(WETH, 100e6));
        assertEq(input, 100e6);
        assertGt(output, 0);
        _distribute(100e6);
        vm.prank(alice);
        core.enableAutoStrategy(swap);
        (input, output) = core.executeAutoStrategyBatch(
            swap, _one(alice), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 100e6)
        );
        assertEq(input, 100e6);
        assertGt(output, 0);
    }

    /// E-21.01: Tests real router change executes on new router.
    function test_E21_RealRouterChangeExecutesOnNewRouter() public {
        _configureSwaps();
        bytes32 swap = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        core.unpause();
        _mintAndStake(alice, 1 ether);
        _distribute(100e6);
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;
        uint256 quote = IUniswapV2RouterMainnet(SUSHI_V2_ROUTER).getAmountsOut(100e6, path)[1];
        assertGt(quote, 0);
        IXMetroAdapterAdminFork(proxy).setRouters(SUSHI_V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        (,,,,, address configuredV2,,,,,) = IAdapterLifecycleMainnet(proxy).configuration();
        assertEq(configuredV2, SUSHI_V2_ROUTER);
        vm.prank(alice);
        (uint256 rewardIn, uint256 output) =
            core.claimAndExecute(swap, quote * 99 / 100, block.timestamp + 1 hours, _route(WETH, 100e6));
        assertEq(rewardIn, 100e6);
        assertEq(output, quote);
        assertEq(IERC20(WETH).balanceOf(alice), quote);
        assertEq(IERC20(USDC).allowance(proxy, SUSHI_V2_ROUTER), 0);
    }

    /// E-21.01/.08: Tests real V4 spoke change only expires V4 and needs new permission.
    function test_E21_RealV4SpokeChangeOnlyExpiresV4AndNeedsNewPermission() public {
        (bytes32 swap,, bytes32 v4Id,) = _configureAll();
        assertTrue(ISpokeLifecycleMainnet(FOREX_SPOKE).isPositionManagerActive(V4_GIVER));
        core.unpause();
        _mintAndStake(alice, 1 ether);
        _mintAndStake(bob, 1 ether);
        vm.prank(alice);
        ISpokeLifecycleMainnet(V4_SPOKE).setUserPositionManager(V4_GIVER, true);
        vm.prank(alice);
        core.enableAutoStrategy(v4Id);
        vm.prank(bob);
        core.enableAutoStrategy(swap);
        _distribute(100e6);
        uint64 swapRevision = core.getAutoStrategyPreference(bob).strategyRevision;
        IXMetroAdapterAdminFork(proxy).setAaveV4Config(FOREX_SPOKE, V4_GIVER, 1, true, true);
        assertEq(IAdapterLifecycleMainnet(proxy).aaveV4Giver(), V4_GIVER);
        assertEq(core.getAutoStrategyPreference(bob).strategyRevision, swapRevision);
        vm.expectRevert();
        core.executeAutoStrategyBatch(v4Id, _one(alice), 1, _oneMinimum(), 0, "");
        assertEq(core.claimable(alice), 50e6);
        (uint256 swapInput, uint256 swapOutput) = core.executeAutoStrategyBatch(
            swap, _one(bob), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 50e6)
        );
        assertEq(swapInput, 50e6);
        assertGt(swapOutput, 0);
        vm.prank(alice);
        core.enableAutoStrategy(v4Id);
        assertFalse(ISpokeLifecycleMainnet(FOREX_SPOKE).isPositionManager(alice, V4_GIVER));
        vm.expectRevert();
        core.executeAutoStrategyBatch(v4Id, _one(alice), 1, _oneMinimum(), 0, "");
        assertEq(core.claimable(alice), 50e6);
        vm.prank(alice);
        ISpokeLifecycleMainnet(FOREX_SPOKE).setUserPositionManager(V4_GIVER, true);
        uint256 beforeShares = ISpokeLifecycleMainnet(FOREX_SPOKE).getUserSuppliedShares(1, alice);
        (uint256 v4Input, uint256 v4Shares) = core.executeAutoStrategyBatch(v4Id, _one(alice), 1, _oneMinimum(), 0, "");
        assertEq(v4Input, 50e6);
        assertEq(ISpokeLifecycleMainnet(FOREX_SPOKE).getUserSuppliedShares(1, alice) - beforeShares, v4Shares);
        assertEq(ISpokeLifecycleMainnet(V4_SPOKE).getUserSuppliedShares(7, alice), 0);
    }

    function _directUsdt() private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;
    }

    /// E-22.01/.02: Tests UUPS storage and failure matrix.
    function test_E22_UupsStorageAndFailureMatrix() public {
        (bytes32 swap,, bytes32 v4Id, bytes32 mapleId) = _configureAll();
        _fundUSDC(proxy, 5e6);
        bytes32 namespaceBefore = vm.load(proxy, ADAPTER_NAMESPACE);
        uint64 epochBefore = adapter.logicEpoch();
        address currentImplementation = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        assertEq(currentImplementation, implementation);
        assertEq(IAdapterLifecycleMainnet(implementation).proxiableUUID(), IMPLEMENTATION_SLOT);
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).proxiableUUID();
        address nextImpl = _newImplementation();
        address wrongUuidImpl = address(new WrongUUIDImplementation());
        address wrongFamilyImpl = address(new WrongFamilyImplementation());
        vm.prank(alice);
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(nextImpl, "");
        vm.expectRevert();
        IAdapterLifecycleMainnet(implementation).upgradeToAndCall(nextImpl, "");
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(implementation, "");
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(address(metro), "");
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(wrongUuidImpl, "");
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(wrongFamilyImpl, "");
        vm.expectRevert();
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(address(0), "");
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), implementation);
        assertEq(adapter.logicEpoch(), epochBefore);
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(nextImpl, "");
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), nextImpl);
        assertEq(adapter.logicEpoch(), epochBefore + 1);
        assertEq(vm.load(proxy, ADAPTER_NAMESPACE), namespaceBefore);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertTrue(adapter.strategyInfo(swap).enabled);
        assertTrue(adapter.strategyInfo(v4Id).enabled);
        assertTrue(adapter.strategyInfo(mapleId).enabled);
        assertEq(IAdapterLifecycleMainnet(proxy).aaveV4Giver(), V4_GIVER);
    }

    /// E-22.03: Tests UUPS keeps real giver and Maple authorizations.
    function test_E22_UupsKeepsRealGiverAndMapleAuthorizations() public {
        (,, bytes32 v4Id, bytes32 mapleId) = _configureAll();
        string memory oldFixture =
            "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/maple-api-response.json";
        core.unpause();
        _mintAndStake(alice, 1 ether);
        _mintAndStake(bob, 1 ether);
        vm.prank(alice);
        ISpokeLifecycleMainnet(V4_SPOKE).setUserPositionManager(V4_GIVER, true);
        _distribute(100e6);
        vm.prank(bob);
        (uint256 mapleInput,) = core.claimAndExecute(mapleId, 1, 0, _mapleAuthorization(oldFixture));
        assertEq(mapleInput, 50e6);
        assertTrue(
            IMaplePermissionsLifecycleMainnet(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).poolPermissionManager())
                .hasPermission(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).poolManager(), proxy, P_DEPOSIT)
        );
        uint256 nonceAfterAuth = IMapleRouterLifecycleMainnet(MAPLE_ROUTER).nonces(proxy);
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(_newImplementation(), "");
        assertTrue(ISpokeLifecycleMainnet(V4_SPOKE).isPositionManager(alice, V4_GIVER));
        _distribute(100e6);
        uint256 beforeV4 = ISpokeLifecycleMainnet(V4_SPOKE).getUserSuppliedShares(7, alice);
        vm.prank(alice);
        (uint256 v4Input, uint256 v4Shares) = core.claimAndExecute(v4Id, 1, 0, "");
        assertEq(v4Input, 100e6);
        assertEq(ISpokeLifecycleMainnet(V4_SPOKE).getUserSuppliedShares(7, alice) - beforeV4, v4Shares);
        uint256 beforeMaple = IERC20(SYRUP_USDC).balanceOf(bob);
        vm.prank(bob);
        uint256 syrupShares;
        (mapleInput, syrupShares) = core.claimAndExecute(mapleId, 1, 0, "");
        assertEq(mapleInput, 50e6);
        assertEq(IERC20(SYRUP_USDC).balanceOf(bob) - beforeMaple, syrupShares);
        assertEq(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).nonces(proxy), nonceAfterAuth);
    }

    /// E-22.04/.05: Tests whole Proxy replacement and old Proxy rescue.
    function test_E22_WholeProxyReplacementAndOldProxyRescue() public {
        (bytes32 oldSwap,,,) = _configureAll();
        core.unpause();
        _mintAndStake(alice, 1 ether);
        vm.prank(alice);
        core.enableAutoStrategy(oldSwap);
        _fundUSDC(proxy, 5e6);
        uint64 priorEpoch = core.deFiAdapterEpoch();
        core.pause();
        address oldProxy = proxy;
        address newProxy = _newProxy();
        emit log_named_address("replacement Proxy for Maple signer", newProxy);
        core.setDeFiAdapter(newProxy);
        assertEq(core.deFiAdapter(), newProxy);
        assertEq(core.deFiAdapterEpoch(), priorEpoch + 1);
        vm.expectRevert();
        IXMetroAdapterAdminFork(oldProxy).setRouters(V3_ROUTER, V2_ROUTER, ONEINCH_ROUTER);
        address spareImpl = _newImplementation();
        vm.expectRevert();
        IAdapterLifecycleMainnet(oldProxy).upgradeToAndCall(spareImpl, "");
        address rescueRecipient = makeAddr("retired-adapter-rescue");
        (bool rescueOk,) =
            oldProxy.call(abi.encodeWithSignature("rescueERC20(address,address,uint256)", USDC, rescueRecipient, 5e6));
        assertTrue(rescueOk);
        assertEq(IERC20(USDC).balanceOf(rescueRecipient), 5e6);
        IXMetroAdapterAdminFork(newProxy).setRouters(V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        bytes32 swap = IXMetroAdapterAdminFork(newProxy).setSwapTokenConfig(WETH, true, true);
        core.unpause();
        _distribute(100e6);
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            swap, _one(alice), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 100e6)
        );
        assertEq(core.claimable(alice), 100e6);
        vm.prank(address(core));
        vm.expectRevert();
        IXMetroDeFiAdapter(oldProxy)
            .execute(
                IXMetroDeFiAdapter.ManualExecution({
                strategyId: swap,
                account: alice,
                amountIn: 1,
                minAmountOut: 1,
                deadline: block.timestamp + 1 hours,
                executionData: _route(WETH, 100e6)
            })
            );
        vm.prank(alice);
        (uint256 input, uint256 output) = core.claimAndExecute(swap, 1, block.timestamp + 1 hours, _route(WETH, 100e6));
        assertEq(input, 100e6);
        assertGt(output, 0);
        assertEq(IERC20(USDC).balanceOf(newProxy), 0);
    }

    /// E-22.06: Tests replacement keeps giver permission but requires new Maple signature.
    function test_E22_ReplacementKeepsGiverPermissionButRequiresNewMapleSignature() public {
        _configureAll();
        core.unpause();
        _mintAndStake(alice, 1 ether);
        _mintAndStake(bob, 1 ether);
        vm.prank(alice);
        ISpokeLifecycleMainnet(V4_SPOKE).setUserPositionManager(V4_GIVER, true);
        assertTrue(ISpokeLifecycleMainnet(V4_SPOKE).isPositionManager(alice, V4_GIVER));
        core.pause();
        address oldProxy = proxy;
        address newProxy = _newProxy();
        string memory oldFixture =
            "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/maple-api-response.json";
        string memory newFixture =
            "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/maple-new-proxy-api-response.json";
        assertEq(vm.parseJsonAddress(vm.readFile(oldFixture), ".lender"), oldProxy);
        assertEq(vm.parseJsonAddress(vm.readFile(newFixture), ".lender"), newProxy);
        core.setDeFiAdapter(newProxy);
        proxy = newProxy;
        adapter = IXMetroDeFiAdapter(newProxy);
        (,, bytes32 v4Id, bytes32 mapleId) = _configureAll();
        core.unpause();
        _distribute(200e6);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.claimable(bob), 100e6);
        uint256 beforeV4 = ISpokeLifecycleMainnet(V4_SPOKE).getUserSuppliedShares(7, alice);
        vm.prank(alice);
        (uint256 v4Input, uint256 v4Shares) = core.claimAndExecute(v4Id, 1, 0, "");
        assertEq(v4Input, 100e6);
        assertEq(ISpokeLifecycleMainnet(V4_SPOKE).getUserSuppliedShares(7, alice) - beforeV4, v4Shares);
        uint256 nonceBefore = IMapleRouterLifecycleMainnet(MAPLE_ROUTER).nonces(newProxy);
        vm.prank(bob);
        vm.expectRevert();
        core.claimAndExecute(mapleId, 1, 0, _mapleAuthorization(oldFixture));
        assertEq(core.claimable(bob), 100e6);
        assertEq(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).nonces(newProxy), nonceBefore);
        uint256 syrupBefore = IERC20(SYRUP_USDC).balanceOf(bob);
        vm.prank(bob);
        (uint256 mapleInput, uint256 syrupShares) = core.claimAndExecute(mapleId, 1, 0, _mapleAuthorization(newFixture));
        assertEq(mapleInput, 100e6);
        assertGt(syrupShares, 0);
        assertEq(IERC20(SYRUP_USDC).balanceOf(bob) - syrupBefore, syrupShares);
        assertEq(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).nonces(newProxy), nonceBefore + 1);
        assertTrue(
            IMaplePermissionsLifecycleMainnet(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).poolPermissionManager())
                .hasPermission(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).poolManager(), newProxy, P_DEPOSIT)
        );
        assertFalse(
            IMaplePermissionsLifecycleMainnet(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).poolPermissionManager())
                .hasPermission(IMapleRouterLifecycleMainnet(MAPLE_ROUTER).poolManager(), oldProxy, P_DEPOSIT)
        );
    }

    /// X-05: Tests full configuration and preference across upgrade and replacement.
    function test_X05_FullConfigurationAndPreferenceAcrossUpgradeAndReplacement() public {
        (bytes32 swapId, bytes32 v3Id, bytes32 v4Id, bytes32 mapleId) = _configureAll();
        _assertAllConfigured(proxy, 1);
        core.unpause();
        _mintAndStake(alice, 1 ether);
        vm.prank(alice);
        core.enableAutoStrategy(swapId);
        vm.prank(alice);
        ISpokeLifecycleMainnet(V4_SPOKE).setUserPositionManager(V4_GIVER, true);
        _distribute(100e6);
        assertEq(core.claimable(alice), 100e6);
        uint64 adapterEpochBefore = core.deFiAdapterEpoch();
        uint64 domainBefore = adapter.strategyInfo(swapId).domainRevision;
        uint64 swapRevisionBefore = adapter.strategyInfo(swapId).strategyRevision;
        uint64 v3RevisionBefore = adapter.strategyInfo(v3Id).strategyRevision;
        uint64 v4RevisionBefore = adapter.strategyInfo(v4Id).strategyRevision;
        uint64 mapleRevisionBefore = adapter.strategyInfo(mapleId).strategyRevision;
        IAdapterLifecycleMainnet(proxy).upgradeToAndCall(_newImplementation(), "");
        _assertAllConfigured(proxy, 2);
        assertEq(adapter.strategyInfo(swapId).domainRevision, domainBefore);
        assertEq(adapter.strategyInfo(swapId).strategyRevision, swapRevisionBefore);
        assertEq(adapter.strategyInfo(v3Id).strategyRevision, v3RevisionBefore);
        assertEq(adapter.strategyInfo(v4Id).strategyRevision, v4RevisionBefore);
        assertEq(adapter.strategyInfo(mapleId).strategyRevision, mapleRevisionBefore);
        assertEq(core.getAutoStrategyPreference(alice).strategyId, swapId);
        assertEq(core.getAutoStrategyPreference(alice).logicEpoch, 1);
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            swapId, _one(alice), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 100e6)
        );
        assertEq(core.claimable(alice), 100e6);
        core.pause();
        address newProxy = _newProxy();
        core.setDeFiAdapter(newProxy);
        proxy = newProxy;
        adapter = IXMetroDeFiAdapter(newProxy);
        (bytes32 newSwap, bytes32 newV3, bytes32 newV4, bytes32 newMaple) = _configureAll();
        _assertAllConfigured(newProxy, 1);
        assertEq(newSwap, swapId);
        assertEq(newV3, v3Id);
        assertEq(newV4, v4Id);
        assertEq(newMaple, mapleId);
        assertEq(core.deFiAdapterEpoch(), adapterEpochBefore + 1);
        assertEq(core.getAutoStrategyPreference(alice).adapterEpoch, adapterEpochBefore);
        assertTrue(ISpokeLifecycleMainnet(V4_SPOKE).isPositionManager(alice, V4_GIVER));
        core.unpause();
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            newSwap, _one(alice), 1, new uint256[](0), block.timestamp + 1 hours, _route(WETH, 100e6)
        );
        assertEq(core.claimable(alice), 100e6);
    }
}
