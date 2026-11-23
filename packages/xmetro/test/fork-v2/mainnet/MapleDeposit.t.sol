// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

interface IMapleRouterMainnet {
    function asset() external view returns (address);
    function pool() external view returns (address);
    function poolManager() external view returns (address);
    function poolPermissionManager() external view returns (address);
    function nonces(address lender) external view returns (uint256);
}

interface IMaplePermissionManagerMainnet {
    function poolBitmaps(address manager, bytes32 permission) external view returns (uint256);
    function hasPermission(address manager, address lender, bytes32 permission) external view returns (bool);
}

/// @notice E-20: Maple API signature for this Proxy and real SyrupRouter/PermissionManager interactions.
contract MapleDepositMainnetTest is MainnetForkBase {
    bytes32 private constant P_DEPOSIT = bytes32("P:deposit");
    bytes32 private constant P_TRANSFER = bytes32("P:transfer");
    bytes32 private constant P_TRANSFER_FROM = bytes32("P:transferFrom");
    string private constant FIXTURE =
        "integration/testing/ethereum-fork/evidence/2026-09-29-eth26077998-01/maple-api-response.json";

    IMapleRouterMainnet private router;
    IMaplePermissionManagerMainnet private permissions;
    address private manager;
    bytes32 private strategy;
    address[3] private users;

    struct Signature {
        uint256 bitmap;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    event MapleAuthorizationConsumed(uint256 indexed routerNonce);
    event ClaimAndExecuted(address indexed user, bytes32 indexed strategyId, uint256 rewardIn, uint256 amountOut);
    event UserStrategySettled(bytes32 indexed strategyId, address indexed user, uint256 amountIn, uint256 amountOut);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    function setUp() public {
        _fork();
        _deploySystem();
        // This fixture stores the official API signature obtained for this Proxy at 2026-09-29 07:29 UTC.
        assertEq(vm.parseJsonAddress(vm.readFile(FIXTURE), ".lender"), proxy);
        assertEq(vm.parseJsonUint(vm.readFile(FIXTURE), ".forkBlock"), FORK_BLOCK);
        router = IMapleRouterMainnet(MAPLE_ROUTER);
        assertEq(router.asset(), USDC);
        assertEq(router.pool(), SYRUP_USDC);
        manager = router.poolManager();
        permissions = IMaplePermissionManagerMainnet(router.poolPermissionManager());
        assertGt(manager.code.length, 0);
        assertGt(address(permissions).code.length, 0);
        strategy = IXMetroAdapterAdminFork(proxy).setMapleConfig(MAPLE_ROUTER, bytes32(0), true, true);
        core.unpause();
        users[0] = makeAddr("maple-alice");
        users[1] = makeAddr("maple-bob");
        users[2] = makeAddr("maple-carol");
    }

    function _signature() private view returns (Signature memory sig) {
        string memory json = vm.readFile(FIXTURE);
        sig.bitmap = vm.parseJsonUint(json, ".bitmap");
        sig.deadline = vm.parseJsonUint(json, ".deadline");
        sig.v = uint8(vm.parseJsonUint(json, ".v"));
        sig.r = vm.parseJsonBytes32(json, ".r");
        sig.s = vm.parseJsonBytes32(json, ".s");
        assertEq(sig.bitmap, permissions.poolBitmaps(manager, P_DEPOSIT));
        assertGt(sig.deadline, block.timestamp);
        assertTrue(sig.v == 27 || sig.v == 28);
    }

    function _authorization(Signature memory sig) private pure returns (bytes memory) {
        return abi.encode(sig.bitmap, sig.deadline, sig.v, sig.r, sig.s);
    }

    function _stakeThree() private {
        _mintAndStake(users[0], 2 ether);
        _mintAndStake(users[1], 3 ether);
        _mintAndStake(users[2], 5 ether);
    }

    function _users() private view returns (address[] memory list) {
        list = new address[](3);
        for (uint256 i; i < 3; ++i) list[i] = users[i];
    }

    function _assertPermissionState(bool expected) private view {
        assertTrue(permissions.hasPermission(manager, MAPLE_ROUTER, P_DEPOSIT));
        assertEq(permissions.hasPermission(manager, proxy, P_DEPOSIT), expected);
        assertEq(permissions.poolBitmaps(manager, P_TRANSFER), 0);
        assertEq(permissions.poolBitmaps(manager, P_TRANSFER_FROM), 0);
    }

    /// E-20.01/.02/.07: Tests real api authorization and manual deposit.
    function test_E20_RealApiAuthorizationAndManualDeposit() public {
        Signature memory sig = _signature();
        _assertPermissionState(false);
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        uint256 nonceBefore = router.nonces(proxy);
        uint256 syrupBefore = IERC20(SYRUP_USDC).balanceOf(users[0]);
        vm.recordLogs();
        vm.prank(users[0]);
        (uint256 amountIn, uint256 shares) = core.claimAndExecute(strategy, 1, 0, _authorization(sig));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(amountIn, 100e6);
        assertGt(shares, 0);
        assertEq(IERC20(SYRUP_USDC).balanceOf(users[0]) - syrupBefore, shares);
        assertEq(router.nonces(proxy), nonceBefore + 1);
        _assertPermissionState(true);
        assertEq(core.claimable(users[0]), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        assertEq(IERC20(USDC).balanceOf(proxy), 0);
        assertEq(IERC20(USDC).allowance(proxy, MAPLE_ROUTER), 0);
        bool authEvent;
        bool claimEvent;
        bool protocolDeposit;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == proxy && logs[i].topics[0] == MapleAuthorizationConsumed.selector) {
                assertEq(uint256(logs[i].topics[1]), nonceBefore + 1);
                authEvent = true;
            }
            if (logs[i].emitter == address(core) && logs[i].topics[0] == ClaimAndExecuted.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), users[0]);
                assertEq(logs[i].topics[2], strategy);
                (uint256 eventIn, uint256 eventOut) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(eventIn, amountIn);
                assertEq(eventOut, shares);
                claimEvent = true;
            }
            if (logs[i].emitter == SYRUP_USDC && logs[i].topics[0] == Deposit.selector) {
                (uint256 eventAssets, uint256 eventShares) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(eventAssets, amountIn);
                assertEq(eventShares, shares);
                protocolDeposit = true;
            }
        }
        assertTrue(authEvent);
        assertTrue(claimEvent);
        assertTrue(protocolDeposit);
        emit log_named_uint("Maple real shares for 100 USDC", shares);
    }

    /// E-20.03: Tests subsequent deposit needs no signature.
    function test_E20_SubsequentDepositNeedsNoSignature() public {
        Signature memory sig = _signature();
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        vm.prank(users[0]);
        core.claimAndExecute(strategy, 1, 0, _authorization(sig));
        uint256 nonceAfter = router.nonces(proxy);
        _distribute(50e6);
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(strategy, 1, 0, _authorization(sig));
        assertEq(core.claimable(users[0]), 50e6);
        vm.prank(users[0]);
        (uint256 amountIn, uint256 shares) = core.claimAndExecute(strategy, 1, 0, "");
        assertEq(amountIn, 50e6);
        assertGt(shares, 0);
        assertEq(router.nonces(proxy), nonceAfter);
        assertEq(IERC20(USDC).allowance(proxy, MAPLE_ROUTER), 0);
    }

    /// E-20.04/.07: Tests batch one real deposit pro rata and donation isolation.
    function test_E20_BatchOneRealDepositProRataAndDonationIsolation() public {
        Signature memory sig = _signature();
        _stakeThree();
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            core.enableAutoStrategy(strategy);
        }
        _distribute(100e6);
        assertEq(core.claimable(users[0]), 20e6);
        assertEq(core.claimable(users[1]), 30e6);
        assertEq(core.claimable(users[2]), 50e6);
        uint256[] memory beforeBalances = new uint256[](3);
        uint256 nonceBefore = router.nonces(proxy);
        vm.recordLogs();
        (uint256 rewardIn, uint256 shares) =
            core.executeAutoStrategyBatch(strategy, _users(), 1, new uint256[](0), 0, _authorization(sig));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(rewardIn, 100e6);
        assertGt(shares, 0);
        assertEq(router.nonces(proxy), nonceBefore + 1);
        uint256 allocated;
        uint256 settledEvents;
        uint256 protocolDeposits;
        for (uint256 i; i < 3; ++i) {
            uint256 actual = IERC20(SYRUP_USDC).balanceOf(users[i]) - beforeBalances[i];
            assertGt(actual, 0);
            allocated += actual;
            assertEq(core.claimable(users[i]), 0);
            // Allocate by input ratio, assigning at most one integer remainder to the largest input user.
            if (i < 2) assertEq(actual, shares * (i == 0 ? 20 : 30) / 100);
        }
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == proxy && logs[i].topics[0] == UserStrategySettled.selector) {
                assertEq(logs[i].topics[1], strategy);
                address recipient = address(uint160(uint256(logs[i].topics[2])));
                uint256 userIndex = recipient == users[0] ? 0 : recipient == users[1] ? 1 : 2;
                assertEq(recipient, users[userIndex]);
                (uint256 eventIn, uint256 eventOut) = abi.decode(logs[i].data, (uint256, uint256));
                if (userIndex == 0) assertEq(eventIn, 20e6);
                else if (userIndex == 1) assertEq(eventIn, 30e6);
                else assertEq(eventIn, 50e6);
                assertEq(eventOut, IERC20(SYRUP_USDC).balanceOf(recipient));
                ++settledEvents;
            }
            if (logs[i].emitter == SYRUP_USDC && logs[i].topics[0] == Deposit.selector) {
                (uint256 eventAssets, uint256 eventShares) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(eventAssets, rewardIn);
                assertEq(eventShares, shares);
                ++protocolDeposits;
            }
        }
        assertEq(settledEvents, 3);
        assertEq(protocolDeposits, 1);
        assertEq(allocated, shares);
        assertEq(IERC20(USDC).allowance(proxy, MAPLE_ROUTER), 0);
        uint256 donation = IERC20(SYRUP_USDC).balanceOf(users[0]) / 10;
        vm.prank(users[0]);
        assertTrue(IERC20(SYRUP_USDC).transfer(proxy, donation));
        _distribute(100e6);
        uint256[] memory secondBefore = new uint256[](3);
        for (uint256 i; i < 3; ++i) secondBefore[i] = IERC20(SYRUP_USDC).balanceOf(users[i]);
        (uint256 secondIn, uint256 secondShares) =
            core.executeAutoStrategyBatch(strategy, _users(), 1, new uint256[](0), 0, "");
        assertEq(secondIn, 100e6);
        uint256 secondAllocated;
        for (uint256 i; i < 3; ++i) secondAllocated += IERC20(SYRUP_USDC).balanceOf(users[i]) - secondBefore[i];
        assertEq(secondAllocated, secondShares);
        assertEq(IERC20(SYRUP_USDC).balanceOf(proxy), donation);
        assertEq(router.nonces(proxy), nonceBefore + 1);
        // With zero poolBitmaps, real syrupUSDC transfer and transferFrom remain available.
        uint256 bobBefore = IERC20(SYRUP_USDC).balanceOf(users[1]);
        vm.prank(users[1]);
        assertTrue(IERC20(SYRUP_USDC).approve(users[2], 1));
        vm.prank(users[2]);
        assertTrue(IERC20(SYRUP_USDC).transferFrom(users[1], users[2], 1));
        assertEq(IERC20(SYRUP_USDC).balanceOf(users[1]), bobBefore - 1);
    }

    /// E-20.05: Tests zero and named deposit data both accepted.
    function test_E20_ZeroAndNamedDepositDataBothAccepted() public {
        Signature memory sig = _signature();
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        uint256 snapshot = vm.snapshotState();
        vm.prank(users[0]);
        (, uint256 zeroShares) = core.claimAndExecute(strategy, 1, 0, _authorization(sig));
        assertGt(zeroShares, 0);
        assertTrue(vm.revertToState(snapshot));
        strategy = IXMetroAdapterAdminFork(proxy).setMapleConfig(MAPLE_ROUTER, bytes32("0:XMetro"), true, true);
        vm.prank(users[0]);
        (, uint256 namedShares) = core.claimAndExecute(strategy, 1, 0, _authorization(sig));
        assertGt(namedShares, 0);
        assertEq(namedShares, zeroShares);
    }

    /// E-20.06/.07: Tests invalid authorization and slippage rollback.
    function test_E20_InvalidAuthorizationAndSlippageRollback() public {
        Signature memory sig = _signature();
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        uint256 nonceBefore = router.nonces(proxy);
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(strategy, 1, 0, "");
        Signature memory bad = sig;
        bad.bitmap = 0;
        _mustFail(bad);
        bad = sig;
        bad.v = 29;
        _mustFail(bad);
        bad = sig;
        bad.deadline = block.timestamp;
        _mustFail(bad);
        bad = sig;
        bad.r = bytes32(uint256(sig.r) ^ 1);
        _mustFail(bad);
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(strategy, type(uint256).max, 0, _authorization(sig));
        assertEq(core.claimable(users[0]), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(SYRUP_USDC).balanceOf(users[0]), 0);
        assertEq(router.nonces(proxy), nonceBefore);
        _assertPermissionState(false);
        assertEq(IERC20(USDC).allowance(proxy, MAPLE_ROUTER), 0);
    }

    /// E-20.06: Tests old Proxy signature cannot authorize replacement.
    function test_E20_OldProxySignatureCannotAuthorizeReplacement() public {
        Signature memory sig = _signature();
        address oldProxy = proxy;
        core.pause();
        address newProxy = address(new ERC1967Proxy(
            implementation,
            abi.encodeWithSignature("initialize(address,address,address)", address(core), USDC, address(metro))
        ));
        assertNotEq(newProxy, oldProxy);
        core.setDeFiAdapter(newProxy);
        bytes32 newStrategy = IXMetroAdapterAdminFork(newProxy).setMapleConfig(MAPLE_ROUTER, bytes32(0), true, true);
        core.unpause();
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        uint256 nonceBefore = router.nonces(newProxy);
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(newStrategy, 1, 0, _authorization(sig));
        assertEq(router.nonces(newProxy), nonceBefore);
        assertFalse(permissions.hasPermission(manager, newProxy, P_DEPOSIT));
        assertEq(core.claimable(users[0]), 100e6);
        assertEq(IERC20(USDC).allowance(newProxy, MAPLE_ROUTER), 0);
    }

    function _mustFail(Signature memory bad) private {
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(strategy, 1, 0, _authorization(bad));
    }
}
