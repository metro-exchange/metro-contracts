// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MetroToken} from "../../src/metro.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockSyrupUSDC} from "../mocks/MockSyrupUSDC.sol";
import {MockAaveV4Giver} from "../mocks/MockAaveV4Giver.sol";
import {
    MockAaveV3Pool,
    MockScaledAToken,
    MockAaveV4Spoke,
    MockPoolPermissionManager,
    MockSyrupRouter
} from "../mocks/MockDepositProtocols.sol";

interface IBaseQAMockAdapterAdmin {
    function setAaveV3Config(address pool, address aToken, uint16 referralCode, bool enabled, bool autoEnabled)
        external
        returns (bytes32);
    function setAaveV4Config(address spoke, address giver, uint256 reserveId, bool enabled, bool autoEnabled) external;
    function setMapleConfig(address router, bytes32 depositData, bool enabled, bool autoEnabled)
        external
        returns (bytes32);
}

/// @notice Local QA Mock tests; these are neither Ethereum fork nor Base on-chain evidence.
/// @dev Deploys the real Core and release Adapter Proxy; rewards use the actual ledger without vm.mockCall.
contract BaseQAProtocolMocksTest is Test {
    uint256 internal constant SIGNER_KEY = 0xA110CE;
    uint256 internal constant INDEX = 12e26;
    bytes32 internal constant DEPOSIT = bytes32("P:deposit");
    bytes32 internal constant DATA = bytes32("0:xMETRO");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant MINT_TOPIC = keccak256("Mint(address,address,uint256,uint256,uint256)");
    bytes32 internal constant V3_SUPPLY_TOPIC = keccak256("Supply(address,address,address,uint256,uint16)");
    bytes32 internal constant V4_SUPPLY_TOPIC = keccak256("Supply(uint256,address,address,uint256,uint256)");
    bytes32 internal constant POOL_DEPOSIT_TOPIC = keccak256("Deposit(address,address,uint256,uint256)");
    bytes32 internal constant ROUTER_DEPOSIT_TOPIC = keccak256("DepositData(address,uint256,bytes32)");

    ERC20Mintable internal usdc;
    MetroToken internal metro;
    xMETRO internal core;
    RewardDistributor internal distributor;
    address internal adapter;
    MockAaveV3Pool internal v3;
    MockScaledAToken internal aToken;
    MockAaveV4Spoke internal spoke;
    MockAaveV4Giver internal giver;
    MockSyrupUSDC internal syrup;
    MockPoolPermissionManager internal permissions;
    MockSyrupRouter internal maple;
    bytes32 internal v3Id;
    bytes32 internal v4Id;
    bytes32 internal mapleId;
    address[] internal users;

    function setUp() public {
        usdc = new ERC20Mintable("Test USDC", "TestUSDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        core = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);
        bytes memory code = vm.parseJsonBytes(
            vm.readFile("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"), ".bytecode.object"
        );
        address implementation;
        assembly ("memory-safe") { implementation := create(0, add(code, 32), mload(code)) }
        require(implementation != address(0), "adapter deployment failed");
        adapter = address(
            new ERC1967Proxy(
                implementation,
                abi.encodeWithSignature(
                    "initialize(address,address,address)", address(core), address(usdc), address(metro)
                )
            )
        );
        core.setDeFiAdapter(adapter);
        distributor = new RewardDistributor(address(core), address(this));
        distributor.setOperator(address(this), true);
        core.setRewardDistributor(address(distributor));
        core.setAutoCompoundOperator(address(this), true);
        v3 = new MockAaveV3Pool(address(usdc), INDEX);
        aToken = v3.aUsdc();
        spoke = new MockAaveV4Spoke(address(usdc), 7);
        giver = new MockAaveV4Giver(address(spoke));
        spoke.updatePositionManager(address(giver), true);
        syrup = new MockSyrupUSDC(address(usdc));
        permissions = new MockPoolPermissionManager();
        maple = new MockSyrupRouter(address(usdc), address(syrup), address(permissions), vm.addr(SIGNER_KEY));
        syrup.configureMock(address(maple), address(permissions));
        permissions.setPermissionAdmin(vm.addr(SIGNER_KEY), true);
        permissions.setPermissionAdmin(address(maple), true);
        permissions.setPoolBitmap(address(maple), DEPOSIT, 16);
        permissions.setLenderBitmap(address(maple), 16);
        IBaseQAMockAdapterAdmin admin = IBaseQAMockAdapterAdmin(adapter);
        v3Id = admin.setAaveV3Config(address(v3), address(aToken), 17, true, true);
        admin.setAaveV4Config(address(spoke), address(giver), 7, true, true);
        v4Id = keccak256(
            abi.encode(
                block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0)
            )
        );
        mapleId = admin.setMapleConfig(address(maple), DATA, true, true);
        metro.setMinter(address(this), true);
        metro.setMinter(address(core), true);
        for (uint256 i; i < 3; ++i) {
            address user = makeAddr(string.concat("qa-user-", vm.toString(i)));
            users.push(user);
            metro.mint(user, (i + 1) * 10 ether);
            vm.startPrank(user);
            metro.approve(address(core), type(uint256).max);
            core.stake((i + 1) * 10 ether);
            spoke.setUserPositionManager(address(giver), true);
            vm.stopPrank();
        }
        // Weight ratio 1:2:3 produces actual pending rewards of 12/24/36 TestUSDC.
        usdc.mint(address(this), 72e6);
        usdc.approve(address(distributor), 72e6);
        distributor.distribute(72e6);
    }

    function test_V3_ManualCustodyMintSupplyAndNoUserUSDCApproval() public {
        vm.recordLogs();
        _manual(v3Id, 10e6, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 r = _find(
            logs, address(v3), keccak256("ReserveDataUpdated(address,uint256,uint256,uint256,uint256,uint256)"), 0
        );
        assertEq(logs[r].data, abi.encode(uint256(0), uint256(0), uint256(0), INDEX, uint256(1e27)));
        uint256 transfer = _find(logs, address(usdc), TRANSFER_TOPIC, r + 1);
        _transferLog(logs[transfer], adapter, address(aToken), 12e6);
        uint256 mint = _find(logs, address(aToken), MINT_TOPIC, transfer + 1);
        assertEq(logs[mint].topics.length, 3);
        assertEq(logs[mint].topics[1], _topic(adapter));
        assertEq(logs[mint].topics[2], _topic(users[0]));
        assertEq(logs[mint].data, abi.encode(uint256(12e6), uint256(0), INDEX));
        uint256 supply = _find(logs, address(v3), V3_SUPPLY_TOPIC, mint + 1);
        assertEq(logs[supply].topics.length, 4);
        assertEq(logs[supply].topics[1], _topic(address(usdc)));
        assertEq(logs[supply].topics[2], _topic(users[0]));
        assertEq(logs[supply].topics[3], bytes32(uint256(17)));
        assertEq(logs[supply].data, abi.encode(adapter, uint256(12e6)));
        assertEq(aToken.scaledBalanceOf(users[0]), 10e6);
        assertEq(usdc.balanceOf(address(aToken)), 12e6);
        assertEq(usdc.balanceOf(address(v3)), 0);
        assertEq(core.claimable(users[0]), 0);
        assertEq(usdc.allowance(adapter, address(v3)), 0);
        assertEq(usdc.allowance(users[0], adapter), 0);
    }

    function test_V3_BatchSuppliesOnceAndEmitsScaledTransfers() public {
        _optIn(v3Id);
        aToken.donateScaled(adapter, 7);
        vm.recordLogs();
        core.executeAutoStrategyBatch(v3Id, users, 60e6, new uint256[](0), 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(v3.supplyCallCount(), 1);
        assertEq(aToken.scaledBalanceOf(adapter), 7);
        bytes32 topic = keccak256("BalanceTransfer(address,address,uint256,uint256)");
        uint256 start;
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            uint256 j = _find(logs, address(aToken), topic, start);
            assertEq(logs[j].topics[1], _topic(adapter));
            address user = address(uint160(uint256(logs[j].topics[2])));
            (uint256 scaled, uint256 index_) = abi.decode(logs[j].data, (uint256, uint256));
            assertEq(index_, INDEX);
            assertEq(aToken.scaledBalanceOf(user), scaled);
            assertEq(core.claimable(users[i]), 0);
            total += scaled;
            start = j + 1;
        }
        assertEq(total, 60e6);
        assertEq(usdc.balanceOf(address(aToken)), 72e6);
        assertEq(usdc.allowance(adapter, address(v3)), 0);
    }

    function test_V3_InterestMintAndFullTransferCollateralDisable() public {
        _manual(v3Id, 1, "");
        v3.setIndex(15e26);
        vm.recordLogs();
        vm.prank(users[0]);
        aToken.transfer(users[1], 15e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 mint = _find(logs, address(aToken), MINT_TOPIC, 0);
        assertEq(logs[mint].data, abi.encode(uint256(3e6), uint256(3e6), uint256(15e26)));
        uint256 disable =
            _find(logs, address(v3), keccak256("ReserveUsedAsCollateralDisabled(address,address)"), mint + 1);
        assertEq(logs[disable].topics[2], _topic(users[0]));
        assertFalse(v3.usingAsCollateral(users[0]));
        assertFalse(v3.usingAsCollateral(users[1]));
        assertEq(aToken.getPreviousIndex(users[0]), 15e26);
        assertEq(aToken.balanceOf(users[1]), 15e6);
    }

    function test_V3_SecondMintIncludesPreviouslyAccruedInterest() public {
        _manual(v3Id, 1, "");
        v3.setIndex(15e26);
        usdc.mint(address(this), 15e6);
        usdc.approve(address(v3), 15e6);
        vm.recordLogs();
        v3.supply(address(usdc), 15e6, users[0], 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 mint = _find(logs, address(aToken), MINT_TOPIC, 0);
        assertEq(logs[mint].data, abi.encode(uint256(18e6), uint256(3e6), uint256(15e26)));
        assertEq(aToken.balanceOf(users[0]), 30e6);
    }

    function testFuzz_V3_TransferRoundUpAndBalanceConservation(uint96 raw) public {
        _manual(v3Id, 1, "");
        uint256 amount = bound(uint256(raw), 0, 12e6);
        vm.prank(users[0]);
        aToken.transfer(users[1], amount);
        uint256 scaled = Math.mulDiv(amount, 1e27, INDEX, Math.Rounding.Ceil);
        assertEq(aToken.scaledBalanceOf(users[1]), scaled);
        assertEq(aToken.scaledBalanceOf(users[0]) + aToken.scaledBalanceOf(users[1]), 10e6);
        assertEq(aToken.scaledTotalSupply(), 10e6);
    }

    function test_V3_FiniteAllowanceTransferFromAndSelfTransfer() public {
        _manual(v3Id, 1, "");
        vm.prank(users[0]);
        aToken.approve(users[2], 5e6);
        vm.prank(users[2]);
        aToken.transferFrom(users[0], users[1], 5e6);
        assertEq(aToken.allowance(users[0], users[2]), 0);
        uint256 before = aToken.scaledBalanceOf(users[0]);
        vm.prank(users[0]);
        aToken.transfer(users[0], 1e6);
        assertEq(aToken.scaledBalanceOf(users[0]), before);
    }

    function test_V3_PartialPullOrLowOutputRollsBackRewardsAndShares() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            v3.setBehavior(i == 0 ? 5_000 : 10_000, i == 1 ? 5_000 : 10_000, false);
            vm.expectRevert();
            vm.prank(users[0]);
            core.claimAndExecute(v3Id, 10e6, 0, "");
            _unchanged();
            assertEq(aToken.scaledBalanceOf(users[0]), 0);
            assertEq(v3.supplyCallCount(), 0);
            assertEq(usdc.balanceOf(address(aToken)), 0);
            assertTrue(vm.revertToState(snap));
        }
    }

    function test_V3_MintAndFinalizeArePoolOnlyAndIndexCannotDecrease() public {
        vm.expectRevert();
        aToken.mint(address(this), users[0], 1, INDEX);
        vm.expectRevert();
        v3.finalizeTransfer(address(usdc), users[0], users[1], 1, 1);
        vm.expectRevert();
        v3.setIndex(INDEX - 1);
    }

    function test_V4_ManualCallsGiverNotAdapterPositionManagerAndLogsBothLayers() public {
        vm.recordLogs();
        _manual(v4Id, 12e6, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 s = _find(logs, address(spoke), V4_SUPPLY_TOPIC, 0);
        assertEq(logs[s].topics.length, 4);
        assertEq(logs[s].topics[1], bytes32(uint256(7)));
        assertEq(logs[s].topics[2], _topic(address(giver)));
        assertEq(logs[s].topics[3], _topic(users[0]));
        assertEq(logs[s].data, abi.encode(uint256(12e6), uint256(12e6)));
        uint256 g = _find(
            logs, address(giver), keccak256("SupplyOnBehalfOf(address,address,address,uint256,uint256,uint256)"), s + 1
        );
        assertEq(logs[g].topics[1], _topic(address(spoke)));
        assertEq(logs[g].topics[2], _topic(adapter));
        assertEq(logs[g].topics[3], _topic(users[0]));
        assertEq(logs[g].data, abi.encode(uint256(7), uint256(12e6), uint256(12e6)));
        assertFalse(spoke.isPositionManagerActive(adapter));
        assertEq(spoke.getUserSuppliedShares(7, users[0]), 12e6);
        assertEq(usdc.balanceOf(address(giver)), 0);
        assertEq(usdc.balanceOf(address(spoke)), 12e6);
        assertEq(usdc.allowance(adapter, address(giver)), 0);
        assertEq(usdc.allowance(address(giver), address(spoke)), 0);
    }

    function test_V4_BatchSuppliesForEachUserAndConservesShares() public {
        _optIn(v4Id);
        core.executeAutoStrategyBatch(v4Id, users, 72e6, _v4Minima(), 0, "");
        assertEq(spoke.supplyCallCount(), 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(spoke.getUserSuppliedShares(7, users[i]), (i + 1) * 12e6);
            assertEq(core.claimable(users[i]), 0);
        }
        assertEq(usdc.balanceOf(address(giver)), 0);
    }

    function test_V4_RegistrationActivationApprovalEventsAndRevocation() public {
        vm.recordLogs();
        giver.registerSpoke(address(spoke), false);
        spoke.updatePositionManager(address(giver), false);
        vm.prank(users[0]);
        spoke.setUserPositionManager(address(giver), false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], keccak256("RegisterSpoke(address,bool)"));
        assertEq(logs[0].topics[1], _topic(address(spoke)));
        assertEq(logs[1].topics[0], keccak256("UpdatePositionManager(address,bool)"));
        assertEq(logs[1].topics[1], _topic(address(giver)));
        assertEq(logs[2].topics[0], keccak256("SetUserPositionManager(address,address,bool)"));
        assertEq(logs[2].topics[1], _topic(users[0]));
        assertEq(logs[2].topics[2], _topic(address(giver)));
        for (uint256 i; i < 3; ++i) {
            assertEq(logs[i].data, abi.encode(false));
        }
        assertFalse(spoke.isPositionManager(users[0], address(giver)));
        vm.expectRevert();
        vm.prank(users[0]);
        core.claimAndExecute(v4Id, 1, 0, "");
        _unchanged();
    }

    function test_V4_InactiveManagerIsNotAuthorizedEvenIfUserApprovalRemains() public {
        spoke.updatePositionManager(address(giver), false);
        assertFalse(spoke.isPositionManager(users[0], address(giver)));
        assertTrue(spoke.isPositionManager(users[0], users[0]));
        vm.expectRevert();
        vm.prank(users[0]);
        core.claimAndExecute(v4Id, 1, 0, "");
        _unchanged();
    }

    function test_V4_SecondUserFailureRollsBackWholeBatch() public {
        _optIn(v4Id);
        spoke.setBehavior(10_000, 10_000, 10_000, 10_000, 2);
        vm.expectRevert();
        core.executeAutoStrategyBatch(v4Id, users, 1, _v4Minima(), 0, "");
        _unchanged();
        for (uint256 i; i < 3; ++i) {
            assertEq(spoke.getUserSuppliedShares(7, users[i]), 0);
        }
        assertEq(spoke.supplyCallCount(), 0);
        assertEq(usdc.balanceOf(address(spoke)), 0);
        assertEq(usdc.allowance(address(giver), address(spoke)), 0);
    }

    function test_V4_FourAccountingFaultsAreRejected() public {
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            spoke.setBehavior(
                i == 0 ? 0 : 10_000, i == 1 ? 5_000 : 10_000, i == 2 ? 5_000 : 10_000, i == 3 ? 5_000 : 10_000, 0
            );
            vm.expectRevert();
            vm.prank(users[0]);
            core.claimAndExecute(v4Id, 1, 0, "");
            _unchanged();
            assertEq(spoke.getUserSuppliedShares(7, users[0]), 0);
            assertTrue(vm.revertToState(snap));
        }
    }

    function test_Maple_AuthorizationPoolDepositRouterReturnAndEventOrder() public {
        bytes memory signature = _authorization(adapter, 0, 16, block.timestamp + 1 hours, SIGNER_KEY);
        vm.recordLogs();
        _manual(mapleId, 12e6, signature);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 p = _find(logs, address(permissions), keccak256("LenderBitmapsSet(address[],uint256[])"), 0);
        assertEq(logs[p].topics.length, 1);
        (address[] memory lenders, uint256[] memory bitmaps) = abi.decode(logs[p].data, (address[], uint256[]));
        assertEq(lenders.length, 1);
        assertEq(lenders[0], adapter);
        assertEq(bitmaps[0], 16);
        uint256 d = _find(logs, address(syrup), POOL_DEPOSIT_TOPIC, p + 1);
        assertEq(logs[d].topics[1], _topic(address(maple)));
        assertEq(logs[d].topics[2], _topic(address(maple)));
        assertEq(logs[d].data, abi.encode(uint256(12e6), uint256(12e6)));
        uint256 custody = _find(logs, address(usdc), TRANSFER_TOPIC, d + 1);
        _transferLog(logs[custody], address(maple), address(syrup), 12e6);
        uint256 shares = _find(logs, address(syrup), TRANSFER_TOPIC, custody + 1);
        _transferLog(logs[shares], address(maple), adapter, 12e6);
        uint256 r = _find(logs, address(maple), ROUTER_DEPOSIT_TOPIC, shares + 1);
        assertEq(logs[r].topics[1], _topic(adapter));
        assertEq(logs[r].data, abi.encode(uint256(12e6), DATA));
        uint256 userTransfer = _find(logs, address(syrup), TRANSFER_TOPIC, r + 1);
        _transferLog(logs[userTransfer], adapter, users[0], 12e6);
        assertEq(maple.nonces(adapter), 1);
        assertEq(usdc.balanceOf(address(syrup)), 12e6);
        assertEq(usdc.balanceOf(address(maple)), 0);
        assertEq(syrup.balanceOf(users[0]), 12e6);
        assertEq(syrup.balanceOf(adapter), 0);
        assertEq(usdc.allowance(adapter, address(maple)), 0);
        assertEq(usdc.allowance(address(maple), address(syrup)), type(uint256).max);
    }

    function test_Maple_AlreadyAuthorizedUsesDepositWithNoSignature() public {
        permissions.setLenderBitmap(adapter, 16);
        _manual(mapleId, 12e6, "");
        assertEq(maple.depositCallCount(), 1);
        assertEq(maple.authorizeCallCount(), 0);
        assertEq(maple.nonces(adapter), 0);
    }

    function test_Maple_BatchDepositsOnceAndLeavesDonatedSharesAlone() public {
        _optIn(mapleId);
        syrup.mint(adapter, 7);
        core.executeAutoStrategyBatch(
            mapleId,
            users,
            72e6,
            new uint256[](0),
            0,
            _authorization(adapter, 0, 16, block.timestamp + 1 hours, SIGNER_KEY)
        );
        for (uint256 i; i < 3; ++i) {
            assertEq(syrup.balanceOf(users[i]), (i + 1) * 12e6);
        }
        assertEq(maple.authorizeCallCount(), 1);
        assertEq(syrup.balanceOf(adapter), 7);
        assertEq(syrup.balanceOf(address(maple)), 0);
        assertEq(usdc.balanceOf(address(syrup)), 72e6);
    }

    function test_Maple_ZeroAndCustomDepositDataAreBothAccepted() public {
        permissions.setLenderBitmap(adapter, 16);
        mapleId = IBaseQAMockAdapterAdmin(adapter).setMapleConfig(address(maple), bytes32(0), true, true);
        _manual(mapleId, 1, "");
        assertEq(maple.lastDepositData(), bytes32(0));
        mapleId = IBaseQAMockAdapterAdmin(adapter).setMapleConfig(address(maple), DATA, true, true);
        vm.prank(users[1]);
        core.claimAndExecute(mapleId, 1, 0, "");
        assertEq(maple.lastDepositData(), DATA);
    }

    function test_Maple_InvalidSignatureWrongLenderNonceBitmapAndExpiryRollback() public {
        for (uint256 i; i < 5; ++i) {
            uint256 snap = vm.snapshotState();
            bytes memory sig = _authorization(
                i == 1 ? users[0] : adapter,
                i == 2 ? 1 : 0,
                i == 3 ? 8 : 16,
                i == 4 ? block.timestamp - 1 : block.timestamp + 1 hours,
                i == 0 ? SIGNER_KEY + 1 : SIGNER_KEY
            );
            vm.expectRevert();
            vm.prank(users[0]);
            core.claimAndExecute(mapleId, 1, 0, sig);
            _unchanged();
            assertEq(maple.nonces(adapter), 0);
            assertEq(permissions.lenderBitmaps(adapter), 0);
            assertEq(syrup.totalSupply(), 0);
            assertTrue(vm.revertToState(snap));
        }
    }

    function test_Maple_RevokedSignerAndRouterPermissionsAreEnforced() public {
        bytes memory sig = _authorization(adapter, 0, 16, block.timestamp + 1 hours, SIGNER_KEY);
        permissions.setPermissionAdmin(vm.addr(SIGNER_KEY), false);
        vm.expectRevert();
        vm.prank(users[0]);
        core.claimAndExecute(mapleId, 1, 0, sig);
        permissions.setPermissionAdmin(vm.addr(SIGNER_KEY), true);
        permissions.setPermissionAdmin(address(maple), false);
        vm.expectRevert();
        vm.prank(users[0]);
        core.claimAndExecute(mapleId, 1, 0, sig);
        _unchanged();
        assertEq(maple.nonces(adapter), 0);
    }

    function test_Maple_SignatureCannotReplayAndExactDeadlineIsValidAtRouter() public {
        usdc.mint(address(this), 2e6);
        usdc.approve(address(maple), 2e6);
        uint256 deadline = block.timestamp;
        bytes memory encoded = _authorization(address(this), 0, 16, deadline, SIGNER_KEY);
        (,, uint8 v, bytes32 r, bytes32 s) = abi.decode(encoded, (uint256, uint256, uint8, bytes32, bytes32));
        maple.authorizeAndDeposit(16, deadline, v, r, s, 1e6, DATA);
        vm.expectRevert();
        maple.authorizeAndDeposit(16, deadline, v, r, s, 1e6, DATA);
        assertEq(maple.nonces(address(this)), 1);
        assertEq(syrup.balanceOf(address(this)), 1e6);
    }

    function test_Maple_FaultsRollbackNewAuthorizationAndEveryBalance() public {
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            maple.setBehavior(i == 0 ? 5_000 : 10_000, i == 1 ? 5_000 : 10_000, i == 2, i == 3, 1);
            bytes memory sig = _authorization(adapter, 0, 16, block.timestamp + 1 hours, SIGNER_KEY);
            vm.expectRevert();
            vm.prank(users[0]);
            core.claimAndExecute(mapleId, 12e6, 0, sig);
            _unchanged();
            assertEq(maple.nonces(adapter), 0);
            assertEq(permissions.lenderBitmaps(adapter), 0);
            assertEq(syrup.totalSupply(), 0);
            assertEq(usdc.balanceOf(address(syrup)), 0);
            assertEq(maple.authorizeCallCount(), 0);
            assertTrue(vm.revertToState(snap));
        }
    }

    function test_Maple_PoolDepositAndTransferActuallyCheckBitmaps() public {
        usdc.mint(address(this), 1e6);
        usdc.approve(address(syrup), 1e6);
        vm.expectRevert();
        syrup.deposit(1e6, users[0]);
        permissions.setLenderBitmap(users[0], 16);
        syrup.deposit(1e6, users[0]);
        permissions.setPoolBitmap(address(maple), bytes32("P:transfer"), 16);
        vm.expectRevert();
        vm.prank(users[0]);
        syrup.transfer(users[1], 1);
        permissions.setLenderBitmap(users[1], 16);
        vm.prank(users[0]);
        syrup.transfer(users[1], 1);
        assertEq(syrup.balanceOf(users[1]), 1);
    }

    function test_Maple_ERC20AllowanceAndProtocolApprovalEvent() public {
        permissions.setLenderBitmap(adapter, 16);
        _manual(mapleId, 1, "");
        vm.prank(users[0]);
        syrup.approve(users[2], 5e6);
        vm.recordLogs();
        vm.prank(users[2]);
        syrup.transferFrom(users[0], users[1], 5e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], keccak256("Approval(address,address,uint256)"));
        assertEq(logs[0].data, abi.encode(uint256(0)));
        _transferLog(logs[1], users[0], users[1], 5e6);
        assertEq(syrup.allowance(users[0], users[2]), 0);
        assertEq(syrup.totalSupply(), 12e6);
    }

    function test_Maple_PermissionConfigurationEventsAndBatchLengths() public {
        vm.recordLogs();
        permissions.setPermissionAdmin(users[0], true);
        permissions.setPoolBitmap(address(maple), bytes32("P:transfer"), 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], keccak256("PermissionAdminSet(address,bool)"));
        assertEq(logs[0].topics[1], _topic(users[0]));
        assertEq(logs[0].data, abi.encode(true));
        assertEq(logs[1].topics[0], keccak256("PoolBitmapsSet(address,bytes32[],uint256[])"));
        (bytes32[] memory ids, uint256[] memory bits) = abi.decode(logs[1].data, (bytes32[], uint256[]));
        assertEq(ids[0], bytes32("P:transfer"));
        assertEq(bits[0], 4);
        vm.expectRevert();
        vm.prank(users[0]);
        permissions.setLenderBitmaps(new address[](1), new uint256[](0));
        vm.expectRevert();
        permissions.setLenderBitmaps(users, new uint256[](3));
    }

    function test_AllPaths_ProtocolCallbackCannotReenterCore() public {
        bytes memory callData = abi.encodeWithSelector(core.claimRewards.selector);
        v3.setReentry(address(core), callData);
        _manual(v3Id, 1, "");
        assertTrue(v3.reentryAttempted());
        assertFalse(v3.reentrySucceeded());
        spoke.setReentry(address(core), callData);
        vm.prank(users[1]);
        core.claimAndExecute(v4Id, 1, 0, "");
        assertTrue(spoke.reentryAttempted());
        assertFalse(spoke.reentrySucceeded());
        permissions.setLenderBitmap(adapter, 16);
        maple.setReentry(address(core), callData);
        vm.prank(users[2]);
        core.claimAndExecute(mapleId, 1, 0, "");
        assertTrue(maple.reentryAttempted());
        assertFalse(maple.reentrySucceeded());
    }

    function test_Tokens_DecimalsMintApprovalAndTransfer() public {
        uint8[3] memory decimals_ = [uint8(6), uint8(8), uint8(18)];
        for (uint256 i; i < 3; ++i) {
            ERC20Mintable token = new ERC20Mintable("QA", "QA", decimals_[i]);
            uint256 amount = 10 ** decimals_[i];
            token.mint(users[0], amount);
            vm.prank(users[0]);
            token.approve(users[1], amount);
            vm.prank(users[1]);
            token.transferFrom(users[0], users[2], amount);
            assertEq(token.decimals(), decimals_[i]);
            assertEq(token.balanceOf(users[2]), amount);
            assertEq(token.allowance(users[0], users[1]), 0);
        }
    }

    function _manual(bytes32 id, uint256 minimum, bytes memory data) private {
        vm.prank(users[0]);
        (uint256 input,) = core.claimAndExecute(id, minimum, 0, data);
        assertEq(input, 12e6);
    }

    function _optIn(bytes32 id) private {
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            core.enableAutoStrategy(id);
        }
    }

    function test_QAAdminControlsCanBeHandedOver() public {
        address outsider = makeAddr("outsider");
        address nextOwner = makeAddr("next-owner");

        vm.startPrank(outsider);
        vm.expectRevert(); usdc.mint(outsider, 1);
        vm.expectRevert(); syrup.mint(outsider, 1);
        vm.expectRevert(); v3.setBehavior(10_000, 10_000, false);
        vm.expectRevert(); spoke.updatePositionManager(outsider, true);
        vm.expectRevert(); giver.registerSpoke(outsider, true);
        vm.expectRevert(); permissions.setPermissionAdmin(outsider, true);
        vm.expectRevert(); maple.setBehavior(10_000, 10_000, false, false, 0);
        vm.stopPrank();

        usdc.transferOwnership(nextOwner);
        syrup.transferOwnership(nextOwner);
        v3.transferOwnership(nextOwner);
        spoke.transferOwnership(nextOwner);
        giver.transferOwnership(nextOwner);
        permissions.transferOwnership(nextOwner);
        maple.transferOwnership(nextOwner);
        vm.startPrank(nextOwner);
        usdc.mint(nextOwner, 1);
        syrup.mint(nextOwner, 1);
        v3.setBehavior(10_000, 10_000, false);
        spoke.updatePositionManager(outsider, true);
        giver.registerSpoke(outsider, true);
        permissions.setPermissionAdmin(outsider, true);
        maple.setBehavior(10_000, 10_000, false, false, 0);
        aToken.donateScaled(nextOwner, 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(nextOwner), 1);
        assertEq(syrup.balanceOf(nextOwner), 1);
        assertTrue(spoke.activeManagers(outsider));
        assertTrue(giver.isSpokeRegistered(outsider));
    }

    function _v4Minima() private pure returns (uint256[] memory minima) {
        minima = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            minima[i] = (i + 1) * 12e6;
        }
    }

    function _authorization(address lender, uint256 nonce, uint256 bitmap, uint256 deadline, uint256 key)
        private
        view
        returns (bytes memory)
    {
        // Sign the official SyrupRouter digest for the Adapter Proxy, not the end user.
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", block.chainid, address(maple), lender, nonce, bitmap, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encode(bitmap, deadline, v, r, s);
    }

    function _unchanged() private view {
        assertEq(usdc.balanceOf(address(core)), 72e6);
        assertEq(usdc.balanceOf(adapter), 0);
        assertEq(usdc.allowance(adapter, address(v3)), 0);
        assertEq(usdc.allowance(adapter, address(giver)), 0);
        assertEq(usdc.allowance(adapter, address(maple)), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(core.claimable(users[i]), (i + 1) * 12e6);
        }
    }

    function _find(Vm.Log[] memory logs, address emitter, bytes32 topic, uint256 start) private pure returns (uint256) {
        for (uint256 i = start; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) return i;
        }
        revert("expected protocol log missing or out of order");
    }

    function _transferLog(Vm.Log memory log, address from, address to, uint256 amount) private pure {
        assertEq(log.topics.length, 3);
        assertEq(log.topics[0], TRANSFER_TOPIC);
        assertEq(log.topics[1], _topic(from));
        assertEq(log.topics[2], _topic(to));
        assertEq(log.data, abi.encode(amount));
    }

    function _topic(address value) private pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }
}
