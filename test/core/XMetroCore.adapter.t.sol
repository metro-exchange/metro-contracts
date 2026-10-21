// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockAaveV4Giver} from "../mocks/MockAaveV4Giver.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {xMETRO} from "../../src/xMETRO.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {MockOneInchExecutor, MockOneInchRouter} from "../mocks/MockOneInchRouter.sol";

interface ICoreAdapterConfiguration {
    function setRouters(address routerV2, address routerV3, address oneInchRouter) external;
    function setSwapMetroConfig(bool enabled, bool autoEnabled) external;
    function setSwapTokenConfig(address tokenOut, bool enabled, bool autoEnabled) external returns (bytes32 id);
    function setAaveV4Config(address spoke, address giver, uint256 reserveId, bool enabled, bool autoEnabled) external;
}

interface ICoreUUPSUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract CoreFlowToken is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract CoreV2Router {
    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address receiver, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn));
        CoreFlowToken(path[path.length - 1]).mint(receiver, amountIn);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }
}

contract CoreMisreportingV2Router {
    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address receiver, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn));
        CoreFlowToken(path[path.length - 1]).mint(receiver, amountIn);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn + 1;
    }
}

contract CoreAaveV4Spoke {
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    IERC20 public immutable asset;
    uint256 public immutable reserveId;
    mapping(address => bool) public active;
    mapping(address => mapping(address => bool)) public authorized;
    mapping(uint256 => mapping(address => uint256)) public shares;

    constructor(address asset_, uint256 reserveId_) {
        asset = IERC20(asset_);
        reserveId = reserveId_;
    }

    function setActive(address manager, bool value) external {
        active[manager] = value;
    }

    function setAuthorized(address user, address manager, bool value) external {
        authorized[user][manager] = value;
    }

    function getReserve(uint256 id) external view returns (Reserve memory reserve) {
        require(id == reserveId);
        reserve.underlying = address(asset);
        reserve.decimals = 6;
    }

    function getUserSuppliedShares(uint256 id, address user) external view returns (uint256) {
        return shares[id][user];
    }

    function isPositionManagerActive(address manager) external view returns (bool) {
        return active[manager];
    }

    function isPositionManager(address user, address manager) external view returns (bool) {
        return authorized[user][manager];
    }

    function supply(uint256 id, uint256 amount, address onBehalfOf)
        external
        returns (uint256 suppliedShares, uint256 suppliedAssets)
    {
        require(id == reserveId && active[msg.sender] && authorized[onBehalfOf][msg.sender]);
        require(asset.transferFrom(msg.sender, address(this), amount));
        shares[id][onBehalfOf] += amount;
        return (amount, amount);
    }
}

contract CoreCode {}

contract CoreRewardSource {
    xMETRO public immutable core;
    IERC20 public immutable rewardToken;

    constructor(xMETRO core_, IERC20 rewardToken_) {
        core = core_;
        rewardToken = rewardToken_;
    }

    function xMETRO() external view returns (address) {
        return address(core);
    }

    function deposit(uint256 amount) external {
        rewardToken.approve(address(core), amount);
        core.depositRewards(amount);
    }
}

contract XMetroCoreSizeTest is Test {
    uint256 internal constant EIP170_LIMIT = 24_576;
    uint256 internal constant PROJECT_LIMIT = 23_552;
    uint256 internal constant EXPECTED_RUNTIME = 22_921;
    uint256 internal constant EXPECTED_INITCODE = 24_500;
    uint256 internal constant ETHEREUM_PINNED_BLOCK = 25_838_112;
    uint256 internal constant BASE_PINNED_BLOCK = 50_555_256;

    function test_Local_CreateFinalCoreUnderEIP170() public {
        _deployAndAssertCore();
    }

    function test_EthereumPinned_CreateFinalCoreUnderEIP170() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, ETHEREUM_PINNED_BLOCK);
        assertEq(block.chainid, 1);
        _deployAndAssertCore();
    }

    function test_BasePinned_CreateFinalCoreUnderEIP170() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, BASE_PINNED_BLOCK);
        assertEq(block.chainid, 8453);
        _deployAndAssertCore();
    }

    function _deployAndAssertCore() private {
        CoreFlowToken metro = new CoreFlowToken("Metro", "METRO", 18);
        CoreFlowToken usdc = new CoreFlowToken("USD Coin", "USDC", 6);
        bytes memory baseInitCode = vm.getCode("xMETRO.sol:xMETRO");
        bytes memory runtime = vm.getDeployedCode("xMETRO.sol:xMETRO");
        assertEq(baseInitCode.length, EXPECTED_INITCODE);
        assertEq(runtime.length, EXPECTED_RUNTIME);
        assertLe(runtime.length, PROJECT_LIMIT);
        assertLt(runtime.length, EIP170_LIMIT);
        bytes memory initCode = abi.encodePacked(
            baseInitCode, abi.encode(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000)
        );
        address deployed = _create(initCode);
        assertTrue(deployed != address(0));
        assertEq(deployed.code.length, EXPECTED_RUNTIME);
        assertFalse(xMETRO(deployed).paused());
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
    }
}

