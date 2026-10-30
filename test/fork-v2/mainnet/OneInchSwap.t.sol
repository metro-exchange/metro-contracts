// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Vm} from "forge-std/Vm.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

interface IOneInchRouterMainnet {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }
    function swap(address executor, SwapDescription calldata desc, bytes calldata data)
        external
        payable
        returns (uint256, uint256);
}

/// @notice Diagnosis of official 1inch.com frontend calldata for the exact CREATE-deployed Proxy.
contract OneInchSwapMainnetTest is MainnetForkBase {
    string private constant FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/oneinch-frontend-eoa-wallet-proxy-receiver.json";
    string private constant FORCED_FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/oneinch-excluding-pmm-v2-v3.json";
    bytes32 private constant MANUAL = keccak256("ClaimAndExecuted(address,bytes32,uint256,uint256)");
    bytes32 private constant SETTLED = keccak256("UserStrategySettled(bytes32,address,uint256,uint256)");
    bytes32 private constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    function setUp() public {
        _fork();
        _deploySystem();
        assertEq(vm.parseJsonAddress(vm.readFile(FIXTURE), ".proxy"), proxy);
        IXMetroAdapterAdminFork(proxy).setRouters(V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        core.unpause();
    }

    function _data(uint256 index) private view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(FIXTURE), string.concat(".routes[", vm.toString(index), "].calldata"));
    }

    function _assertFrontendCallerBindingReverts(uint256 index, address tokenOut) private {
        bytes memory data = _data(index);
        assertEq(bytes4(data), IOneInchRouterMainnet.swap.selector);
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = data[i + 4];
        }
        (, IOneInchRouterMainnet.SwapDescription memory desc,) =
            abi.decode(args, (address, IOneInchRouterMainnet.SwapDescription, bytes));
        assertEq(address(desc.srcToken), USDC);
        assertEq(address(desc.dstToken), tokenOut);
        assertEq(desc.dstReceiver, proxy);
        assertEq(desc.amount, 100e6);
        address user = makeAddr("one-inch-real-proxy-user");
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(tokenOut, true, true);
        _mintAndStake(user, 1 ether);
        _distribute(100e6);
        uint256 beforeOut = IERC20(tokenOut).balanceOf(user);
        uint256 beforeCore = IERC20(USDC).balanceOf(address(core));
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("InvalidExecutionRequest()")));
        core.claimAndExecute(
            strategy,
            1,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        assertEq(core.claimable(user), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), beforeCore);
        assertEq(IERC20(tokenOut).balanceOf(user), beforeOut);
        assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
    }

    function _assertUnsupportedSelector(uint256 index, address tokenOut) private {
        bytes memory data = _data(index);
        assertTrue(bytes4(data) != IOneInchRouterMainnet.swap.selector);
        address user = makeAddr("one-inch-unsupported-selector-user");
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(tokenOut, true, true);
        _mintAndStake(user, 1 ether);
        _distribute(100e6);
        uint256 beforeCore = IERC20(USDC).balanceOf(address(core));
        vm.prank(user);
        vm.expectRevert();
        core.claimAndExecute(
            strategy,
            1,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        assertEq(core.claimable(user), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), beforeCore);
    }

    function test_OneInchFrontendUsdtEoaQuoteProxyReceiverCannotExecute() public {
        _assertFrontendCallerBindingReverts(0, USDT);
    }

    function test_OneInchFrontendWbtcEoaQuoteProxyReceiverCannotExecute() public {
        _assertFrontendCallerBindingReverts(1, WBTC);
    }

    function test_OneInchFrontendGhoUnsupportedSelector() public {
        _assertUnsupportedSelector(2, GHO);
    }

    function test_OneInchFrontendXautUnsupportedSelector() public {
        _assertUnsupportedSelector(3, XAUT);
    }

    function test_E17_SyrupOneInchManualRealProxy() public {
        // This route uses Maple Syrup liquidity and does not bind the EOA quote wallet.
        bytes memory data = _data(4);
        IOneInchRouterMainnet.SwapDescription memory desc = _decode(data);
        assertEq(IERC20Metadata(SYRUP_USDC).decimals(), 6);
        assertEq(address(desc.srcToken), USDC);
        assertEq(address(desc.dstToken), SYRUP_USDC);
        assertEq(desc.dstReceiver, proxy);
        assertEq(desc.amount, 100e6);
        address user = makeAddr("one-inch-syrup-manual-user");
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(SYRUP_USDC, true, true);
        _mintAndStake(user, 1 ether);
        _distribute(100e6);
        _fundUSDC(proxy, 5e6);
        uint256 beforeOut = IERC20(SYRUP_USDC).balanceOf(user);
        vm.recordLogs();
        vm.prank(user);
        (uint256 rewardIn, uint256 amountOut) = core.claimAndExecute(
            strategy,
            desc.minReturnAmount,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(rewardIn, 100e6);
        assertGe(amountOut, desc.minReturnAmount);
        assertEq(IERC20(SYRUP_USDC).balanceOf(user) - beforeOut, amountOut);
        assertEq(core.claimable(user), 0);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
        bool foundManual;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics.length != 3 || logs[i].topics[0] != MANUAL) {
                continue;
            }
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(logs[i].topics[2], strategy);
            (uint256 eventIn, uint256 eventOut) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(eventIn, rewardIn);
            assertEq(eventOut, amountOut);
            foundManual = true;
        }
        assertTrue(foundManual);
        emit log_named_uint("1inch syrup manual output", amountOut);
    }

    function test_E17_SyrupOneInchBatchProRata() public {
        bytes memory data = _data(4);
        IOneInchRouterMainnet.SwapDescription memory desc = _decode(data);
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(SYRUP_USDC, true, true);
        address[] memory users = new address[](3);
        users[0] = makeAddr("one-inch-syrup-batch-alice");
        users[1] = makeAddr("one-inch-syrup-batch-bob");
        users[2] = makeAddr("one-inch-syrup-batch-carol");
        _mintAndStake(users[0], 2 ether);
        _mintAndStake(users[1], 3 ether);
        _mintAndStake(users[2], 5 ether);
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            core.enableAutoStrategy(strategy);
        }
        _distribute(100e6);
        assertEq(core.claimable(users[0]), 20e6);
        assertEq(core.claimable(users[1]), 30e6);
        assertEq(core.claimable(users[2]), 50e6);
        _fundUSDC(proxy, 5e6);
        vm.recordLogs();
        (uint256 rewardIn, uint256 amountOut) = core.executeAutoStrategyBatch(
            strategy,
            users,
            desc.minReturnAmount,
            new uint256[](0),
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(rewardIn, 100e6);
        assertGe(amountOut, desc.minReturnAmount);
        uint256 a = IERC20(SYRUP_USDC).balanceOf(users[0]);
        uint256 b = IERC20(SYRUP_USDC).balanceOf(users[1]);
        uint256 c = IERC20(SYRUP_USDC).balanceOf(users[2]);
        assertEq(a, amountOut * 20 / 100);
        assertEq(b, amountOut * 30 / 100);
        assertEq(c, amountOut - a - b);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
        uint256 settlements;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != proxy || logs[i].topics.length != 3 || logs[i].topics[0] != SETTLED) continue;
            assertEq(logs[i].topics[1], strategy);
            address recipient = address(uint160(uint256(logs[i].topics[2])));
            uint256 index = recipient == users[0] ? 0 : recipient == users[1] ? 1 : 2;
            assertEq(recipient, users[index]);
            (uint256 eventIn, uint256 eventOut) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(eventIn, index == 0 ? 20e6 : index == 1 ? 30e6 : 50e6);
            assertEq(eventOut, IERC20(SYRUP_USDC).balanceOf(recipient));
            ++settlements;
        }
        assertEq(settlements, 3);
        emit log_named_uint("1inch syrup batch output", amountOut);
    }

    function _decode(bytes memory data) private pure returns (IOneInchRouterMainnet.SwapDescription memory desc) {
        assertEq(bytes4(data), IOneInchRouterMainnet.swap.selector);
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = data[i + 4];
        }
        (, desc,) = abi.decode(args, (address, IOneInchRouterMainnet.SwapDescription, bytes));
    }

    function _forcedData(uint256 index) private view returns (bytes memory) {
        string memory json = vm.readFile(FORCED_FIXTURE);
        assertEq(vm.parseJsonAddress(json, ".proxy"), proxy);
        return vm.parseJsonBytes(json, string.concat(".routes[", vm.toString(index), "].calldata"));
    }

    /// E-17.01/.03/.05/.07: Tests the related fork checklist scenario.
    function _forcedManual(uint256 index, address tokenOut, uint8 decimals) private {
        bytes memory data = _forcedData(index);
        IOneInchRouterMainnet.SwapDescription memory desc = _decode(data);
        assertEq(address(desc.srcToken), USDC);
        assertEq(address(desc.dstToken), tokenOut);
        assertEq(desc.dstReceiver, proxy);
        assertEq(desc.amount, 100e6);
        assertEq(IERC20Metadata(tokenOut).decimals(), decimals);
        address user = makeAddr("oneinch-forced-manual-user");
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(tokenOut, true, true);
        _mintAndStake(user, 1 ether);
        _distribute(100e6);
        _fundUSDC(proxy, 5e6);
        uint256 beforeOut = IERC20(tokenOut).balanceOf(user);
        vm.recordLogs();
        vm.prank(user);
        (uint256 rewardIn, uint256 amountOut) = core.claimAndExecute(
            strategy,
            desc.minReturnAmount,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(rewardIn, 100e6);
        assertGe(amountOut, desc.minReturnAmount);
        assertEq(IERC20(tokenOut).balanceOf(user) - beforeOut, amountOut);
        assertEq(core.claimable(user), 0);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
        bool projectEvent;
        bool inputTransfer;
        bool outputTransfer;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER) {
                if (
                    logs[i].emitter == USDC && logs[i].topics[1] == bytes32(uint256(uint160(proxy)))
                        && logs[i].topics[2] == bytes32(uint256(uint160(address(desc.srcReceiver))))
                ) {
                    assertEq(abi.decode(logs[i].data, (uint256)), 100e6);
                    inputTransfer = true;
                }
                if (
                    logs[i].emitter == tokenOut && logs[i].topics[1] == bytes32(uint256(uint160(proxy)))
                        && logs[i].topics[2] == bytes32(uint256(uint160(user)))
                ) {
                    assertEq(abi.decode(logs[i].data, (uint256)), amountOut);
                    outputTransfer = true;
                }
            }
            if (logs[i].emitter != address(core) || logs[i].topics.length != 3 || logs[i].topics[0] != MANUAL) {
                continue;
            }
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(logs[i].topics[2], strategy);
            (uint256 loggedIn, uint256 loggedOut) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(loggedIn, rewardIn);
            assertEq(loggedOut, amountOut);
            projectEvent = true;
        }
        assertTrue(projectEvent);
        assertTrue(inputTransfer && outputTransfer);
        emit log_named_uint("1inch forced manual output", amountOut);
    }

    /// E-17.02/.04/.06/.08: Tests the related fork checklist scenario.
    function _forcedBatch(uint256 index, address tokenOut, uint8 decimals) private {
        bytes memory data = _forcedData(index);
        IOneInchRouterMainnet.SwapDescription memory desc = _decode(data);
        assertEq(address(desc.srcToken), USDC);
        assertEq(address(desc.dstToken), tokenOut);
        assertEq(desc.dstReceiver, proxy);
        assertEq(desc.amount, 100e6);
        assertEq(IERC20Metadata(tokenOut).decimals(), decimals);
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(tokenOut, true, true);
        address[] memory users = new address[](3);
        users[0] = makeAddr("oneinch-forced-batch-alice");
        users[1] = makeAddr("oneinch-forced-batch-bob");
        users[2] = makeAddr("oneinch-forced-batch-carol");
        _mintAndStake(users[0], 2 ether);
        _mintAndStake(users[1], 3 ether);
        _mintAndStake(users[2], 5 ether);
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            core.enableAutoStrategy(strategy);
        }
        _distribute(100e6);
        assertEq(core.claimable(users[0]), 20e6);
        assertEq(core.claimable(users[1]), 30e6);
        assertEq(core.claimable(users[2]), 50e6);
        _fundUSDC(proxy, 5e6);
        address[] memory candidates = new address[](6);
        candidates[0] = address(0);
        candidates[1] = users[0];
        candidates[2] = users[0];
        candidates[3] = makeAddr("oneinch-forced-unopted");
        candidates[4] = users[1];
        candidates[5] = users[2];
        uint256[] memory wrongMinima = new uint256[](1);
        wrongMinima[0] = 1;
        vm.expectRevert();
        core.executeAutoStrategyBatch(
            strategy,
            candidates,
            desc.minReturnAmount,
            wrongMinima,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        assertEq(core.claimable(users[0]), 20e6);
        assertEq(core.claimable(users[1]), 30e6);
        assertEq(core.claimable(users[2]), 50e6);
        vm.recordLogs();
        (uint256 rewardIn, uint256 amountOut) = core.executeAutoStrategyBatch(
            strategy,
            candidates,
            desc.minReturnAmount,
            new uint256[](0),
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(rewardIn, 100e6);
        assertGe(amountOut, desc.minReturnAmount);
        uint256 a = IERC20(tokenOut).balanceOf(users[0]);
        uint256 b = IERC20(tokenOut).balanceOf(users[1]);
        uint256 c = IERC20(tokenOut).balanceOf(users[2]);
        assertEq(a, amountOut * 20 / 100);
        assertEq(b, amountOut * 30 / 100);
        assertEq(c, amountOut - a - b);
        assertEq(core.claimable(users[0]), 0);
        assertEq(core.claimable(users[1]), 0);
        assertEq(core.claimable(users[2]), 0);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
        uint256 settlements;
        uint256 outputTransfers;
        bool inputTransfer;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER) {
                if (
                    logs[i].emitter == USDC && logs[i].topics[1] == bytes32(uint256(uint160(proxy)))
                        && logs[i].topics[2] == bytes32(uint256(uint160(address(desc.srcReceiver))))
                ) {
                    assertEq(abi.decode(logs[i].data, (uint256)), 100e6);
                    inputTransfer = true;
                }
                if (logs[i].emitter == tokenOut && logs[i].topics[1] == bytes32(uint256(uint160(proxy)))) {
                    address outputRecipient = address(uint160(uint256(logs[i].topics[2])));
                    assertTrue(
                        outputRecipient == users[0] || outputRecipient == users[1] || outputRecipient == users[2]
                    );
                    assertEq(abi.decode(logs[i].data, (uint256)), IERC20(tokenOut).balanceOf(outputRecipient));
                    ++outputTransfers;
                }
            }
            if (logs[i].emitter != proxy || logs[i].topics.length != 3 || logs[i].topics[0] != SETTLED) continue;
            assertEq(logs[i].topics[1], strategy);
            address recipient = address(uint160(uint256(logs[i].topics[2])));
            uint256 userIndex = recipient == users[0] ? 0 : recipient == users[1] ? 1 : 2;
            assertEq(recipient, users[userIndex]);
            (uint256 loggedIn, uint256 loggedOut) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(loggedIn, userIndex == 0 ? 20e6 : userIndex == 1 ? 30e6 : 50e6);
            assertEq(loggedOut, IERC20(tokenOut).balanceOf(recipient));
            ++settlements;
        }
        assertEq(settlements, 3);
        assertTrue(inputTransfer);
        assertEq(outputTransfers, 3);
        emit log_named_uint("1inch forced batch output", amountOut);
    }

    function test_E17_ForcedUsdtManual() public {
        _forcedManual(0, USDT, 6);
    }

    function test_E17_ForcedUsdtBatch() public {
        _forcedBatch(0, USDT, 6);
    }

    function test_E17_ForcedWbtcManual() public {
        _forcedManual(1, WBTC, 8);
    }

    function test_E17_ForcedWbtcBatch() public {
        _forcedBatch(1, WBTC, 8);
    }

    function test_E17_ForcedGhoManual() public {
        _forcedManual(2, GHO, 18);
    }

    function test_E17_ForcedGhoBatch() public {
        _forcedBatch(2, GHO, 18);
    }

    function test_E17_ForcedXautManual() public {
        _forcedManual(3, XAUT, 6);
    }

    function test_E17_ForcedXautBatch() public {
        _forcedBatch(3, XAUT, 6);
    }

    function test_X02_OneInchWbtcZeroRoundedUserRollsBackBatch() public {
        bytes memory data = _forcedData(1);
        IOneInchRouterMainnet.SwapDescription memory desc = _decode(data);
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WBTC, true, true);
        address dust = makeAddr("oneinch-wbtc-dust-user");
        address whale = makeAddr("oneinch-wbtc-whale-user");
        _mintAndStake(dust, 1 ether);
        _mintAndStake(whale, 99_999_999 ether);
        vm.prank(dust);
        core.enableAutoStrategy(strategy);
        vm.prank(whale);
        core.enableAutoStrategy(strategy);
        _distribute(100e6);
        assertEq(core.claimable(dust), 1);
        assertEq(core.claimable(whale), 99_999_999);
        address[] memory users = new address[](2);
        users[0] = dust;
        users[1] = whale;
        vm.expectRevert(bytes4(keccak256("InvalidExecutionRequest()")));
        core.executeAutoStrategyBatch(
            strategy,
            users,
            desc.minReturnAmount,
            new uint256[](0),
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), data)
        );
        assertEq(core.claimable(dust), 1);
        assertEq(core.claimable(whale), 99_999_999);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(WBTC).balanceOf(dust), 0);
        assertEq(IERC20(WBTC).balanceOf(whale), 0);
        assertEq(IERC20(WBTC).balanceOf(proxy), 0);
        assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
    }

    function _invalidSwapData(bytes memory original, uint8 variant) private pure returns (bytes memory changed) {
        bytes memory args = new bytes(original.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = original[i + 4];
        }
        (address executor, IOneInchRouterMainnet.SwapDescription memory desc, bytes memory payload) =
            abi.decode(args, (address, IOneInchRouterMainnet.SwapDescription, bytes));
        if (variant == 0) desc.dstReceiver = payable(address(0xBEEF));
        else if (variant == 1) desc.amount = 99e6;
        else if (variant == 2) desc.minReturnAmount = 1;
        else if (variant == 3) desc.flags = 1;
        else if (variant == 4) payload = bytes("");
        changed = abi.encodeWithSelector(IOneInchRouterMainnet.swap.selector, executor, desc, payload);
        if (variant == 5) changed[0] = bytes1(0xff);
    }

    function test_E17_ForcedRouteRejectsInvalidFieldsAtomically() public {
        bytes memory original = _forcedData(0);
        IOneInchRouterMainnet.SwapDescription memory desc = _decode(original);
        address user = makeAddr("oneinch-forced-negative-user");
        bytes32 strategy = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(USDT, true, true);
        _mintAndStake(user, 1 ether);
        _distribute(100e6);
        _fundUSDC(proxy, 5e6);
        uint256 beforeOut = IERC20(USDT).balanceOf(user);
        for (uint8 variant; variant < 6; ++variant) {
            bytes memory changed = _invalidSwapData(original, variant);
            vm.prank(user);
            vm.expectRevert(bytes4(keccak256("InvalidExecutionRequest()")));
            core.claimAndExecute(
                strategy,
                desc.minReturnAmount,
                block.timestamp + 1 hours,
                abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), changed)
            );
            assertEq(core.claimable(user), 100e6);
            assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
            assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
            assertEq(IERC20(USDT).balanceOf(user), beforeOut);
            assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
        }
        vm.prank(user);
        vm.expectRevert();
        core.claimAndExecute(
            strategy,
            desc.minReturnAmount,
            block.timestamp,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), original)
        );
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("InvalidExecutionRequest()")));
        core.claimAndExecute(
            strategy,
            desc.minReturnAmount + 1,
            block.timestamp + 1 hours,
            abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), original)
        );
        assertEq(core.claimable(user), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertEq(IERC20(USDT).balanceOf(user), beforeOut);
        assertEq(IERC20(USDC).allowance(proxy, ONEINCH_ROUTER), 0);
    }
}
