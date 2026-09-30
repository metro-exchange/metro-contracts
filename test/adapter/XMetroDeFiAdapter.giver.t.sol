// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    CompactAdapterFlowBase,
    CompactAaveV3Pool,
    CompactSyrupToken,
    CompactPermissionManager,
    CompactSyrupRouter
} from "./XMetroDeFiAdapter.flows.t.sol";
import {XMetroDeFiAdapter} from "../../src/XMetroDeFiAdapter.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {MockAaveV4Giver} from "../mocks/MockAaveV4Giver.sol";
import {MockAaveV4Spoke} from "../mocks/MockDepositProtocols.sol";

/// @notice Fault injection is unit-test evidence, not proof of live mainnet protocol success.
contract XMetroGiverSecurityTest is CompactAdapterFlowBase {
    bytes32 internal constant STORAGE_LOCATION = 0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;
    MockAaveV4Spoke internal spoke;
    MockAaveV4Giver internal giver;
    address internal user;
    bytes32 internal strategy;

    function setUp() public override {
        super.setUp();
        spoke = new MockAaveV4Spoke(address(usdc), 7);
        giver = new MockAaveV4Giver(address(spoke));
        spoke.updatePositionManager(address(giver), true);
        adapter.setAaveV4Config(address(spoke), address(giver), 7, true, true);
        user = makeAddr("giver-security-user");
        vm.prank(user);
        spoke.setUserPositionManager(address(giver), true);
        core.setPaused(false);
        usdc.mint(address(core), 100e6);
        strategy = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
    }

    function test_ConfigRequiresRegisteredActiveGiverAndCannotUseProxy() public {
        MockAaveV4Giver unregistered = new MockAaveV4Giver(address(1));
        spoke.updatePositionManager(address(unregistered), true);
        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.setAaveV4Config(address(spoke), address(unregistered), 7, true, true);
        unregistered.registerSpoke(address(spoke), true);
        spoke.updatePositionManager(address(unregistered), false);
        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.setAaveV4Config(address(spoke), address(unregistered), 7, true, true);
        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.setAaveV4Config(address(spoke), address(adapter), 7, true, true);
        vm.expectRevert(XMetroDeFiAdapter.ConfigurationFailure.selector);
        adapter.setAaveV4Config(address(spoke), address(giver), 7, true, true);
        assertEq(adapter.aaveV4Giver(), address(giver));
    }

    function test_RuntimeRechecksBothProtocolPermissionsAndUserApproval() public {
        IXMetroDeFiAdapter.ManualExecution memory request = _request();
        giver.registerSpoke(address(spoke), false);
        vm.expectRevert(XMetroDeFiAdapter.AaveV4AuthorizationFailure.selector);
        core.runManual(usdc, request);
        giver.registerSpoke(address(spoke), true);
        spoke.updatePositionManager(address(giver), false);
        vm.expectRevert(XMetroDeFiAdapter.AaveV4AuthorizationFailure.selector);
        core.runManual(usdc, request);
        spoke.updatePositionManager(address(giver), true);
        vm.prank(user);
        spoke.setUserPositionManager(address(giver), false);
        vm.expectRevert(XMetroDeFiAdapter.AaveV4AuthorizationFailure.selector);
        core.runManual(usdc, request);
        _assertUntouched();
    }

    function test_DisableDoesNotCallBrokenGiverAndRetainsConfiguration() public {
        uint64 revision = adapter.strategyInfo(strategy).strategyRevision;
        vm.mockCallRevert(address(giver), abi.encodeWithSelector(giver.isSpokeRegistered.selector), "broken getter");
        adapter.setAaveV4Config(address(0), address(0), 0, false, false);
        assertFalse(adapter.strategyInfo(strategy).enabled);
        assertEq(adapter.strategyInfo(strategy).strategyRevision, revision + 1);
        assertEq(adapter.aaveV4Giver(), address(giver));
        vm.clearMockedCalls();
    }

    function test_PartialConsumptionWrongReturnAndWrongSharesAreAtomic() public {
        IXMetroDeFiAdapter.ManualExecution memory request = _request();
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            // Under-pull leaves USDC in the Giver; under-reporting, forged shares, or zero output must fail.
            spoke.setBehavior(
                i == 3 ? 0 : 10_000, i == 0 ? 5_000 : 10_000, i == 1 ? 5_000 : 10_000, i == 2 ? 5_000 : 10_000, 0
            );
            vm.expectRevert(
                i == 3 ? XMetroDeFiAdapter.SlippageFailure.selector : XMetroDeFiAdapter.AccountingFailure.selector
            );
            core.runManual(usdc, request);
            _assertUntouched();
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_DonationIsolationAndReentryGuardPreserved() public {
        usdc.mint(address(adapter), 7e6);
        usdc.mint(address(giver), 11e6);
        spoke.setReentry(address(core), abi.encodeWithSelector(core.rawReentry.selector));
        IXMetroDeFiAdapter.ExecutionResult memory result = core.runManual(usdc, _request());
        assertEq(result.amountIn, 100e6);
        assertEq(result.amountOut, 100e6);
        assertEq(usdc.balanceOf(address(adapter)), 7e6);
        assertEq(usdc.balanceOf(address(giver)), 11e6);
        assertEq(usdc.allowance(address(adapter), address(giver)), 0);
        assertEq(usdc.allowance(address(giver), address(spoke)), 0);
        assertTrue(spoke.reentryAttempted());
        assertFalse(spoke.reentrySucceeded());
        assertFalse(spoke.isPositionManagerActive(address(adapter)));
    }

    function test_GiverAppendDoesNotMoveMapleOrExistingStorageAndSurvivesUpgrade() public {
        CompactAaveV3Pool pool = new CompactAaveV3Pool(address(usdc));
        bytes32 v3 = adapter.setAaveV3Config(address(pool), address(pool.aToken()), 17, true, true);
        CompactSyrupToken syrup = new CompactSyrupToken(address(usdc));
        CompactPermissionManager permissions = new CompactPermissionManager();
        CompactSyrupRouter maple = new CompactSyrupRouter(address(usdc), address(syrup), address(permissions));
        bytes32 mapleId = adapter.setMapleConfig(address(maple), bytes32("0:xMETRO"), true, true);
        bytes32 v3Before = keccak256(abi.encode(adapter.strategyInfo(v3)));
        bytes32 mapleBefore = keccak256(abi.encode(adapter.strategyInfo(mapleId)));
        bytes32[20] memory previous;
        for (uint256 i; i < 20; ++i) {
            previous[i] = vm.load(address(adapter), bytes32(uint256(STORAGE_LOCATION) + i));
        }
        uint64 revision = adapter.strategyInfo(strategy).strategyRevision;
        MockAaveV4Giver next = new MockAaveV4Giver(address(spoke));
        spoke.updatePositionManager(address(next), true);
        adapter.setAaveV4Config(address(spoke), address(next), 7, true, true);
        // Changing Giver uses only appended slot 20 and updates this strategy's mapped revision.
        for (uint256 i; i < 20; ++i) {
            assertEq(vm.load(address(adapter), bytes32(uint256(STORAGE_LOCATION) + i)), previous[i]);
        }
        assertEq(
            vm.load(address(adapter), bytes32(uint256(STORAGE_LOCATION) + 20)), bytes32(uint256(uint160(address(next))))
        );
        assertEq(adapter.strategyInfo(strategy).strategyRevision, revision + 1);
        assertTrue(adapter.strategyInfo(v3).enabled);
        assertTrue(adapter.strategyInfo(mapleId).enabled);
        assertEq(v3Before, keccak256(abi.encode(adapter.strategyInfo(v3))));
        assertEq(mapleBefore, keccak256(abi.encode(adapter.strategyInfo(mapleId))));
        address implementation = _create(vm.getCode("XMetroDeFiAdapter.sol:XMetroDeFiAdapter"));
        adapter.upgradeToAndCall(implementation, "");
        assertEq(adapter.aaveV4Giver(), address(next));
        // Upgrade may change logicEpoch in slot 2; all earlier configuration slots must remain stable.
        for (uint256 i; i < 20; ++i) {
            if (i != 2) assertEq(vm.load(address(adapter), bytes32(uint256(STORAGE_LOCATION) + i)), previous[i]);
        }
        assertTrue(adapter.strategyInfo(v3).enabled);
        assertTrue(adapter.strategyInfo(mapleId).enabled);
    }

    function _request() private view returns (IXMetroDeFiAdapter.ManualExecution memory) {
        return IXMetroDeFiAdapter.ManualExecution(strategy, user, 100e6, 1, 0, "");
    }

    function _assertUntouched() private view {
        assertEq(usdc.balanceOf(address(core)), 100e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(giver)), 0);
        assertEq(spoke.getUserSuppliedShares(7, user), 0);
        assertEq(spoke.supplyCallCount(), 0);
        assertEq(usdc.allowance(address(adapter), address(giver)), 0);
        assertEq(usdc.allowance(address(giver), address(spoke)), 0);
    }
}
