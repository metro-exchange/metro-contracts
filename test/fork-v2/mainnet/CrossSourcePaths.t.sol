// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IXMetroDeFiAdapter} from "../../../src/interfaces/IXMetroDeFiAdapter.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

interface ICrossSpoke {
    function setUserPositionManager(address manager, bool approved) external;
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
}

/// @notice X-01: Six reward sources through claim, compound, five 1inch swaps, V3, V4, and Maple.
contract CrossSourcePathsMainnetTest is MainnetForkBase {
    string private constant MAPLE_FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/maple-api-response.json";
    string private constant ONEINCH_FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/oneinch-frontend-eoa-wallet-proxy-receiver.json";
    string private constant FORCED_FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/oneinch-excluding-pmm-v2-v3.json";

    address private user;
    address private contributor;
    bytes32 private syrupId;
    bytes32 private v3Id;
    bytes32 private v4Id;
    bytes32 private mapleId;
    bytes32[4] private additionalSwapIds;
    bool private pendingPrepared;

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
        v4Id = keccak256(
            abi.encode(
                block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0)
            )
        );
        mapleId = IXMetroAdapterAdminFork(proxy).setMapleConfig(MAPLE_ROUTER, bytes32(0), true, true);
        _createMetroPool(10_000 ether, 10_000e6);
        core.unpause();
        user = makeAddr("cross-source-user");
        contributor = makeAddr("cross-source-contributor");
        assertEq(vm.parseJsonAddress(vm.readFile(MAPLE_FIXTURE), ".lender"), proxy);
    }

    function _fundAndMigrate(address token, address holder, bool ythor) private {
        _fundMigrationToken(token, holder, user, 100 ether);
        vm.startPrank(user);
        IERC20(token).approve(address(escrow), 100 ether);
        if (ythor) escrow.migrateYThor(100 ether);
        else escrow.migrateThor(100 ether);
        vm.stopPrank();
    }

    function _contribute() private {
        core.setContributor(contributor, true);
        if (!metro.isMinter(address(this))) metro.setMinter(address(this), true);
        metro.mint(contributor, 100 ether);
        vm.startPrank(contributor);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, user);
        vm.stopPrank();
    }

    function _source(uint8 source) private {
        if (source == 0) {
            _mintAndStake(user, 100 ether);
        } else if (source == 1) {
            _fundAndMigrate(THOR, THOR_HOLDER, false);
        } else if (source == 2) {
            _fundAndMigrate(YTHOR, YTHOR_HOLDER, true);
        } else if (source == 3) {
            _contribute();
        } else if (source == 4) {
            _mintAndStake(user, 100 ether);
            _fundAndMigrate(THOR, THOR_HOLDER, false);
            _fundAndMigrate(YTHOR, YTHOR_HOLDER, true);
            _contribute();
        } else {
            // Earn rewards before removing all free shares; every entrypoint may still consume historical pending.
            _mintAndStake(user, 100 ether);
            _distribute(100e6);
            vm.prank(user);
            core.requestUnstake(100 ether);
            assertEq(core.totalSharesOf(user), 0);
            pendingPrepared = true;
        }
        if (!pendingPrepared) assertGt(core.totalSharesOf(user), 0);
    }

    function _route(uint256 cap) private view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(metro);
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), cap, abi.encode(path));
    }

    function _mapleAuthorization() private view returns (bytes memory) {
        string memory json = vm.readFile(MAPLE_FIXTURE);
        return abi.encode(
            vm.parseJsonUint(json, ".bitmap"),
            vm.parseJsonUint(json, ".deadline"),
            uint8(vm.parseJsonUint(json, ".v")),
            vm.parseJsonBytes32(json, ".r"),
            vm.parseJsonBytes32(json, ".s")
        );
    }

    function _oneInchExecutionData(uint8 pathKind) private view returns (bytes memory) {
        string memory json = vm.readFile(pathKind == 2 ? ONEINCH_FIXTURE : FORCED_FIXTURE);
        string memory routePath = pathKind == 2
            ? ".routes[4].calldata"
            : string.concat(".routes[", vm.toString(uint256(pathKind - 6)), "].calldata");
        bytes memory oneInchCalldata = vm.parseJsonBytes(json, routePath);
        assertEq(bytes4(oneInchCalldata), bytes4(0x07ed2379));
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), uint256(100e6), oneInchCalldata);
    }

    function _strategy(uint8 pathKind) private view returns (bytes32) {
        if (pathKind == 2) return syrupId;
        if (pathKind == 3) return v3Id;
        if (pathKind == 4) return v4Id;
        if (pathKind >= 6) return additionalSwapIds[pathKind - 6];
        return mapleId;
    }

    function _preparePath(uint8 pathKind, bool automatic) private {
        if (!pendingPrepared) _distribute(100e6);
        assertEq(core.claimable(user), 100e6);
        if (pathKind == 4) {
            vm.prank(user);
            ICrossSpoke(V4_SPOKE).setUserPositionManager(V4_GIVER, true);
        }
        if (automatic) {
            vm.prank(user);
            if (pathKind == 1) core.enableAutocompound();
            else core.enableAutoStrategy(_strategy(pathKind));
        }
    }

    function _assertReceived(uint8 pathKind, uint256 amountOut) private view {
        assertGt(amountOut, 0);
        if (pathKind == 1) {
            assertGt(core.balanceOf(user), 0);
        } else if (pathKind == 2 || pathKind == 5) {
            assertEq(IERC20(SYRUP_USDC).balanceOf(user), amountOut);
        } else if (pathKind >= 6) {
            address[4] memory tokens = [USDT, WBTC, GHO, XAUT];
            assertEq(IERC20(tokens[pathKind - 6]).balanceOf(user), amountOut);
        } else if (pathKind == 3) {
            assertGt(IERC20(A_USDC).balanceOf(user), 0);
        } else if (pathKind == 4) {
            assertEq(ICrossSpoke(V4_SPOKE).getUserSuppliedShares(V4_USDC_RESERVE, user), amountOut);
        }
        assertEq(core.claimable(user), 0);
    }

    function _execute(uint8 pathKind, bool automatic) private {
        _preparePath(pathKind, automatic);
        uint256 amountOut;
        if (pathKind == 1) {
            if (automatic) {
                address[] memory one = new address[](1);
                one[0] = user;
                amountOut = core.autocompoundBatch(one, 1, block.timestamp + 1 hours, _route(100e6));
            } else {
                vm.prank(user);
                amountOut = core.autocompound(1, block.timestamp + 1 hours, _route(100e6));
            }
        } else {
            bytes32 id = _strategy(pathKind);
            bytes memory data = pathKind == 2 || pathKind >= 6
                ? _oneInchExecutionData(pathKind)
                : pathKind == 5 ? _mapleAuthorization() : bytes("");
            uint256 deadline = pathKind == 2 || pathKind >= 6 ? block.timestamp + 1 hours : 0;
            if (automatic) {
                address[] memory one = new address[](1);
                one[0] = user;
                uint256[] memory minima = pathKind == 4 ? new uint256[](1) : new uint256[](0);
                if (pathKind == 4) minima[0] = 1;
                (uint256 rewardIn, uint256 output) = core.executeAutoStrategyBatch(id, one, 1, minima, deadline, data);
                assertEq(rewardIn, 100e6);
                amountOut = output;
            } else {
                vm.prank(user);
                (uint256 rewardIn, uint256 output) = core.claimAndExecute(id, 1, deadline, data);
                assertEq(rewardIn, 100e6);
                amountOut = output;
            }
        }
        _assertReceived(pathKind, amountOut);
    }

    function _matrix(uint8 source) private {
        _source(source);
        uint256 snapshot = vm.snapshotState();
        for (uint8 pathKind = 0; pathKind <= 9; ++pathKind) {
            uint8 modes = pathKind == 0 ? 1 : 2;
            for (uint8 mode = 0; mode < modes; ++mode) {
                assertTrue(vm.revertToState(snapshot));
                snapshot = vm.snapshotState();
                if (pathKind == 0) {
                    if (!pendingPrepared) _distribute(100e6);
                    assertEq(core.claimable(user), 100e6);
                    vm.prank(user);
                    assertEq(core.claimRewards(), 100e6);
                    assertEq(IERC20(USDC).balanceOf(user), 100e6);
                } else {
                    _execute(pathKind, mode == 1);
                }
            }
        }
    }

    /// X-01: Tests stake reachable paths.
    function test_X01_StakeReachablePaths() public {
        _matrix(0);
    }

    /// X-01: Tests THOR reachable paths.
    function test_X01_ThorReachablePaths() public {
        _matrix(1);
    }

    /// X-01: Tests yTHOR reachable paths.
    function test_X01_YThorReachablePaths() public {
        _matrix(2);
    }

    /// X-01: Tests contributor reachable paths.
    function test_X01_ContributorReachablePaths() public {
        _matrix(3);
    }

    /// X-01: Tests mixed reachable paths.
    function test_X01_MixedReachablePaths() public {
        _matrix(4);
    }

    /// X-01: Tests exited with old pending reachable paths.
    function test_X01_ExitedWithOldPendingReachablePaths() public {
        _matrix(5);
    }
}
