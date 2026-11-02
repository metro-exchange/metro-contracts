// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {MockAaveV4Giver} from "../mocks/MockAaveV4Giver.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MetroToken} from "../../src/metro.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockSyrupUSDC} from "../mocks/MockSyrupUSDC.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {MockOneInchExecutor, MockOneInchRouter} from "../mocks/MockOneInchRouter.sol";
import {
    MockAaveV3Pool,
    MockAaveV4Spoke,
    MockPoolPermissionManager,
    MockSyrupRouter
} from "../mocks/MockDepositProtocols.sol";

interface ISystemAdapterAdmin {
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

contract SystemCode {}

contract SystemV2Router {
    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata path, address receiver, uint256)
        external
        returns (uint256[] memory amounts)
    {
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn));
        require(IERC20(path[path.length - 1]).transfer(receiver, amountIn));
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }
}

contract XMetroSystemIntegrationTest is Test {
    bytes32 internal constant P_DEPOSIT = bytes32("P:deposit");
    uint256 internal constant USER_STAKE = 100 ether;

    ERC20Mintable internal usdc;
    ERC20Mintable internal output;
    MockSyrupUSDC internal syrupUsdc;
    MetroToken internal metro;
    xMETRO internal core;
    IXMetroDeFiAdapter internal adapter;
    RewardDistributor internal distributor;
    MockCommissionVault internal vault;
    SystemV2Router internal routerV2;
    MockOneInchRouter internal oneInch;
    MockOneInchExecutor internal oneInchExecutor;
    MockAaveV3Pool internal aaveV3;
    MockAaveV4Spoke internal aaveV4;
    MockAaveV4Giver internal giver;
    MockPoolPermissionManager internal permissions;
    MockSyrupRouter internal mapleRouter;
    bytes32 internal swapStrategy;
    bytes32 internal aaveV3Strategy;
    bytes32 internal aaveV4Strategy;
    bytes32 internal mapleStrategy;
    address[] internal users;

    function xMETRO() external view returns (address) {
        return address(core);
    }

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        output = new ERC20Mintable("Output", "OUT", 6);
        syrupUsdc = new MockSyrupUSDC(address(usdc));
        metro = new MetroToken("METRO", "METRO", address(this));
        core = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);

        address implementation = _create(_adapterInitCode());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address)", address(core), address(usdc), address(metro)
        );
        address proxy = address(new ERC1967Proxy(implementation, initData));
        adapter = IXMetroDeFiAdapter(proxy);
        core.setDeFiAdapter(proxy);

        routerV2 = new SystemV2Router();
        oneInch = new MockOneInchRouter();
        oneInchExecutor = new MockOneInchExecutor();
        metro.setMinter(address(this), true);
        metro.mint(address(routerV2), 1_000_000 ether);
        output.mint(address(routerV2), 1_000_000e6);
        metro.mint(address(oneInch), 1_000_000 ether);
        output.mint(address(oneInch), 1_000_000e6);
        aaveV3 = new MockAaveV3Pool(address(usdc), 12e26);
        aaveV4 = new MockAaveV4Spoke(address(usdc), 7);
        giver = new MockAaveV4Giver(address(aaveV4));
        aaveV4.updatePositionManager(address(giver), true);
        permissions = new MockPoolPermissionManager();
        mapleRouter =
            new MockSyrupRouter(address(usdc), address(syrupUsdc), address(permissions), makeAddr("maple-authorizer"));
        syrupUsdc.configureMock(address(mapleRouter), address(permissions));
        permissions.setPermissionAdmin(makeAddr("maple-authorizer"), true);
        permissions.setPermissionAdmin(address(mapleRouter), true);
        permissions.setPoolBitmap(address(mapleRouter), P_DEPOSIT, 16);
        permissions.setLenderBitmap(address(mapleRouter), 16);
        permissions.setLenderBitmap(proxy, 16);

        ISystemAdapterAdmin admin = ISystemAdapterAdmin(proxy);
        admin.setRouters(address(routerV2), address(new SystemCode()), address(oneInch));
        admin.setSwapMetroConfig(true, true);
        swapStrategy = admin.setSwapTokenConfig(address(output), true, true);
        aaveV3Strategy = admin.setAaveV3Config(address(aaveV3), address(aaveV3.aUsdc()), 17, true, true);
        admin.setAaveV4Config(address(aaveV4), address(giver), 7, true, true);
        aaveV4Strategy = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        mapleStrategy = admin.setMapleConfig(address(mapleRouter), bytes32(0), true, true);

        distributor = new RewardDistributor(address(core), address(this));
        vault = new MockCommissionVault(address(usdc), 60e6, address(distributor));
        core.setRewardDistributor(address(distributor));
        core.setAutoCompoundOperator(address(this), true);
        metro.setMinter(address(core), true);

        distributor.setOperator(address(this), true);
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(1_000);

        for (uint256 i; i < 6; ++i) {
            address user = makeAddr(string.concat("system-user-", vm.toString(i)));
            users.push(user);
            metro.mint(user, USER_STAKE);
            vm.startPrank(user);
            metro.approve(address(core), USER_STAKE);
            core.stake(USER_STAKE);
            aaveV4.setUserPositionManager(address(giver), true);
            vm.stopPrank();
        }
        aaveV4.updatePositionManager(address(giver), true);
    }

    function test_CommissionNetRewardFeedsEveryAdapterPathAndPlainClaim() public {
        vm.prank(users[0]);
        core.enableAutocompound();
        vm.prank(users[1]);
        core.enableAutoStrategy(swapStrategy);
        vm.prank(users[2]);
        core.enableAutoStrategy(aaveV3Strategy);
        vm.prank(users[3]);
        core.enableAutoStrategy(aaveV4Strategy);
        vm.prank(users[4]);
        core.enableAutoStrategy(mapleStrategy);

        usdc.mint(address(this), 600e6);
        usdc.approve(address(distributor), 600e6);
        distributor.distribute(600e6);
        assertEq(usdc.balanceOf(address(vault)), 60e6);
        for (uint256 i; i < users.length; ++i) {
            assertEq(core.claimable(users[i]), 90e6);
        }

        address[] memory one = new address[](1);
        one[0] = users[0];
        uint256 sharesBefore = core.balanceOf(users[0]);
        core.autocompoundBatch(one, 90e6, block.timestamp + 1, _oneInchData(address(metro), 90e6));
        assertEq(core.balanceOf(users[0]) - sharesBefore, 90e6);

        one[0] = users[1];
        core.executeAutoStrategyBatch(
            swapStrategy, one, 90e6, new uint256[](0), block.timestamp + 1, _oneInchData(address(output), 90e6)
        );
        assertEq(output.balanceOf(users[1]), 90e6);

        one[0] = users[2];
        core.executeAutoStrategyBatch(aaveV3Strategy, one, 90e6, new uint256[](0), 0, bytes(""));
        assertEq(aaveV3.aUsdc().scaledBalanceOf(users[2]), 75e6);
        assertEq(aaveV3.lastReferralCode(), 17);

        one[0] = users[3];
        uint256[] memory minima = new uint256[](1);
        minima[0] = 90e6;
        core.executeAutoStrategyBatch(aaveV4Strategy, one, 90e6, minima, 0, bytes(""));
        assertEq(aaveV4.getUserSuppliedShares(7, users[3]), 90e6);

        one[0] = users[4];
        core.executeAutoStrategyBatch(mapleStrategy, one, 90e6, new uint256[](0), 0, bytes(""));
        assertEq(syrupUsdc.balanceOf(users[4]), 90e6);

        vm.prank(users[5]);
        assertEq(core.claimRewards(), 90e6);
        assertEq(usdc.balanceOf(users[5]), 90e6);

        for (uint256 i; i < users.length; ++i) {
            assertEq(core.claimable(users[i]), 0);
        }
        assertEq(usdc.balanceOf(address(core)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(metro.balanceOf(address(core)), core.totalSupply());
        assertEq(usdc.allowance(address(adapter), address(routerV2)), 0);
        assertEq(usdc.allowance(address(adapter), address(oneInch)), 0);
        assertEq(usdc.allowance(address(adapter), address(aaveV3)), 0);
        assertEq(usdc.allowance(address(adapter), address(aaveV4)), 0);
        assertEq(usdc.allowance(address(adapter), address(giver)), 0);
        assertEq(usdc.allowance(address(adapter), address(mapleRouter)), 0);
    }

    function test_PausedEmergencySettlesOnlyLedgerRewardsAndLeavesBackingUntouched() public {
        distributor.setMaxCommissionSplitBps(0);
        usdc.mint(address(this), 600e6);
        usdc.approve(address(distributor), 600e6);
        distributor.distribute(600e6);
        uint256 backingBefore = metro.balanceOf(address(core));
        uint256 supplyBefore = core.totalSupply();

        core.pause();
        assertEq(core.emergencyDistribute(users), 600e6);
        for (uint256 i; i < users.length; ++i) {
            assertEq(usdc.balanceOf(users[i]), 100e6);
        }
        assertEq(metro.balanceOf(address(core)), backingBefore);
        assertEq(core.totalSupply(), supplyBefore);
    }

    function test_ThorYThorAndContributorPendingUseTheSameRealAdapterPaths() public {
        core.setMigrationEscrow(address(this));
        core.creditThorFromMigration(users[2], 100 ether);
        core.creditYThorFromMigration(users[3], 100 ether);
        core.setContributor(users[4], true);
        metro.mint(users[4], 100 ether);
        vm.startPrank(users[4]);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, users[5]);
        vm.stopPrank();
        assertEq(core.rewardWeightOf(users[2]), 200 ether);
        assertEq(core.rewardWeightOf(users[3]), 300 ether);
        assertEq(core.rewardWeightOf(users[5]), 200 ether);

        vm.prank(users[2]);
        core.enableAutoStrategy(swapStrategy);
        vm.prank(users[3]);
        core.enableAutoStrategy(mapleStrategy);
        vm.prank(users[5]);
        core.enableAutocompound();
        distributor.setMaxCommissionSplitBps(0);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(distributor), 1_000e6);
        distributor.distribute(1_000e6);
        assertEq(core.claimable(users[0]), 100e6);
        assertEq(core.claimable(users[1]), 100e6);
        assertEq(core.claimable(users[2]), 200e6);
        assertEq(core.claimable(users[3]), 300e6);
        assertEq(core.claimable(users[4]), 100e6);
        assertEq(core.claimable(users[5]), 200e6);

        vm.prank(users[0]);
        core.claimAndExecute(aaveV3Strategy, 1, 0, "");
        vm.prank(users[1]);
        core.claimAndExecute(aaveV4Strategy, 1, 0, "");
        address[] memory one = new address[](1);
        one[0] = users[2];
        core.executeAutoStrategyBatch(
            swapStrategy, one, 200e6, new uint256[](0), block.timestamp + 1, _v2Data(address(output), 200e6)
        );
        one[0] = users[3];
        core.executeAutoStrategyBatch(mapleStrategy, one, 300e6, new uint256[](0), 0, "");
        vm.prank(users[4]);
        core.claimRewards();
        one[0] = users[5];
        uint256 sharesBefore = core.balanceOf(users[5]);
        core.autocompoundBatch(one, 200e6, block.timestamp + 1, _v2Data(address(metro), 200e6));
        assertEq(core.balanceOf(users[5]) - sharesBefore, 200e6);
        assertEq(output.balanceOf(users[2]), 200e6);
        assertEq(syrupUsdc.balanceOf(users[3]), 300e6);
        for (uint256 i; i < users.length; ++i) {
            assertEq(core.claimable(users[i]), 0);
        }
        assertEq(usdc.balanceOf(address(core)), 0);

        core.setYThorRewardWeightBps(15_000);
        assertEq(core.rewardWeightOf(users[3]), 250 ether);
        usdc.mint(address(this), 950e6);
        usdc.approve(address(distributor), 950e6);
        distributor.distribute(950e6);
        uint256 updatedYThorPending = core.claimable(users[3]);
        assertGt(updatedYThorPending, 0);
        assertLe(updatedYThorPending, 250e6);
        assertGt(core.claimable(users[2]), 0);
        assertGt(core.claimable(users[5]), 0);
        one[0] = users[3];
        core.executeAutoStrategyBatch(mapleStrategy, one, updatedYThorPending, new uint256[](0), 0, "");
        assertEq(syrupUsdc.balanceOf(users[3]), 300e6 + updatedYThorPending);
        assertEq(core.claimable(users[3]), 0);
    }

    function _strategyId(IXMetroDeFiAdapter.StrategyKind kind, address token) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, keccak256("XMETRO_DEFI_STRATEGY_V1"), kind, token));
    }

    function test_DistributorNewRewardsInvalidateOldSwapQuoteWithoutAffectingClaims() public {
        usdc.mint(address(this), 1_200e6);
        usdc.approve(address(distributor), 1_200e6);
        distributor.distribute(600e6);
        uint256 cap = core.claimable(users[0]);
        bytes memory quote = _v2Data(address(output), cap);
        distributor.distribute(600e6);
        uint256 pending = core.claimable(users[0]);
        assertGt(pending, cap);
        uint256 coreBefore = usdc.balanceOf(address(core));
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(users[0]);
        vm.expectRevert(bytes4(keccak256("InvalidExecutionRequest()")));
        core.claimAndExecute(swapStrategy, cap, block.timestamp + 1, quote);
        assertEq(core.claimable(users[0]), pending);
        assertEq(usdc.balanceOf(address(core)), coreBefore);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore);
        vm.prank(users[0]);
        assertEq(core.claimRewards(), pending);
    }

    function _v2Data(address tokenOut, uint256 cap) private view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = tokenOut;
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(0), cap, abi.encode(path));
    }

    function _oneInchData(address tokenOut, uint256 amount) private view returns (bytes memory) {
        MockOneInchRouter.SwapDescription memory description = MockOneInchRouter.SwapDescription({
            srcToken: IERC20(address(usdc)),
            dstToken: IERC20(tokenOut),
            srcReceiver: payable(address(oneInchExecutor)),
            dstReceiver: payable(address(adapter)),
            amount: amount,
            minReturnAmount: amount,
            flags: 0
        });
        bytes memory callData = abi.encodeWithSelector(
            MockOneInchRouter.swap.selector, address(oneInchExecutor), description, bytes("verified-route")
        );
        return abi.encode(keccak256("XMETRO_SWAP_V2"), uint8(2), amount, callData);
    }

    function _adapterInitCode() private view returns (bytes memory) {
        string memory artifact = vm.readFile("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json");
        return vm.parseJsonBytes(artifact, ".bytecode.object");
    }

    function _create(bytes memory initCode) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        require(deployed != address(0));
    }
}
