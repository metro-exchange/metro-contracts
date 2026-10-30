// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {xMETRO} from "../../src/xMETRO.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {CoreFlowToken, CoreV2Router, CoreCode, ICoreAdapterConfiguration} from "./XMetroCore.adapter.t.sol";

contract XMetroCoreAdapterInvariantHandler is Test {
    xMETRO public immutable core;
    CoreFlowToken public immutable usdc;
    CoreFlowToken public immutable output;
    bytes32 public immutable swapStrategy;
    address[3] internal actors;
    uint256 public totalDeposited;
    uint256 public totalConsumed;
    uint256 public swapAttempts;
    uint256 public swapSuccesses;
    uint256 public compoundAttempts;
    uint256 public compoundSuccesses;
    uint256 public claimAttempts;
    uint256 public claimSuccesses;
    uint256 public unexpectedFailures;

    constructor(xMETRO core_, CoreFlowToken usdc_, CoreFlowToken output_, bytes32 swapStrategy_) {
        core = core_;
        usdc = usdc_;
        output = output_;
        swapStrategy = swapStrategy_;
        actors[0] = makeAddr("core-invariant-a");
        actors[1] = makeAddr("core-invariant-b");
        actors[2] = makeAddr("core-invariant-c");
        usdc.approve(address(core_), type(uint256).max);
    }

    function xMETRO() external view returns (address) {
        return address(core);
    }

    function rewardToken() external view returns (address) {
        return address(usdc);
    }

    function actor(uint256 index) external view returns (address) {
        return actors[index];
    }

    function depositRewards(uint96 seed) external {
        uint256 amount = bound(uint256(seed), 1, 100_000e6);
        usdc.mint(address(this), amount);
        core.depositRewards(amount);
        totalDeposited += amount;
    }

    function switchMode(uint256 actorSeed, uint8 modeSeed) external {
        address account = actors[actorSeed % actors.length];
        vm.startPrank(account);
        uint8 mode = modeSeed % 4;
        if (mode == 0) core.enableAutoStrategy(swapStrategy);
        else if (mode == 1) core.enableAutocompound();
        else if (mode == 2) core.disableAutoStrategy();
        else core.disableAutocompound();
        vm.stopPrank();
    }

    function executeAutoSwap() external {
        uint256 quotedInput;
        for (uint256 i; i < actors.length; ++i) {
            if (core.claimable(actors[i]) != 0 && core.getAutoStrategyPreference(actors[i]).strategyId == swapStrategy)
            {
                quotedInput += core.claimable(actors[i]);
            }
        }
        if (quotedInput == 0) return;
        ++swapAttempts;
        address[] memory accounts = _actors();
        try core.executeAutoStrategyBatch(
            swapStrategy, accounts, 1, new uint256[](0), block.timestamp + 1, _v2Data(address(output), quotedInput)
        ) returns (
            uint256 rewardIn, uint256
        ) {
            totalConsumed += rewardIn;
            ++swapSuccesses;
        } catch (bytes memory reason) {
            emit log_named_bytes("unexpected auto swap failure", reason);
            ++unexpectedFailures;
        }
    }

    function executeAutoCompound() external {
        uint256 quotedInput;
        for (uint256 i; i < actors.length; ++i) {
            if (core.claimable(actors[i]) != 0 && core.autocompoundEnabled(actors[i])) {
                quotedInput += core.claimable(actors[i]);
            }
        }
        if (quotedInput == 0) return;
        ++compoundAttempts;
        address[] memory accounts = _actors();
        uint256 beforeBalance = usdc.balanceOf(address(core));
        try core.autocompoundBatch(
            accounts, 1, block.timestamp + 1, _v2Data(address(core.METRO()), quotedInput)
        ) returns (
            uint256
        ) {
            totalConsumed += beforeBalance - usdc.balanceOf(address(core));
            ++compoundSuccesses;
        } catch (bytes memory reason) {
            emit log_named_bytes("unexpected auto compound failure", reason);
            ++unexpectedFailures;
        }
    }

    function rewardsAfterQuote(uint256 actorSeed) external {
        address user = actors[actorSeed % actors.length];
        uint256 cap = core.claimable(user);
        if (cap == 0) return;
        bytes memory quote = _v2Data(address(output), cap);
        usdc.mint(address(this), 600e6);
        core.depositRewards(600e6);
        totalDeposited += 600e6;
        uint256 pending = core.claimable(user);
        assertGt(pending, cap);
        uint256 balance = usdc.balanceOf(address(core));
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("InvalidExecutionRequest()")));
        core.claimAndExecute(swapStrategy, 1, block.timestamp + 1, quote);
        assertEq(core.claimable(user), pending);
        assertEq(usdc.balanceOf(address(core)), balance);
    }

    function claim(uint256 actorSeed) external {
        address account = actors[actorSeed % actors.length];
        if (core.claimable(account) == 0) return;
        ++claimAttempts;
        vm.prank(account);
        try core.claimRewards() returns (uint256 paid) {
            totalConsumed += paid;
            ++claimSuccesses;
        } catch (bytes memory reason) {
            emit log_named_bytes("unexpected claim failure", reason);
            ++unexpectedFailures;
        }
    }

    function _actors() private view returns (address[] memory accounts) {
        accounts = new address[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            accounts[i] = actors[i];
        }
    }

    function _v2Data(address tokenOut, uint256 cap) private view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = tokenOut;
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), cap, abi.encode(path));
    }
}

