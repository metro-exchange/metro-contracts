// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";

interface IXMetroCoreFork {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function deFiAdapter() external view returns (address);
    function deFiAdapterEpoch() external view returns (uint64);
    function METRO() external view returns (address);
    function rewardToken() external view returns (address);
    function setDeFiAdapter(address adapter) external;
    function setRewardDistributor(address distributor) external;
    function setMigrationEscrow(address escrow) external;
    function setAutoCompoundOperator(address operator, bool allowed) external;
    function setYThorRewardWeightBps(uint256 newWeightBps) external;
    function yThorRewardWeightBps() external view returns (uint256);
    function unpause() external;
    function pause() external;
    function stake(uint256 amount) external;
    function creditYThorFromMigration(address user, uint256 principal) external;
    function balanceOf(address account) external view returns (uint256);
    function rewardWeightOf(address account) external view returns (uint256);
    function claimable(address account) external view returns (uint256);
    function depositRewards(uint256 amount) external;
    function claimAndExecute(bytes32 strategy, uint256 minOut, uint256 deadline, bytes calldata executionData)
        external
        returns (uint256 rewardIn, uint256 amountOut);
    function enableAutoStrategy(bytes32 strategy) external;
    function enableAutocompound() external;
    function disableAutocompound() external;
    function autocompound(uint256 minOut, uint256 deadline, bytes calldata executionData)
        external
        returns (uint256 amountOut);
    function autocompoundBatch(address[] calldata users, uint256 minOut, uint256 deadline, bytes calldata executionData)
        external
        returns (uint256 amountOut);
    function executeAutoStrategyBatch(
        bytes32 strategy,
        address[] calldata users,
        uint256 minTotalOut,
        uint256[] calldata minUserOut,
        uint256 deadline,
        bytes calldata executionData
    ) external returns (uint256 rewardIn, uint256 amountOut);
}

interface IXMetroAdapterAdminFork {
    function setRouters(address routerV2, address routerV3, address oneInchRouter) external;
    function setSwapMetroConfig(bool enabled, bool autoEnabled) external;
    function setSwapTokenConfig(address tokenOut, bool enabled, bool autoEnabled) external returns (bytes32);
    function setAaveV3Config(address pool, address aToken, uint16 referralCode, bool enabled, bool autoEnabled)
        external
        returns (bytes32);
    function setAaveV4Config(address spoke, address giver, uint256 reserveId, bool enabled, bool autoEnabled) external;
    function setMapleConfig(address router, bytes32 depositData, bool enabled, bool autoEnabled)
        external
        returns (bytes32);
}

interface IWETHFork is IERC20 {
    function deposit() external payable;
}

contract ForkRewardSource {
    IXMetroCoreFork public immutable core;
    IERC20 public immutable token;

    constructor(IXMetroCoreFork core_, IERC20 token_) {
        core = core_;
        token = token_;
    }

    function xMETRO() external view returns (address) {
        return address(core);
    }

    function rewardToken() external view returns (address) {
        return address(token);
    }

    function depositRewards(uint256 amount) external {
        token.approve(address(core), amount);
        core.depositRewards(amount);
    }
}

abstract contract XMetroForkBase is Test {
    uint256 internal constant ETHEREUM_PINNED_BLOCK = 25_838_112;
    uint256 internal constant BASE_PINNED_BLOCK = 50_555_256;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC_WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60;
    address internal constant UNISWAP_V2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNISWAP_V3 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant UNISWAP_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address internal constant ONEINCH = 0x111111125421cA6dc452d289314280a0f8842A65;
    bytes32 internal constant STRATEGY_DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");

    IXMetroCoreFork internal core;
    IXMetroDeFiAdapter internal adapter;
    ForkRewardSource internal rewardSource;

    function _selectEthereumFork(uint256 blockNumber) internal {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing ETH_RPC_URL");
        vm.createSelectFork(rpc, blockNumber);
        assertEq(block.chainid, 1);
    }

    function _selectEthereumLatestFork() internal returns (uint256 blockNumber) {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing ETH_RPC_URL");
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1);
        return block.number;
    }

    function _selectBaseFork(uint256 blockNumber) internal {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing BASE_RPC_URL");
        vm.createSelectFork(rpc, blockNumber);
        assertEq(block.chainid, 8453);
    }

    function _selectBaseLatestFork() internal returns (uint256 blockNumber) {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "missing BASE_RPC_URL");
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 8453);
        return block.number;
    }

    function _deployExactCoreAndAdapter(address metroToken) internal returns (address proxy) {
        return _deployExactCoreAndAdapterFor(metroToken, USDC);
    }

    function _deployExactCoreAndAdapterFor(address metroToken, address rewardToken) internal returns (address proxy) {
        bytes memory coreInit = abi.encodePacked(
            _artifactCreationCode("out-core/xMETRO.sol/xMETRO.json"),
            abi.encode(address(this), metroToken, rewardToken, makeAddr("fork-forfeiture"), 20_000)
        );
        core = IXMetroCoreFork(_create(coreInit));
        assertFalse(core.paused(), "Core must deploy unpaused");
        // Pause explicitly to test configuration/unpause boundaries; the constructor is not paused.
        core.pause();
        address implementation =
            _create(_artifactCreationCode("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"));
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address,address)", address(core), rewardToken, metroToken);
        proxy = address(new ERC1967Proxy(implementation, initData));
        adapter = IXMetroDeFiAdapter(proxy);
        core.setDeFiAdapter(proxy);
        assertEq(address(core).code.length, 22_921);
        assertEq(implementation.code.length, 20_487);
        assertEq(core.deFiAdapter(), proxy);
    }

    function _bindRewardSource() internal {
        _bindRewardSourceFor(USDC);
    }

    function _bindRewardSourceFor(address rewardToken) internal {
        rewardSource = new ForkRewardSource(core, IERC20(rewardToken));
        core.setRewardDistributor(address(rewardSource));
    }

    function _stakeWeth(address account, uint256 amount) internal {
        vm.deal(account, amount);
        vm.startPrank(account);
        IWETHFork(WETH).deposit{value: amount}();
        IERC20(WETH).approve(address(core), amount);
        core.stake(amount);
        vm.stopPrank();
    }

    function _enableAuto(address account, bytes32 strategy) internal {
        vm.prank(account);
        core.enableAutoStrategy(strategy);
    }

    function _enableCompound(address account) internal {
        vm.prank(account);
        core.enableAutocompound();
    }

    function _depositRewards(uint256 amount) internal {
        deal(USDC, address(rewardSource), amount);
        rewardSource.depositRewards(amount);
    }

    function _fundFromWhale(address recipient, uint256 amount) internal {
        vm.prank(USDC_WHALE);
        assertTrue(IERC20(USDC).transfer(recipient, amount));
    }

    function _strategyId(IXMetroDeFiAdapter.StrategyKind kind, address outputToken) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, STRATEGY_DOMAIN, kind, outputToken));
    }

    function _v2SwapData(address tokenOut) internal pure returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = tokenOut;
        return abi.encode(uint8(0), abi.encode(path));
    }

    function _v3SwapData(bytes memory path) internal pure returns (bytes memory) {
        return abi.encode(uint8(1), path);
    }

    function _artifactCreationCode(string memory path) internal view returns (bytes memory) {
        string memory artifact = vm.readFile(path);
        return vm.parseJsonBytes(artifact, ".bytecode.object");
    }

    function _create(bytes memory initCode) internal returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        require(deployed != address(0), "CREATE failed");
    }
}
