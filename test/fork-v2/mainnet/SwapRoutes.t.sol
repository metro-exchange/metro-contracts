// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IXMetroDeFiAdapter} from "../../../src/interfaces/IXMetroDeFiAdapter.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase, IUniswapV2RouterMainnet} from "./MainnetForkBase.sol";

/// @notice E-17.11-.15: Real V2/V3 routing and output allowlist; five 1inch assets are tested separately.
contract SwapRoutesMainnetTest is MainnetForkBase {
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    bytes32 private wethStrategy;
    bytes32 private usdtStrategy;
    address[3] private users;

    function setUp() public {
        _fork();
        _deploySystem();
        _configureSwaps();
        wethStrategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        usdtStrategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(USDT, true, true);
        core.unpause();
        users[0] = makeAddr("swap-route-alice");
        users[1] = makeAddr("swap-route-bob");
        users[2] = makeAddr("swap-route-carol");
    }

    function _path(address[] memory path, uint256 cap) private pure returns (bytes memory) {
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), cap, abi.encode(path));
    }

    function _direct(address out) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = USDC;
        path[1] = out;
    }

    function _multi() private pure returns (address[] memory path) {
        path = new address[](3);
        path[0] = USDC;
        path[1] = WETH;
        path[2] = USDT;
    }

    function _three() private view returns (address[] memory list) {
        list = new address[](3);
        for (uint256 i; i < 3; ++i) {
            list[i] = users[i];
        }
    }

    /// E-17.11/.15: Tests V2 single manual without auto preference.
    function test_E17_V2SingleManualWithoutAutoPreference() public {
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        address[] memory path = _direct(WETH);
        uint256 quote = IUniswapV2RouterMainnet(V2_ROUTER).getAmountsOut(100e6, path)[1];
        assertEq(core.getAutoStrategyPreference(users[0]).strategyId, bytes32(0));
        uint256 beforeOut = IERC20(WETH).balanceOf(users[0]);
        vm.prank(users[0]);
        (uint256 rewardIn, uint256 out) =
            core.claimAndExecute(wethStrategy, quote * 99 / 100, block.timestamp + 1 hours, _path(path, 100e6));
        assertEq(rewardIn, 100e6);
        assertEq(out, quote);
        assertEq(IERC20(WETH).balanceOf(users[0]) - beforeOut, out);
        assertEq(core.getAutoStrategyPreference(users[0]).strategyId, bytes32(0));
        assertEq(core.claimable(users[0]), 0);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
    }

    /// E-17.11: Tests V2 multi hop batch pro rata.
    function test_E17_V2MultiHopBatchProRata() public {
        _mintAndStake(users[0], 2 ether);
        _mintAndStake(users[1], 3 ether);
        _mintAndStake(users[2], 5 ether);
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            core.enableAutoStrategy(usdtStrategy);
        }
        _distribute(100e6);
        address[] memory path = _multi();
        uint256 quote = IUniswapV2RouterMainnet(V2_ROUTER).getAmountsOut(100e6, path)[2];
        _fundUSDC(proxy, 5e6);
        (uint256 rewardIn, uint256 out) = core.executeAutoStrategyBatch(
            usdtStrategy, _three(), quote * 99 / 100, new uint256[](0), block.timestamp + 1 hours, _path(path, 100e6)
        );
        assertEq(rewardIn, 100e6);
        assertEq(out, quote);
        uint256 aliceOut = IERC20(USDT).balanceOf(users[0]);
        uint256 bobOut = IERC20(USDT).balanceOf(users[1]);
        uint256 carolOut = IERC20(USDT).balanceOf(users[2]);
        assertEq(aliceOut, out * 20 / 100);
        assertEq(bobOut, out * 30 / 100);
        assertEq(carolOut, out - aliceOut - bobOut);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
    }

    /// E-17.12: Tests V3 single and multi hop real pools.
    function test_E17_V3SingleAndMultiHopRealPools() public {
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        uint256 snapshot = vm.snapshotState();
        bytes memory single = abi.encodePacked(USDC, uint24(500), WETH);
        vm.prank(users[0]);
        (uint256 firstIn, uint256 firstOut) = core.claimAndExecute(
            wethStrategy,
            1,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(1), uint256(100e6), single)
        );
        assertEq(firstIn, 100e6);
        assertGt(firstOut, 0);
        assertEq(IERC20(USDC).allowance(proxy, V3_ROUTER), 0);
        assertTrue(vm.revertToState(snapshot));
        bytes memory multi = abi.encodePacked(USDC, uint24(100), DAI, uint24(3000), WETH);
        vm.prank(users[0]);
        (uint256 secondIn, uint256 secondOut) = core.claimAndExecute(
            wethStrategy,
            1,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(1), uint256(100e6), multi)
        );
        assertEq(secondIn, 100e6);
        assertGt(secondOut, 0);
        assertEq(IERC20(WETH).balanceOf(users[0]), secondOut);
        assertEq(IERC20(USDC).allowance(proxy, V3_ROUTER), 0);
    }

    /// E-17.13: Tests whitelist add disable and resume.
    function test_E17_WhitelistAddDisableAndResume() public {
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        bytes32 daiStrategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(DAI, true, true);
        assertTrue(adapter.strategyInfo(daiStrategy).enabled);
        IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, false, false);
        assertFalse(adapter.strategyInfo(wethStrategy).enabled);
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(wethStrategy, 1, block.timestamp + 1 hours, _path(_direct(WETH), 100e6));
        vm.prank(users[0]);
        vm.expectRevert();
        core.enableAutoStrategy(wethStrategy);
        vm.prank(users[0]);
        (uint256 rewardIn, uint256 daiOut) =
            core.claimAndExecute(daiStrategy, 1, block.timestamp + 1 hours, _path(_direct(DAI), 100e6));
        assertEq(rewardIn, 100e6);
        assertGt(daiOut, 0);
        assertEq(IERC20(DAI).balanceOf(users[0]), daiOut);
        IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WETH, true, true);
        assertTrue(adapter.strategyInfo(wethStrategy).enabled);
    }

    /// E-17.14/.15: Tests invalid route deadline minimum and METRO entry.
    function test_E17_InvalidRouteDeadlineMinimumAndMetroEntry() public {
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        bytes32 metroStrategy = keccak256(
            abi.encode(
                block.chainid,
                keccak256("XMETRO_DEFI_STRATEGY_V1"),
                IXMetroDeFiAdapter.StrategyKind.SwapMetro,
                address(metro)
            )
        );
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(metroStrategy, 1, block.timestamp + 1 hours, _path(_direct(address(metro)), 100e6));
        address[] memory wrongStart = new address[](2);
        wrongStart[0] = WETH;
        wrongStart[1] = USDT;
        _mustFail(usdtStrategy, 1, block.timestamp + 1 hours, _path(wrongStart, 100e6));
        _mustFail(usdtStrategy, 1, block.timestamp + 1 hours, _path(_direct(WETH), 100e6));
        _mustFail(usdtStrategy, 1, block.timestamp, _path(_direct(USDT), 100e6));
        _mustFail(usdtStrategy, type(uint256).max, block.timestamp + 1 hours, _path(_direct(USDT), 100e6));
        assertEq(core.claimable(users[0]), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(USDC).allowance(proxy, V2_ROUTER), 0);
    }

    function _mustFail(bytes32 id, uint256 minimum, uint256 deadline, bytes memory route) private {
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(id, minimum, deadline, route);
    }
}