contract XMetroCoreAdapterInvariantTest is StdInvariant, Test {
    bytes32 internal constant STRATEGY_DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");

    CoreFlowToken internal metro;
    CoreFlowToken internal usdc;
    CoreFlowToken internal output;
    CoreV2Router internal router;
    xMETRO internal core;
    IXMetroDeFiAdapter internal adapter;
    XMetroCoreAdapterInvariantHandler internal handler;
    bytes32 internal swapStrategy;
    bytes32 internal swapMetroStrategy;

    function setUp() public {
        metro = new CoreFlowToken("Metro", "METRO", 18);
        usdc = new CoreFlowToken("USD Coin", "USDC", 6);
        output = new CoreFlowToken("Output", "OUT", 6);
        router = new CoreV2Router();
        core = _deployCore();
        address implementation = _create(_adapterInitCode());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)", address(core), address(usdc), address(metro)
        );
        address proxy = address(new ERC1967Proxy(implementation, initData));
        adapter = IXMetroDeFiAdapter(proxy);
        core.setDeFiAdapter(proxy);
        ICoreAdapterConfiguration admin = ICoreAdapterConfiguration(proxy);
        admin.setRouters(address(router), address(new CoreCode()), address(new CoreCode()));
        admin.setSwapMetroConfig(true, true);
        swapStrategy = admin.setSwapTokenConfig(address(output), true, true);
        swapMetroStrategy = keccak256(
            abi.encode(block.chainid, STRATEGY_DOMAIN, IXMetroDeFiAdapter.StrategyKind.SwapMetro, address(metro))
        );

        handler = new XMetroCoreAdapterInvariantHandler(core, usdc, output, swapStrategy);
        core.setRewardDistributor(address(handler));
        core.setAutoCompoundOperator(address(handler), true);
        for (uint256 i; i < 3; ++i) {
            address account = handler.actor(i);
            uint256 amount = (i + 1) * 10 ether;
            metro.mint(account, amount);
            vm.startPrank(account);
            metro.approve(address(core), amount);
            core.stake(amount);
            vm.stopPrank();
        }
        // Seed one successful execution of each route, so a campaign cannot pass vacuously.
        handler.depositRewards(600e6);
        vm.prank(handler.actor(0));
        core.enableAutoStrategy(swapStrategy);
        vm.prank(handler.actor(1));
        core.enableAutocompound();
        handler.executeAutoSwap();
        handler.executeAutoCompound();
        handler.claim(2);
        targetContract(address(handler));
    }

    function invariant_RewardTokenConservationAcrossClaimsAndBothAutomaticPaths() public view {
        assertEq(handler.totalDeposited(), usdc.balanceOf(address(core)) + handler.totalConsumed());
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
        uint256 payableRewards;
        for (uint256 i; i < 3; ++i) {
            payableRewards += core.claimable(handler.actor(i));
        }
        assertLe(payableRewards, usdc.balanceOf(address(core)));
        assertEq(handler.unexpectedFailures(), 0);
        assertEq(handler.swapAttempts(), handler.swapSuccesses());
        assertEq(handler.compoundAttempts(), handler.compoundSuccesses());
        assertEq(handler.claimAttempts(), handler.claimSuccesses());
        assertGt(handler.swapSuccesses(), 0);
        assertGt(handler.compoundSuccesses(), 0);
        assertGt(handler.claimSuccesses(), 0);
    }

    function invariant_AtMostOneAutomaticPreferenceIsActivePerUser() public view {
        for (uint256 i; i < 3; ++i) {
            address account = handler.actor(i);
            xMETRO.AutoStrategyPreference memory preference = core.getAutoStrategyPreference(account);
            if (core.autocompoundEnabled(account)) {
                assertEq(preference.strategyId, swapMetroStrategy);
            } else if (preference.strategyId != bytes32(0)) {
                assertEq(preference.strategyId, swapStrategy);
            }
        }
    }

    function invariant_AdapterExecutionNeverDisturbsMetroBacking() public view {
        assertEq(metro.balanceOf(address(core)), core.totalShares());
        assertEq(adapter.xMETRO(), address(core));
        assertEq(adapter.USDC(), address(usdc));
        assertEq(adapter.METRO(), address(metro));
    }

    function _deployCore() private returns (xMETRO deployed) {
        bytes memory initCode = abi.encodePacked(
            vm.getCode("xMETRO.sol:xMETRO"),
            abi.encode(address(this), address(metro), address(usdc), makeAddr("invariant-forfeiture"), 20_000)
        );
        deployed = xMETRO(_create(initCode));
    }

    function _adapterInitCode() private view returns (bytes memory) {
        string memory artifact = vm.readFile("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json");
        return vm.parseJsonBytes(artifact, ".bytecode.object");
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        require(deployed != address(0));
    }
}
