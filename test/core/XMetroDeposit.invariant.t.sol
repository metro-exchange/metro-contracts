// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MetroToken} from "../../src/metro.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockSyrupUSDC} from "../mocks/MockSyrupUSDC.sol";
import {MockAaveV4Giver} from "../mocks/MockAaveV4Giver.sol";
import {
    MockAaveV3Pool,
    MockAaveV4Spoke,
    MockPoolPermissionManager,
    MockSyrupRouter
} from "../mocks/MockDepositProtocols.sol";

interface IDepositInvariantAdmin {
    function setAaveV3Config(address pool, address aToken, uint16 referral, bool enabled, bool autoEnabled)
        external
        returns (bytes32);
    function setAaveV4Config(address spoke, address giver, uint256 reserveId, bool enabled, bool autoEnabled) external;
    function setMapleConfig(address router, bytes32 data, bool enabled, bool autoEnabled) external returns (bytes32);
}

/// @dev Stateful tests use real Core accounting and the release Adapter artifact. Mock protocols
///      hold the actual USDC and receipt balances; no fork or public-chain state is involved.
contract DepositInvariantHandler is Test {
    xMETRO public immutable core;
    ERC20Mintable public immutable usdc;
    bytes32 public immutable v3Id;
    bytes32 public immutable v4Id;
    bytes32 public immutable mapleId;
    address[3] internal actors;

    uint256 public totalDeposited;
    uint256 public totalExecuted;
    uint256 public v3Executed;
    uint256 public v4Executed;
    uint256 public mapleExecuted;
    uint256 public unexpectedFailures;
    uint256 public v3Successes;
    uint256 public v4Successes;
    uint256 public mapleSuccesses;
    mapping(address => uint256) public expectedV3;
    mapping(address => uint256) public expectedV4;
    mapping(address => uint256) public expectedMaple;

    constructor(
        xMETRO core_,
        ERC20Mintable usdc_,
        bytes32 v3Id_,
        bytes32 v4Id_,
        bytes32 mapleId_,
        address[3] memory actors_
    ) {
        core = core_;
        usdc = usdc_;
        v3Id = v3Id_;
        v4Id = v4Id_;
        mapleId = mapleId_;
        actors = actors_;
        usdc_.approve(address(core_), type(uint256).max);
    }

    function xMETRO() external view returns (address) {
        return address(core);
    }

    function rewardToken() external view returns (address) {
        return address(usdc);
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function depositRewards(uint96 seed) external {
        // With fixed 1:2:3 shares, a multiple of six gives an exact independent reward oracle.
        uint256 amount = bound(uint256(seed), 1, 1_000_000e6) * 6;
        usdc.mint(address(this), amount);
        core.depositRewards(amount);
        totalDeposited += amount;
    }

    function execute(uint256 actorSeed, uint8 kindSeed) external {
        address account = actors[actorSeed % actors.length];
        uint256 pending = core.claimable(account);
        if (pending == 0) return;
        uint256 kind = uint256(kindSeed) % 3;
        bytes32 id = kind == 0 ? v3Id : kind == 1 ? v4Id : mapleId;
        vm.prank(account);
        try core.claimAndExecute(id, 1, 0, "") returns (uint256 used, uint256 shares) {
            if (used != pending || shares != pending) ++unexpectedFailures;
            totalExecuted += used;
            if (kind == 0) {
                v3Executed += shares;
                expectedV3[account] += shares;
                ++v3Successes;
            } else if (kind == 1) {
                v4Executed += shares;
                expectedV4[account] += shares;
                ++v4Successes;
            } else {
                mapleExecuted += shares;
                expectedMaple[account] += shares;
                ++mapleSuccesses;
            }
        } catch {
            ++unexpectedFailures;
        }
    }
}

contract XMetroDepositInvariantTest is StdInvariant, Test {
    MetroToken internal metro;
    ERC20Mintable internal usdc;
    xMETRO internal core;
    address internal adapter;
    MockAaveV3Pool internal v3;
    MockAaveV4Spoke internal v4;
    MockAaveV4Giver internal giver;
    MockSyrupUSDC internal syrup;
    MockPoolPermissionManager internal permissions;
    MockSyrupRouter internal maple;
    DepositInvariantHandler internal handler;
    address[3] internal actors;

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        bytes memory coreInit = abi.encodePacked(
            vm.getCode("xMETRO.sol:xMETRO"),
            abi.encode(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000)
        );
        core = xMETRO(_create(coreInit));
        bytes memory adapterInit = vm.parseJsonBytes(
            vm.readFile("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"), ".bytecode.object"
        );
        address implementation = _create(adapterInit);
        adapter = address(
            new ERC1967Proxy(
                implementation,
                abi.encodeWithSignature(
                    "initialize(address,address,address)", address(core), address(usdc), address(metro)
                )
            )
        );
        core.setDeFiAdapter(adapter);

        v3 = new MockAaveV3Pool(address(usdc), 1e27);
        v4 = new MockAaveV4Spoke(address(usdc), 7);
        giver = new MockAaveV4Giver(address(v4));
        v4.updatePositionManager(address(giver), true);
        syrup = new MockSyrupUSDC(address(usdc));
        permissions = new MockPoolPermissionManager();
        maple = new MockSyrupRouter(address(usdc), address(syrup), address(permissions), vm.addr(0xA110CE));
        syrup.configureMock(address(maple), address(permissions));
        permissions.setPermissionAdmin(vm.addr(0xA110CE), true);
        permissions.setPermissionAdmin(address(maple), true);
        permissions.setPoolBitmap(address(maple), bytes32("P:deposit"), 16);
        permissions.setLenderBitmap(address(maple), 16);
        permissions.setLenderBitmap(adapter, 16);

        IDepositInvariantAdmin admin = IDepositInvariantAdmin(adapter);
        bytes32 v3Id = admin.setAaveV3Config(address(v3), address(v3.aUsdc()), 17, true, true);
        admin.setAaveV4Config(address(v4), address(giver), 7, true, true);
        bytes32 v4Id = keccak256(
            abi.encode(
                block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0)
            )
        );
        bytes32 mapleId = admin.setMapleConfig(address(maple), bytes32("0:xMETRO"), true, true);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("deposit-invariant-", vm.toString(i)));
            uint256 stakeAmount = (i + 1) * 10 ether;
            metro.mint(actors[i], stakeAmount);
            vm.startPrank(actors[i]);
            metro.approve(address(core), stakeAmount);
            core.stake(stakeAmount);
            v4.setUserPositionManager(address(giver), true);
            vm.stopPrank();
        }
        handler = new DepositInvariantHandler(core, usdc, v3Id, v4Id, mapleId, actors);
        usdc.transferOwnership(address(handler));
        core.setRewardDistributor(address(handler));
        core.setAutoCompoundOperator(address(this), true);
        handler.depositRewards(100e6);
        handler.execute(0, 0);
        handler.execute(1, 1);
        handler.execute(2, 2);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.depositRewards.selector;
        selectors[1] = handler.execute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function testFuzz_V3BatchAcrossNormalizedIncomeIndices(uint8 indexSeed) public {
        uint256[5] memory factors = [uint256(2), 4, 5, 10, 20];
        uint256 factor = factors[uint256(indexSeed) % factors.length];
        v3.setIndex(factor * 1e27);
        bytes32 id = handler.v3Id();
        address[] memory users = _optInAll(id);
        v3.aUsdc().donateScaled(adapter, 7);
        handler.depositRewards(100e6);

        (uint256 used, uint256 received) = core.executeAutoStrategyBatch(id, users, 1, new uint256[](0), 0, "");
        assertEq(used, 600e6);
        assertEq(received, 600e6);
        assertEq(v3.supplyCallCount(), 2);
        assertEq(v3.aUsdc().scaledBalanceOf(adapter), 7);
        for (uint256 i; i < actors.length; ++i) {
            uint256 oldShares = i == 0 ? 100e6 : 0;
            assertEq(v3.aUsdc().scaledBalanceOf(actors[i]), oldShares + (i + 1) * 100e6 / factor);
            assertEq(core.claimable(actors[i]), 0);
        }
        assertEq(usdc.balanceOf(address(v3.aUsdc())), 700e6);
        assertEq(usdc.allowance(adapter, address(v3)), 0);
    }

    function testFuzz_V4BatchMinimaAndRevokedManagerRollback(uint96 minimaSeed, uint8 revokedSeed) public {
        bytes32 id = handler.v4Id();
        address[] memory users = _optInAll(id);
        handler.depositRewards(100e6);
        uint256[] memory minima = new uint256[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            minima[i] = bound(uint256(keccak256(abi.encode(minimaSeed, i))), 1, (i + 1) * 100e6);
        }
        uint256 revoked = uint256(revokedSeed) % (actors.length + 1);
        if (revoked < actors.length) {
            vm.prank(actors[revoked]);
            v4.setUserPositionManager(address(giver), false);
            vm.expectRevert();
            core.executeAutoStrategyBatch(id, users, 1, minima, 0, "");
            assertEq(usdc.balanceOf(address(core)), 600e6);
            assertEq(v4.supplyCallCount(), 1);
            for (uint256 i; i < actors.length; ++i) {
                assertEq(v4.getUserSuppliedShares(7, actors[i]), i == 1 ? 200e6 : 0);
                assertEq(core.claimable(actors[i]), (i + 1) * 100e6);
            }
        } else {
            (uint256 used, uint256 received) = core.executeAutoStrategyBatch(id, users, 1, minima, 0, "");
            assertEq(used, 600e6);
            assertEq(received, 600e6);
            assertEq(v4.supplyCallCount(), 4);
            for (uint256 i; i < actors.length; ++i) {
                assertEq(v4.getUserSuppliedShares(7, actors[i]), (i == 1 ? 200e6 : 0) + (i + 1) * 100e6);
                assertEq(core.claimable(actors[i]), 0);
            }
        }
        assertEq(usdc.balanceOf(address(giver)), 0);
        assertEq(usdc.allowance(adapter, address(giver)), 0);
    }

    function testFuzz_MapleBatchVariableShareRateAndAuthorizationNonce(uint16 rateSeed, bool authorized) public {
        uint256 rate = bound(uint256(rateSeed), 200, 10_000);
        maple.setBehavior(10_000, rate, false, false, 0);
        bytes memory authorization;
        if (!authorized) {
            permissions.setLenderBitmap(adapter, 0);
            uint256 deadline = block.timestamp + 1 hours;
            bytes32 digest = keccak256(
                abi.encodePacked("\x19\x01", block.chainid, address(maple), adapter, uint256(0), uint256(16), deadline)
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xA110CE, digest);
            authorization = abi.encode(uint256(16), deadline, v, r, s);
        }
        bytes32 id = handler.mapleId();
        address[] memory users = _optInAll(id);
        syrup.mint(adapter, 7);
        handler.depositRewards(100e6);

        (uint256 used, uint256 shares) = core.executeAutoStrategyBatch(id, users, 1, new uint256[](0), 0, authorization);
        assertEq(used, 600e6);
        assertEq(shares, Math.mulDiv(600e6, rate, 10_000));
        assertEq(maple.depositCallCount() + maple.authorizeCallCount(), 2);
        assertEq(maple.nonces(adapter), authorized ? 0 : 1);
        uint256 first = Math.mulDiv(shares, 100e6, 600e6);
        uint256 second = Math.mulDiv(shares, 200e6, 600e6);
        assertEq(syrup.balanceOf(actors[0]), first);
        assertEq(syrup.balanceOf(actors[1]), second);
        assertEq(syrup.balanceOf(actors[2]), 300e6 + shares - first - second);
        assertEq(syrup.balanceOf(adapter), 7);
        assertEq(usdc.balanceOf(address(syrup)), 900e6);
        assertEq(usdc.allowance(adapter, address(maple)), 0);
    }

    function invariant_ThreeDepositPathsConserveRewardAndReceiptBalances() public view {
        assertEq(handler.unexpectedFailures(), 0);
        assertGt(handler.v3Successes(), 0);
        assertGt(handler.v4Successes(), 0);
        assertGt(handler.mapleSuccesses(), 0);
        assertEq(handler.totalDeposited(), handler.totalExecuted() + usdc.balanceOf(address(core)));
        assertEq(handler.totalExecuted(), handler.v3Executed() + handler.v4Executed() + handler.mapleExecuted());
        uint256 v3Total;
        uint256 v4Total;
        uint256 mapleTotal;
        for (uint256 i; i < actors.length; ++i) {
            address account = actors[i];
            assertEq(v3.aUsdc().scaledBalanceOf(account), handler.expectedV3(account));
            assertEq(v4.getUserSuppliedShares(7, account), handler.expectedV4(account));
            assertEq(syrup.balanceOf(account), handler.expectedMaple(account));
            v3Total += v3.aUsdc().scaledBalanceOf(account);
            v4Total += v4.getUserSuppliedShares(7, account);
            mapleTotal += syrup.balanceOf(account);
        }
        assertEq(v3Total, handler.v3Executed());
        assertEq(v4Total, handler.v4Executed());
        assertEq(mapleTotal, handler.mapleExecuted());
        assertEq(usdc.balanceOf(address(v3.aUsdc())), v3Total);
        assertEq(usdc.balanceOf(address(v4)), v4Total);
        assertEq(usdc.balanceOf(address(syrup)), mapleTotal);
        assertEq(usdc.balanceOf(adapter), 0);
        assertEq(usdc.balanceOf(address(giver)), 0);
        assertEq(usdc.allowance(adapter, address(v3)), 0);
        assertEq(usdc.allowance(adapter, address(giver)), 0);
        assertEq(usdc.allowance(adapter, address(maple)), 0);
        assertEq(metro.balanceOf(address(core)), core.totalShares());
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") { deployed := create(0, add(initCode, 32), mload(initCode)) }
        require(deployed != address(0));
    }

    function _optInAll(bytes32 id) private returns (address[] memory users) {
        users = new address[](actors.length);
        for (uint256 i; i < actors.length; ++i) {
            users[i] = actors[i];
            vm.prank(users[i]);
            core.enableAutoStrategy(id);
        }
    }
}
