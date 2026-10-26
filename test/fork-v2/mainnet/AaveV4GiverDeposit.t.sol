// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IXMetroDeFiAdapter} from "../../../src/interfaces/IXMetroDeFiAdapter.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

interface IAaveV4SpokeMainnet {
    function isPositionManagerActive(address manager) external view returns (bool);
    function isPositionManager(address user, address manager) external view returns (bool);
    function setUserPositionManager(address manager, bool approved) external;
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
}

interface IAaveV4GiverMainnet {
    function isSpokeRegistered(address spoke) external view returns (bool);
}

/// @notice E-19: Use the official Giver and active Spoke without changing mainnet protocol permissions.
contract AaveV4GiverDepositMainnetTest is MainnetForkBase {
    uint256 private constant RESERVE = 7;
    bytes32 private constant GIVER_SUPPLY = keccak256("SupplyOnBehalfOf(address,address,address,uint256,uint256,uint256)");
    bytes32 private constant SPOKE_SUPPLY = keccak256("Supply(uint256,address,address,uint256,uint256)");
    bytes32 private constant SETTLED = keccak256("UserStrategySettled(bytes32,address,uint256,uint256)");
    bytes32 private constant MANUAL = keccak256("ClaimAndExecuted(address,bytes32,uint256,uint256)");
    bytes4 private constant AUTH_ERROR = bytes4(keccak256("AaveV4AuthorizationFailure()"));
    bytes4 private constant SLIPPAGE_ERROR = bytes4(keccak256("SlippageFailure()"));

    IAaveV4SpokeMainnet private spoke;
    IAaveV4GiverMainnet private giver;
    bytes32 private strategy;
    address[3] private users;

    function setUp() public {
        _fork();
        _deploySystem();
        spoke = IAaveV4SpokeMainnet(V4_SPOKE);
        giver = IAaveV4GiverMainnet(V4_GIVER);
        IXMetroAdapterAdminFork(proxy).setAaveV4Config(V4_SPOKE, V4_GIVER, RESERVE, true, true);
        strategy = keccak256(abi.encode(block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0)));
        assertTrue(adapter.strategyInfo(strategy).enabled);
        core.unpause();
        users[0] = makeAddr("aave-v4-alice");
        users[1] = makeAddr("aave-v4-bob");
        users[2] = makeAddr("aave-v4-carol");
        _mintAndStake(users[0], 2 ether);
        _mintAndStake(users[1], 3 ether);
        _mintAndStake(users[2], 5 ether);
    }

    function _three() private view returns (address[] memory list) {
        list = new address[](3);
        for (uint256 i; i < 3; ++i) list[i] = users[i];
    }

    function _minima() private pure returns (uint256[] memory list) {
        list = new uint256[](3);
        list[0] = 1;
        list[1] = 1;
        list[2] = 1;
    }

    function _authorize(address user, bool allowed) private {
        vm.prank(user);
        spoke.setUserPositionManager(V4_GIVER, allowed);
        assertEq(spoke.isPositionManager(user, V4_GIVER), allowed);
    }

    function _prepareAuto() private {
        for (uint256 i; i < 3; ++i) {
            if (!spoke.isPositionManager(users[i], V4_GIVER)) _authorize(users[i], true);
            vm.prank(users[i]);
            core.enableAutoStrategy(strategy);
        }
    }

    function _assertAllowanceAndDonation(uint256 giverBaseline) private view {
        assertEq(IERC20(USDC).balanceOf(V4_GIVER), giverBaseline);
        assertEq(IERC20(USDC).allowance(proxy, V4_GIVER), 0);
        assertEq(IERC20(USDC).allowance(proxy, V4_SPOKE), 0);
        assertEq(IERC20(USDC).balanceOf(proxy), 0);
        assertFalse(spoke.isPositionManagerActive(proxy));
    }

    function _assertSupplyLogs(Vm.Log[] memory logs, address user, uint256 assets, uint256 shares, bool batch)
        private
        view
    {
        uint256 giverCount;
        uint256 spokeCount;
        uint256 projectCount;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 4 && entry.emitter == V4_GIVER && entry.topics[0] == GIVER_SUPPLY
                && entry.topics[3] == bytes32(uint256(uint160(user)))) {
                assertEq(entry.topics[1], bytes32(uint256(uint160(V4_SPOKE))));
                assertEq(entry.topics[2], bytes32(uint256(uint160(proxy))));
                (uint256 reserve, uint256 loggedShares, uint256 loggedAssets) =
                    abi.decode(entry.data, (uint256, uint256, uint256));
                assertEq(reserve, RESERVE);
                assertEq(loggedShares, shares);
                assertEq(loggedAssets, assets);
                ++giverCount;
            }
            if (entry.topics.length == 4 && entry.emitter == V4_SPOKE && entry.topics[0] == SPOKE_SUPPLY
                && entry.topics[3] == bytes32(uint256(uint160(user)))) {
                assertEq(entry.topics[1], bytes32(RESERVE));
                assertEq(entry.topics[2], bytes32(uint256(uint160(V4_GIVER))));
                (uint256 loggedShares, uint256 loggedAssets) = abi.decode(entry.data, (uint256, uint256));
                assertEq(loggedShares, shares);
                assertEq(loggedAssets, assets);
                ++spokeCount;
            }
            if (batch && entry.topics.length == 3 && entry.emitter == proxy && entry.topics[0] == SETTLED
                && entry.topics[2] == bytes32(uint256(uint160(user)))) {
                assertEq(entry.topics[1], strategy);
                (uint256 loggedAssets, uint256 loggedShares) = abi.decode(entry.data, (uint256, uint256));
                assertEq(loggedAssets, assets);
                assertEq(loggedShares, shares);
                ++projectCount;
            }
            if (!batch && entry.topics.length == 3 && entry.emitter == address(core) && entry.topics[0] == MANUAL
                && entry.topics[1] == bytes32(uint256(uint160(user)))) {
                assertEq(entry.topics[2], strategy);
                (uint256 loggedAssets, uint256 loggedShares) = abi.decode(entry.data, (uint256, uint256));
                assertEq(loggedAssets, assets);
                assertEq(loggedShares, shares);
                ++projectCount;
            }
        }
        assertEq(giverCount, 1);
        assertEq(spokeCount, 1);
        assertEq(projectCount, 1);
    }

    /// E-19.01/.02: Tests official registration activation and user authorization.
    function test_E19_OfficialRegistrationActivationAndUserAuthorization() public {
        assertTrue(giver.isSpokeRegistered(V4_SPOKE));
        assertTrue(spoke.isPositionManagerActive(V4_GIVER));
        assertFalse(spoke.isPositionManagerActive(proxy));
        assertFalse(spoke.isPositionManager(users[0], V4_GIVER));
        _authorize(users[0], true);
        assertEq(IERC20(USDC).allowance(users[0], proxy), 0);
        assertEq(IERC20(USDC).allowance(users[0], V4_GIVER), 0);
    }

    /// E-19.03/.07: Tests manual100 USDC through giver and both protocol events.
    function test_E19_Manual100UsdcThroughGiverAndBothProtocolEvents() public {
        _authorize(users[0], true);
        _distribute(500e6);
        uint256 giverBaseline = IERC20(USDC).balanceOf(V4_GIVER);
        uint256 beforeShares = spoke.getUserSuppliedShares(RESERVE, users[0]);
        vm.recordLogs();
        vm.prank(users[0]);
        (uint256 amountIn, uint256 shares) = core.claimAndExecute(strategy, 1, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(amountIn, 100e6);
        assertGt(shares, 0);
        assertEq(spoke.getUserSuppliedShares(RESERVE, users[0]) - beforeShares, shares);
        _assertSupplyLogs(logs, users[0], amountIn, shares, false);
        assertEq(core.claimable(users[0]), 0);
        assertEq(core.claimable(users[1]), 150e6);
        assertEq(core.claimable(users[2]), 250e6);
        _assertAllowanceAndDonation(giverBaseline);
        emit log_named_uint("Aave V4 Giver manual shares", shares);
    }

    /// E-19.04/.07: Tests batch three per user supplies and donation baseline.
    function test_E19_BatchThreePerUserSuppliesAndDonationBaseline() public {
        _prepareAuto();
        _distribute(100e6);
        _fundUSDC(V4_GIVER, 7e6);
        uint256 giverBaseline = IERC20(USDC).balanceOf(V4_GIVER);
        vm.recordLogs();
        (uint256 amountIn, uint256 totalShares) =
            core.executeAutoStrategyBatch(strategy, _three(), 1, _minima(), 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(amountIn, 100e6);
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            uint256 shares = spoke.getUserSuppliedShares(RESERVE, users[i]);
            assertGt(shares, 0);
            uint256 assets = i == 0 ? 20e6 : i == 1 ? 30e6 : 50e6;
            _assertSupplyLogs(logs, users[i], assets, shares, true);
            assertEq(core.claimable(users[i]), 0);
            sum += shares;
        }
        assertEq(totalShares, sum);
        _assertAllowanceAndDonation(giverBaseline);
    }

    /// E-19.05: Tests missing or revoked authorization preserves pending.
    function test_E19_MissingOrRevokedAuthorizationPreservesPending() public {
        _distribute(500e6);
        vm.prank(users[0]);
        vm.expectRevert(AUTH_ERROR);
        core.claimAndExecute(strategy, 1, 0, "");
        _authorize(users[0], true);
        _authorize(users[0], false);
        vm.prank(users[0]);
        vm.expectRevert(AUTH_ERROR);
        core.claimAndExecute(strategy, 1, 0, "");
        assertEq(core.claimable(users[0]), 100e6);
        assertEq(spoke.getUserSuppliedShares(RESERVE, users[0]), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 500e6);
    }

    function _assertBatchUntouched() private view {
        assertEq(core.claimable(users[0]), 20e6);
        assertEq(core.claimable(users[1]), 30e6);
        assertEq(core.claimable(users[2]), 50e6);
        for (uint256 i; i < 3; ++i) assertEq(spoke.getUserSuppliedShares(RESERVE, users[i]), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(USDC).allowance(proxy, V4_GIVER), 0);
    }

    /// E-19.06: Tests last user revoked rolls back earlier supplies.
    function test_E19_LastUserRevokedRollsBackEarlierSupplies() public {
        _prepareAuto();
        _distribute(100e6);
        _authorize(users[2], false);
        vm.expectRevert(AUTH_ERROR);
        core.executeAutoStrategyBatch(strategy, _three(), 1, _minima(), 0, "");
        _assertBatchUntouched();
    }

    /// E-19.06: Tests second user revoked rolls back first supply.
    function test_E19_SecondUserRevokedRollsBackFirstSupply() public {
        _prepareAuto();
        _distribute(100e6);
        _authorize(users[1], false);
        vm.expectRevert(AUTH_ERROR);
        core.executeAutoStrategyBatch(strategy, _three(), 1, _minima(), 0, "");
        _assertBatchUntouched();
    }

    /// E-19.06: Tests user and total minimum rollback.
    function test_E19_UserAndTotalMinimumRollback() public {
        _prepareAuto();
        _distribute(100e6);
        uint256[] memory minima = _minima();
        minima[2] = type(uint256).max;
        vm.expectRevert(SLIPPAGE_ERROR);
        core.executeAutoStrategyBatch(strategy, _three(), 1, minima, 0, "");
        _assertBatchUntouched();
        minima[2] = 1;
        vm.expectRevert(SLIPPAGE_ERROR);
        core.executeAutoStrategyBatch(strategy, _three(), type(uint256).max, minima, 0, "");
        _assertBatchUntouched();
    }

    /// X-02: Tests filtered candidate minima keep original indexes.
    function test_X02_FilteredCandidateMinimaKeepOriginalIndexes() public {
        _prepareAuto();
        _distribute(100e6);
        address[] memory candidates = new address[](7);
        candidates[0] = address(0);
        candidates[1] = users[0];
        candidates[2] = makeAddr("v4-unselected");
        candidates[3] = users[1];
        candidates[4] = users[0];
        candidates[5] = users[2];
        candidates[6] = address(0);
        uint256[] memory minima = new uint256[](7);
        minima[1] = 1;
        minima[3] = 1;
        minima[5] = type(uint256).max;
        vm.expectRevert(SLIPPAGE_ERROR);
        core.executeAutoStrategyBatch(strategy, candidates, 1, minima, 0, "");
        _assertBatchUntouched();
        minima[5] = 1;
        vm.expectRevert();
        core.executeAutoStrategyBatch(strategy, candidates, 1, new uint256[](6), 0, "");
        _assertBatchUntouched();
        (uint256 amountIn, uint256 shares) =
            core.executeAutoStrategyBatch(strategy, candidates, 1, minima, 0, "");
        assertEq(amountIn, 100e6);
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 actual = spoke.getUserSuppliedShares(RESERVE, users[i]);
            assertGt(actual, 0);
            assertEq(core.claimable(users[i]), 0);
            total += actual;
        }
        assertEq(shares, total);
        assertEq(IERC20(USDC).allowance(proxy, V4_GIVER), 0);
    }
}