contract XMetroCoreAdapterFlowTest is Test {
    uint256 internal constant ADAPTER_RUNTIME = 20_487;

    CoreFlowToken internal metro;
    CoreFlowToken internal usdc;
    CoreFlowToken internal output;
    CoreV2Router internal router;
    MockOneInchRouter internal oneInch;
    MockOneInchExecutor internal oneInchExecutor;
    xMETRO internal core;
    IXMetroDeFiAdapter internal adapter;
    CoreRewardSource internal rewardSource;
    bytes32 internal swapStrategy;

    function setUp() public {
        metro = new CoreFlowToken("Metro", "METRO", 18);
        usdc = new CoreFlowToken("USD Coin", "USDC", 6);
        output = new CoreFlowToken("Output", "OUT", 6);
        router = new CoreV2Router();
        oneInch = new MockOneInchRouter();
        oneInchExecutor = new MockOneInchExecutor();
        core = _deployCore();

        bytes memory implementationInitCode = _adapterInitCode();
        address implementation = _create(implementationInitCode);
        assertEq(implementation.code.length, ADAPTER_RUNTIME);
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)", address(core), address(usdc), address(metro)
        );
        address proxy = address(new ERC1967Proxy(implementation, initData));
        adapter = IXMetroDeFiAdapter(proxy);
        core.setDeFiAdapter(proxy);

        rewardSource = new CoreRewardSource(core, usdc);
        core.setRewardDistributor(address(rewardSource));
        core.setAutoCompoundOperator(address(this), true);

        ICoreAdapterConfiguration configuration = ICoreAdapterConfiguration(proxy);
        configuration.setRouters(address(router), address(new CoreCode()), address(oneInch));
        configuration.setSwapMetroConfig(true, true);
        swapStrategy = configuration.setSwapTokenConfig(address(output), true, true);
        metro.mint(address(oneInch), 1_000_000 ether);
        output.mint(address(oneInch), 1_000_000e6);
    }

    function test_CoreManualClaimUsesFinalProxyAndFixedRecipient() public {
        address user = makeAddr("manual-user");
        _stake(user, 100e18);
        _depositRewards(100e6);

        vm.prank(user);
        (uint256 rewardIn, uint256 amountOut) =
            core.claimAndExecute(swapStrategy, 100e6, block.timestamp + 1, _oneInchData(address(output), 100e6));

        assertEq(rewardIn, 100e6);
        assertEq(amountOut, 100e6);
        assertEq(output.balanceOf(user), 100e6);
        assertEq(core.claimable(user), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function test_CoreAutoSwapBatchFiltersAndForwardsAlignedArrays() public {
        address[] memory users = new address[](2);
        users[0] = makeAddr("batch-a");
        users[1] = makeAddr("batch-b");
        _stake(users[0], 100e18);
        _stake(users[1], 100e18);
        vm.prank(users[0]);
        core.enableAutoStrategy(swapStrategy);
        vm.prank(users[1]);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(100e6);

        (uint256 rewardIn, uint256 amountOut) = core.executeAutoStrategyBatch(
            swapStrategy, users, 100e6, new uint256[](0), block.timestamp + 1, _oneInchData(address(output), 100e6)
        );

        assertEq(rewardIn, 100e6);
        assertEq(amountOut, 100e6);
        assertEq(output.balanceOf(users[0]), 50e6);
        assertEq(output.balanceOf(users[1]), 50e6);
        assertEq(core.claimable(users[0]), 0);
        assertEq(core.claimable(users[1]), 0);
    }

    function test_CoreLegacyAutoCompoundBatchUsesSwapMetroAndMintsShares() public {
        address[] memory users = new address[](2);
        users[0] = makeAddr("compound-a");
        users[1] = makeAddr("compound-b");
        _stake(users[0], 100e18);
        _stake(users[1], 100e18);
        vm.prank(users[0]);
        core.enableAutocompound();
        vm.prank(users[1]);
        core.enableAutocompound();
        _depositRewards(100e6);

        uint256 received =
            core.autocompoundBatch(users, 100e6, block.timestamp + 1, _oneInchData(address(metro), 100e6));

        assertEq(received, 100e6);
        assertEq(core.balanceOf(users[0]), 100e18 + 50e6);
        assertEq(core.balanceOf(users[1]), 100e18 + 50e6);
        assertEq(core.claimable(users[0]), 0);
        assertEq(core.claimable(users[1]), 0);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function test_OneInchFailureRollsBackPendingDebtPreferenceAndBalances() public {
        address user = makeAddr("one-inch-atomic-user");
        _stake(user, 100e18);
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(100e6);

        uint256 pendingBefore = core.claimable(user);
        int256 debtBefore = core.rewardDebt(user);
        xMETRO.AutoStrategyPreference memory preferenceBefore = core.getAutoStrategyPreference(user);
        uint256 coreUsdcBefore = usdc.balanceOf(address(core));
        oneInch.setMisreport(true);

        vm.prank(user);
        vm.expectRevert();
        core.claimAndExecute(swapStrategy, 100e6, block.timestamp + 1, _oneInchData(address(output), 100e6));

        assertEq(core.claimable(user), pendingBefore);
        assertEq(core.rewardDebt(user), debtBefore);
        xMETRO.AutoStrategyPreference memory preferenceAfter = core.getAutoStrategyPreference(user);
        assertEq(preferenceAfter.strategyId, preferenceBefore.strategyId);
        assertEq(preferenceAfter.strategyRevision, preferenceBefore.strategyRevision);
        assertEq(preferenceAfter.domainRevision, preferenceBefore.domainRevision);
        assertEq(usdc.balanceOf(address(core)), coreUsdcBefore);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(output.balanceOf(user), 0);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
    }

    function test_AutoModesRemainMutuallyExclusive() public {
        address user = makeAddr("preference-user");
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        xMETRO.AutoStrategyPreference memory genericPreference = core.getAutoStrategyPreference(user);
        assertEq(genericPreference.strategyId, swapStrategy);
        assertFalse(core.autocompoundEnabled(user));

        vm.prank(user);
        core.enableAutocompound();
        xMETRO.AutoStrategyPreference memory compoundPreference = core.getAutoStrategyPreference(user);
        assertTrue(core.autocompoundEnabled(user));
        assertTrue(compoundPreference.strategyId != swapStrategy);

        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        xMETRO.AutoStrategyPreference memory restoredGeneric = core.getAutoStrategyPreference(user);
        assertEq(restoredGeneric.strategyId, swapStrategy);
        assertFalse(core.autocompoundEnabled(user));
    }

    function test_BatchFiltersZeroDuplicateNoPendingAndKeepsSourceAlignment() public {
        address userA = makeAddr("filter-a");
        address userB = makeAddr("filter-b");
        address noPending = makeAddr("filter-no-pending");
        _stake(userA, 100e18);
        _stake(userB, 200e18);
        vm.prank(userA);
        core.enableAutoStrategy(swapStrategy);
        vm.prank(userB);
        core.enableAutoStrategy(swapStrategy);
        vm.prank(noPending);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(90e6);

        address[] memory candidates = new address[](6);
        candidates[0] = address(0);
        candidates[1] = userA;
        candidates[2] = userA;
        candidates[3] = noPending;
        candidates[4] = userB;
        candidates[5] = address(0);
        (uint256 rewardIn, uint256 amountOut) = core.executeAutoStrategyBatch(
            swapStrategy, candidates, 90e6, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );

        assertEq(rewardIn, 90e6);
        assertEq(amountOut, 90e6);
        assertEq(output.balanceOf(userA), 30e6);
        assertEq(output.balanceOf(userB), 60e6);
        assertEq(output.balanceOf(noPending), 0);
        assertEq(core.claimable(userA), 0);
        assertEq(core.claimable(userB), 0);
    }

    function test_ConfigRevisionMakesPreferenceStaleWithoutConsumingPending() public {
        address user = makeAddr("stale-domain-user");
        _stake(user, 100e18);
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(100e6);
        uint256 pendingBefore = core.claimable(user);

        CoreV2Router nextRouter = new CoreV2Router();
        ICoreAdapterConfiguration(address(adapter))
            .setRouters(address(nextRouter), address(new CoreCode()), address(new CoreCode()));
        assertFalse(core.paused());

        address[] memory users = new address[](1);
        users[0] = user;
        vm.expectRevert(xMETRO.NoRewards.selector);
        core.executeAutoStrategyBatch(
            swapStrategy, users, pendingBefore, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(core.claimable(user), pendingBefore);
        assertEq(output.balanceOf(user), 0);

        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        core.executeAutoStrategyBatch(
            swapStrategy, users, pendingBefore, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(output.balanceOf(user), pendingBefore);
    }

    function testFuzz_RepeatedStrategyAndRouterChangesPreservePendingUntilFreshOptIn(uint8 changeSeed) public {
        address user = makeAddr("config-sequence-user");
        _stake(user, 100 ether);
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(100e6);
        address[] memory users = new address[](1);
        users[0] = user;
        ICoreAdapterConfiguration admin = ICoreAdapterConfiguration(address(adapter));
        uint256 changes = bound(uint256(changeSeed), 1, 12);

        for (uint256 i; i < changes; ++i) {
            if (i % 2 == 0) {
                admin.setSwapTokenConfig(address(output), false, false);
                admin.setSwapTokenConfig(address(output), true, true);
            } else {
                admin.setRouters(address(new CoreV2Router()), address(new CoreCode()), address(new CoreCode()));
            }
            vm.expectRevert(xMETRO.NoRewards.selector);
            core.executeAutoStrategyBatch(
                swapStrategy, users, 1, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
            );
            assertEq(core.claimable(user), 100e6);
            vm.prank(user);
            core.enableAutoStrategy(swapStrategy);
        }

        (uint256 used, uint256 received) = core.executeAutoStrategyBatch(
            swapStrategy, users, 100e6, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(used, 100e6);
        assertEq(received, 100e6);
        assertEq(output.balanceOf(user), 100e6);
        assertEq(core.claimable(user), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
    }

    function test_UUPSUpgradeWithPendingRequiresFreshOptInAndRetainsConfiguration() public {
        address user = makeAddr("live-upgrade-user");
        _stake(user, 100 ether);
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(100e6);
        address proxy = address(adapter);
        bytes memory v2InitCode = vm.parseJsonBytes(
            vm.readFile("out-adapter/XMetroDeFiAdapterV2.sol/XMetroDeFiAdapterV2.json"), ".bytecode.object"
        );
        address v2 = _create(v2InitCode);
        ICoreUUPSUpgrade(proxy).upgradeToAndCall(v2, "");
        assertEq(core.deFiAdapter(), proxy);
        assertEq(core.deFiAdapterEpoch(), 1);
        assertEq(adapter.implementationVersion(), 2);
        assertEq(adapter.logicEpoch(), 2);
        assertTrue(adapter.strategyInfo(swapStrategy).enabled);

        address[] memory users = new address[](1);
        users[0] = user;
        vm.expectRevert(xMETRO.NoRewards.selector);
        core.executeAutoStrategyBatch(
            swapStrategy, users, 1, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(core.claimable(user), 100e6);
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        core.executeAutoStrategyBatch(
            swapStrategy, users, 100e6, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(output.balanceOf(user), 100e6);
        assertEq(core.claimable(user), 0);
    }

    function test_SingleStepOwnerHandoffMovesAdapterConfigurationAuthority() public {
        address nextOwner = makeAddr("next-owner");
        address outsider = makeAddr("not-owner");
        vm.prank(outsider);
        vm.expectRevert();
        core.transferOwnership(nextOwner);
        vm.expectRevert();
        core.transferOwnership(address(0));
        assertEq(core.owner(), address(this));
        core.transferOwnership(nextOwner);
        assertEq(core.owner(), nextOwner);

        vm.expectRevert();
        ICoreAdapterConfiguration(address(adapter)).setSwapTokenConfig(address(output), false, false);
        vm.expectRevert();
        core.setAutoCompoundOperator(outsider, true);
        vm.prank(nextOwner);
        ICoreAdapterConfiguration(address(adapter)).setSwapTokenConfig(address(output), false, false);
        assertFalse(adapter.strategyInfo(swapStrategy).enabled);
        vm.prank(nextOwner);
        core.setAutoCompoundOperator(outsider, true);
        assertTrue(core.autoCompoundOperators(outsider));
        vm.prank(nextOwner);
        core.renounceOwnership();
        assertEq(core.owner(), address(0));
        vm.prank(nextOwner);
        vm.expectRevert();
        ICoreAdapterConfiguration(address(adapter)).setSwapTokenConfig(address(output), true, true);
    }

    function test_AdapterFailureRollsBackRewardDebtAndBothFundTransfers() public {
        address user = makeAddr("atomic-user");
        _stake(user, 100e18);
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(100e6);
        uint256 pendingBefore = core.claimable(user);
        uint256 coreUsdcBefore = usdc.balanceOf(address(core));

        CoreMisreportingV2Router badRouter = new CoreMisreportingV2Router();
        ICoreAdapterConfiguration(address(adapter))
            .setRouters(address(badRouter), address(new CoreCode()), address(new CoreCode()));
        assertFalse(core.paused());
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);

        address[] memory users = new address[](1);
        users[0] = user;
        vm.expectRevert(bytes4(keccak256("AccountingFailure()")));
        core.executeAutoStrategyBatch(
            swapStrategy, users, pendingBefore, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(core.claimable(user), pendingBefore);
        assertEq(usdc.balanceOf(address(core)), coreUsdcBefore);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(badRouter)), 0);
        assertEq(output.balanceOf(user), 0);
        assertEq(usdc.allowance(address(adapter), address(badRouter)), 0);
    }

    function test_ProxyReplacementInvalidatesPreferenceAndOldProxyLosesConfigAuthority() public {
        address user = makeAddr("replacement-user");
        _stake(user, 100e18);
        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        _depositRewards(100e6);
        uint256 pendingBefore = core.claimable(user);
        address oldProxy = address(adapter);

        address implementation = _create(_adapterInitCode());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)", address(core), address(usdc), address(metro)
        );
        address nextProxy = address(new ERC1967Proxy(implementation, initData));
        core.setDeFiAdapter(nextProxy);
        ICoreAdapterConfiguration next = ICoreAdapterConfiguration(nextProxy);
        next.setRouters(address(router), address(new CoreCode()), address(new CoreCode()));
        next.setSwapMetroConfig(true, true);
        bytes32 nextStrategy = next.setSwapTokenConfig(address(output), true, true);
        assertEq(nextStrategy, swapStrategy);

        vm.expectRevert(bytes4(keccak256("AccessStateFailure()")));
        ICoreAdapterConfiguration(oldProxy).setSwapMetroConfig(false, false);
        assertFalse(core.paused());

        address[] memory users = new address[](1);
        users[0] = user;
        vm.expectRevert(xMETRO.NoRewards.selector);
        core.executeAutoStrategyBatch(
            swapStrategy, users, pendingBefore, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(core.claimable(user), pendingBefore);

        vm.prank(user);
        core.enableAutoStrategy(swapStrategy);
        core.executeAutoStrategyBatch(
            swapStrategy, users, pendingBefore, new uint256[](0), block.timestamp + 1, _v2Data(address(output))
        );
        assertEq(output.balanceOf(user), pendingBefore);
        assertEq(core.deFiAdapterEpoch(), 2);
    }

    function test_AaveV4MinimaStayAlignedAfterCoreFiltersCandidates() public {
        uint256 reserveId = 11;
        CoreAaveV4Spoke spoke = new CoreAaveV4Spoke(address(usdc), reserveId);
        MockAaveV4Giver giver = new MockAaveV4Giver(address(spoke));
        spoke.setActive(address(giver), true);
        ICoreAdapterConfiguration(address(adapter))
            .setAaveV4Config(address(spoke), address(giver), reserveId, true, true);
        bytes32 v4Strategy = keccak256(
            abi.encode(
                block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0)
            )
        );
        assertFalse(core.paused());

        address skipped = makeAddr("v4-skipped");
        address userA = makeAddr("v4-core-a");
        address userB = makeAddr("v4-core-b");
        _stake(userA, 100e18);
        _stake(userB, 200e18);
        vm.prank(userA);
        core.enableAutoStrategy(v4Strategy);
        vm.prank(userB);
        core.enableAutoStrategy(v4Strategy);
        spoke.setActive(address(giver), true);
        spoke.setAuthorized(userA, address(giver), true);
        spoke.setAuthorized(userB, address(giver), true);
        _depositRewards(90e6);

        address[] memory candidates = new address[](4);
        candidates[0] = skipped;
        candidates[1] = userA;
        candidates[2] = address(0);
        candidates[3] = userB;
        uint256[] memory minima = new uint256[](4);
        minima[0] = type(uint128).max;
        minima[1] = 30e6;
        minima[2] = type(uint128).max;
        minima[3] = 60e6;
        (uint256 rewardIn, uint256 sharesOut) =
            core.executeAutoStrategyBatch(v4Strategy, candidates, 90e6, minima, 0, bytes(""));
        assertEq(rewardIn, 90e6);
        assertEq(sharesOut, 90e6);
        assertEq(spoke.getUserSuppliedShares(reserveId, userA), 30e6);
        assertEq(spoke.getUserSuppliedShares(reserveId, userB), 60e6);
        assertEq(spoke.getUserSuppliedShares(reserveId, skipped), 0);
        assertEq(usdc.allowance(address(adapter), address(spoke)), 0);
        assertEq(usdc.allowance(address(adapter), address(giver)), 0);
    }

    function testFuzz_StrategySettlementPreservesFractionAcrossAllExecutionPaths(bool compound, bool automatic) public {
        address alice = makeAddr("fraction-alice");
        address bob = makeAddr("fraction-bob");
        _stake(alice, 2);
        _stake(bob, 2);
        _depositRewards(3);
        vm.startPrank(alice);
        if (compound) core.enableAutocompound();
        else core.enableAutoStrategy(swapStrategy);
        vm.stopPrank();
        address[] memory candidates = new address[](3);
        candidates[0] = alice;
        candidates[1] = alice;
        candidates[2] = address(0);
        bytes memory route = _v2Data(compound ? address(metro) : address(output));
        if (automatic) {
            if (compound) {
                assertEq(core.autocompoundBatch(candidates, 1, block.timestamp + 1, route), 1);
            } else {
                (uint256 consumed,) = core.executeAutoStrategyBatch(
                    swapStrategy, candidates, 1, new uint256[](0), block.timestamp + 1, route
                );
                assertEq(consumed, 1);
            }
        } else {
            vm.prank(alice);
            if (compound) {
                assertEq(core.autocompound(1, block.timestamp + 1, route), 1);
            } else {
                (uint256 consumed,) = core.claimAndExecute(swapStrategy, 1, block.timestamp + 1, route);
                assertEq(consumed, 1);
            }
        }
        assertEq(core.claimable(alice), 0);
        assertEq(usdc.balanceOf(address(core)), 2);
        // Compound adds one share: remove it so the next exact split exposes the retained half unit.
        if (compound) {
            vm.prank(alice);
            core.requestUnstake(1);
        }
        _depositRewards(1);
        assertEq(core.claimable(alice), 1);
        assertEq(core.claimable(bob), 2);
        vm.prank(alice);
        assertEq(core.claimRewards(), 1);
        vm.prank(bob);
        assertEq(core.claimRewards(), 2);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function _deployCore() private returns (xMETRO deployed) {
        bytes memory baseInitCode = vm.getCode("xMETRO.sol:xMETRO");
        bytes memory initCode = abi.encodePacked(
            baseInitCode, abi.encode(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000)
        );
        deployed = xMETRO(_create(initCode));
    }

    function _adapterInitCode() private view returns (bytes memory) {
        string memory artifact = vm.readFile("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json");
        return vm.parseJsonBytes(artifact, ".bytecode.object");
    }

    function _stake(address user, uint256 amount) private {
        metro.mint(user, amount);
        vm.startPrank(user);
        metro.approve(address(core), amount);
        core.stake(amount);
        vm.stopPrank();
    }

    function _depositRewards(uint256 amount) private {
        usdc.mint(address(rewardSource), amount);
        rewardSource.deposit(amount);
    }

    function _v2Data(address tokenOut) private view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = tokenOut;
        return abi.encode(uint8(0), abi.encode(path));
    }

    function _oneInchData(address tokenOut, uint256 amount) private view returns (bytes memory) {
        MockOneInchRouter.SwapDescription memory description = MockOneInchRouter.SwapDescription({
            srcToken: IERC20(address(usdc)),
            dstToken: IERC20(tokenOut),
            srcReceiver: payable(address(oneInchExecutor)),
            dstReceiver: payable(address(adapter)),
            amount: amount,
            minReturnAmount: amount,
            flags: 0
        });
        bytes memory callData = abi.encodeWithSelector(
            MockOneInchRouter.swap.selector, address(oneInchExecutor), description, bytes("verified-route")
        );
        return abi.encode(uint8(2), callData);
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        require(deployed != address(0));
    }
}
