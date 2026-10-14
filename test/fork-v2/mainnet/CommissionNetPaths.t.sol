// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IXMetroDeFiAdapter} from "../../../src/interfaces/IXMetroDeFiAdapter.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

interface ICommissionNetSpoke {
    function setUserPositionManager(address manager, bool approved) external;
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
}

/// @notice X-06: Route rewards through the real Vault before claim, compound, swaps, deposits, or emergency payout.
contract CommissionNetPathsMainnetTest is MainnetForkBase {
    string private constant MAPLE_FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/maple-api-response.json";
    string private constant ONEINCH_FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/oneinch-frontend-eoa-wallet-proxy-receiver.json";
    string private constant FORCED_FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/oneinch-excluding-pmm-v2-v3.json";
    bytes32 private constant ROUTED = keccak256("DistributionRouted(address,address,uint256,uint256,uint256,uint64)");
    bytes32 private constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    address private user;
    bytes32 private syrupId;
    bytes32 private v3Id;
    bytes32 private v4Id;
    bytes32 private mapleId;
    bytes32[4] private additionalSwapIds;

    function setUp() public {
        _fork();
        _deploySystem();
        _configureSwaps();
        syrupId = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(SYRUP_USDC, true, true);
        additionalSwapIds[0] = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(USDT, true, true);
        additionalSwapIds[1] = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(WBTC, true, true);
        additionalSwapIds[2] = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(GHO, true, true);
        additionalSwapIds[3] = IXMetroAdapterAdminFork(proxy).setSwapTokenConfig(XAUT, true, true);
        v3Id = IXMetroAdapterAdminFork(proxy).setAaveV3Config(AAVE_V3_POOL, A_USDC, 37, true, true);
        IXMetroAdapterAdminFork(proxy).setAaveV4Config(V4_SPOKE, V4_GIVER, V4_USDC_RESERVE, true, true);
        v4Id = keccak256(abi.encode(block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"),
            IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0)));
        mapleId = IXMetroAdapterAdminFork(proxy).setMapleConfig(MAPLE_ROUTER, bytes32(0), true, true);
        _createMetroPool(10_000 ether, 10_000e6);
        core.unpause();
        user = makeAddr("commission-net-user");
        _mintAndStake(user, 100 ether);

        // Create a real Vault shortfall: each 125 USDC gross sends 25 to Vault and 100 to Core.
        string[] memory codes = new string[](1);
        codes[0] = "commission-net-fork";
        address[] memory payouts = new address[](1);
        payouts[0] = makeAddr("commission-net-payee");
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;
        vault.proposeSettlement(codes, payouts, amounts);
        vm.warp(vault.pendingActivationTime());
        vault.activateSettlement();
        assertEq(vault.requiredTopUp(), 1_000e6);
        distributor.setMaxCommissionSplitBps(2_000);
        assertEq(vm.parseJsonAddress(vm.readFile(MAPLE_FIXTURE), ".lender"), proxy);
    }

    function _expectRealSplit(Vm.Log[] memory logs) private view {
        bool routed;
        bool vaultTransfer;
        bool coreTransfer;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter == address(distributor) && entry.topics[0] == ROUTED) {
                assertEq(entry.topics[1], bytes32(uint256(uint160(address(this)))));
                assertEq(entry.topics[2], bytes32(uint256(uint160(address(vault)))));
                (uint256 gross, uint256 commission, uint256 net, uint64 at) =
                    abi.decode(entry.data, (uint256, uint256, uint256, uint64));
                assertEq(gross, 125e6);
                assertEq(commission, 25e6);
                assertEq(net, 100e6);
                assertEq(at, block.timestamp);
                routed = true;
            }
            if (entry.emitter == USDC && entry.topics[0] == TRANSFER
                && entry.topics[1] == bytes32(uint256(uint160(address(distributor))))) {
                address to = address(uint160(uint256(entry.topics[2])));
                uint256 amount = abi.decode(entry.data, (uint256));
                if (to == address(vault)) { assertEq(amount, 25e6); vaultTransfer = true; }
                if (to == address(core)) { assertEq(amount, 100e6); coreTransfer = true; }
            }
        }
        assertTrue(routed && vaultTransfer && coreTransfer);
    }

    function _distributeNet() private {
        vm.recordLogs();
        _distribute(125e6);
        _expectRealSplit(vm.getRecordedLogs());
        assertEq(IERC20(USDC).balanceOf(address(vault)), 25e6);
        assertEq(vault.requiredTopUp(), 975e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(core.claimable(user), 100e6);
        assertEq(IERC20(USDC).allowance(address(distributor), address(core)), 0);
    }

    function _route() private view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(metro);
        return abi.encode(uint8(0), abi.encode(path));
    }

    function _auth() private view returns (bytes memory) {
        string memory json = vm.readFile(MAPLE_FIXTURE);
        return abi.encode(vm.parseJsonUint(json, ".bitmap"), vm.parseJsonUint(json, ".deadline"),
            uint8(vm.parseJsonUint(json, ".v")), vm.parseJsonBytes32(json, ".r"), vm.parseJsonBytes32(json, ".s"));
    }

    function _data(uint8 kind) private view returns (bytes memory) {
        if (kind == 2 || kind >= 7) {
            string memory json = vm.readFile(kind == 2 ? ONEINCH_FIXTURE : FORCED_FIXTURE);
            string memory routePath = kind == 2 ? ".routes[4].calldata"
                : string.concat(".routes[", vm.toString(uint256(kind - 7)), "].calldata");
            bytes memory callData = vm.parseJsonBytes(json, routePath);
            assertEq(bytes4(callData), bytes4(0x07ed2379));
            return abi.encode(uint8(2), callData);
        }
        if (kind == 5) return _auth();
        return bytes("");
    }

    function _strategy(uint8 kind) private view returns (bytes32) {
        if (kind == 2) return syrupId;
        if (kind == 3) return v3Id;
        if (kind == 4) return v4Id;
        if (kind >= 7) return additionalSwapIds[kind - 7];
        return mapleId;
    }

    function _run(uint8 kind, bool automatic) private {
        _distributeNet();
        if (kind == 0) {
            vm.prank(user);
            assertEq(core.claimRewards(), 100e6);
            assertEq(IERC20(USDC).balanceOf(user), 100e6);
        } else if (kind == 6) {
            address[] memory one = new address[](1);
            one[0] = user;
            core.pause();
            assertEq(core.emergencyDistribute(one), 100e6);
            assertEq(IERC20(USDC).balanceOf(user), 100e6);
        } else {
            if (kind == 4) {
                vm.prank(user);
                ICommissionNetSpoke(V4_SPOKE).setUserPositionManager(V4_GIVER, true);
            }
            uint256 amountOut;
            if (kind == 1) {
                if (automatic) {
                    vm.prank(user);
                    core.enableAutocompound();
                    address[] memory one = new address[](1);
                    one[0] = user;
                    amountOut = core.autocompoundBatch(one, 1, block.timestamp + 1 hours, _route());
                } else {
                    vm.prank(user);
                    amountOut = core.autocompound(1, block.timestamp + 1 hours, _route());
                }
                assertGt(core.balanceOf(user), 100 ether);
            } else {
                bytes32 id = _strategy(kind);
                bytes memory data = _data(kind);
                uint256 deadline = kind == 2 || kind >= 7 ? block.timestamp + 1 hours : 0;
                if (automatic) {
                    vm.prank(user);
                    core.enableAutoStrategy(id);
                    address[] memory one = new address[](1);
                    one[0] = user;
                    uint256[] memory minima = kind == 4 ? new uint256[](1) : new uint256[](0);
                    if (kind == 4) minima[0] = 1;
                    (uint256 rewardIn, uint256 output) =
                        core.executeAutoStrategyBatch(id, one, 1, minima, deadline, data);
                    assertEq(rewardIn, 100e6);
                    amountOut = output;
                } else {
                    vm.prank(user);
                    (uint256 rewardIn, uint256 output) = core.claimAndExecute(id, 1, deadline, data);
                    assertEq(rewardIn, 100e6);
                    amountOut = output;
                }
                if (kind == 2 || kind == 5) assertEq(IERC20(SYRUP_USDC).balanceOf(user), amountOut);
                else if (kind >= 7) {
                    address[4] memory tokens = [USDT, WBTC, GHO, XAUT];
                    assertEq(IERC20(tokens[kind - 7]).balanceOf(user), amountOut);
                }
                else if (kind == 3) assertGt(IERC20(A_USDC).balanceOf(user), 0);
                else assertEq(ICommissionNetSpoke(V4_SPOKE).getUserSuppliedShares(V4_USDC_RESERVE, user), amountOut);
            }
            assertGt(amountOut, 0);
        }
        assertEq(core.claimable(user), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 25e6);
        assertEq(vault.requiredTopUp(), 975e6);
    }

    /// X-06: Tests net reward reachable paths and emergency.
    function test_X06_NetRewardReachablePathsAndEmergency() public {
        uint256 snapshot = vm.snapshotState();
        for (uint8 kind = 0; kind <= 10; ++kind) {
            uint8 modes = kind == 0 || kind == 6 ? 1 : 2;
            for (uint8 mode = 0; mode < modes; ++mode) {
                assertTrue(vm.revertToState(snapshot));
                snapshot = vm.snapshotState();
                _run(kind, mode == 1);
            }
        }
    }
}
