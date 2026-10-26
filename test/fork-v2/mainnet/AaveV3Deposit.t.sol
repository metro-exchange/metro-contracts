// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

interface IAaveV3PoolMainnet {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAUSDCMainnet is IERC20 {
    function scaledBalanceOf(address user) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
}

/// @notice E-18: Deposit actual USDC rewards from the complete project into the Ethereum Aave V3 Pool.
contract AaveV3DepositMainnetTest is MainnetForkBase {
    IAaveV3PoolMainnet private pool;
    IAUSDCMainnet private aUSDC;
    bytes32 private strategy;
    address[3] private users;

    event Supply(address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode);
    event BalanceTransfer(address indexed from, address indexed to, uint256 value, uint256 index);
    event UserStrategySettled(bytes32 indexed strategyId, address indexed user, uint256 rewardAmount, uint256 amountOut);

    function setUp() public {
        _fork();
        _deploySystem();
        pool = IAaveV3PoolMainnet(AAVE_V3_POOL);
        aUSDC = IAUSDCMainnet(A_USDC);
        assertEq(pool.getReserveData(USDC).aTokenAddress, A_USDC);
        assertEq(aUSDC.UNDERLYING_ASSET_ADDRESS(), USDC);
        assertEq(aUSDC.POOL(), AAVE_V3_POOL);
        strategy = IXMetroAdapterAdminFork(proxy).setAaveV3Config(AAVE_V3_POOL, A_USDC, 37, true, true);
        core.unpause();
        users[0] = makeAddr("aave-v3-alice");
        users[1] = makeAddr("aave-v3-bob");
        users[2] = makeAddr("aave-v3-carol");
    }

    function _three() private view returns (address[] memory list) {
        list = new address[](3);
        for (uint256 i; i < 3; ++i) list[i] = users[i];
    }

    function _stakeThree() private {
        _mintAndStake(users[0], 2 ether);
        _mintAndStake(users[1], 3 ether);
        _mintAndStake(users[2], 5 ether);
    }

    function _assertSupply(Vm.Log[] memory logs, address beneficiary, uint256 amount, uint16 referral)
        private
        view
        returns (uint256 count)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != AAVE_V3_POOL || logs[i].topics.length == 0 || logs[i].topics[0] != Supply.selector) continue;
            ++count;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), USDC);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), beneficiary);
            assertEq(uint16(uint256(logs[i].topics[3])), referral);
            (address caller, uint256 actualAmount) = abi.decode(logs[i].data, (address, uint256));
            assertEq(caller, proxy);
            assertEq(actualAmount, amount);
        }
    }

    function _assertTransferEvents(Vm.Log[] memory logs, uint256[3] memory deltas, uint256 index) private view {
        uint256 transferEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == A_USDC && logs[i].topics[0] == BalanceTransfer.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), proxy);
                address recipient = address(uint160(uint256(logs[i].topics[2])));
                (uint256 scaled, uint256 eventIndex) = abi.decode(logs[i].data, (uint256, uint256));
                if (recipient == users[0]) assertEq(scaled, deltas[0]);
                else if (recipient == users[1]) assertEq(scaled, deltas[1]);
                else {
                    assertEq(recipient, users[2]);
                    assertEq(scaled, deltas[2]);
                }
                assertEq(eventIndex, index);
                ++transferEvents;
            }
        }
        assertEq(transferEvents, 3);
    }

    function _assertSettledEvents(Vm.Log[] memory logs, uint256[3] memory deltas, uint256 index) private view {
        uint256 settledEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == proxy && logs[i].topics[0] == UserStrategySettled.selector) {
                assertEq(logs[i].topics[1], strategy);
                address recipient = address(uint160(uint256(logs[i].topics[2])));
                (uint256 eventIn, uint256 eventOut) = abi.decode(logs[i].data, (uint256, uint256));
                if (recipient == users[0]) {
                    assertEq(eventIn, 20e6);
                    assertEq(eventOut, deltas[0] * index / 1e27);
                } else if (recipient == users[1]) {
                    assertEq(eventIn, 30e6);
                    assertEq(eventOut, deltas[1] * index / 1e27);
                } else {
                    assertEq(recipient, users[2]);
                    assertEq(eventIn, 50e6);
                    assertEq(eventOut, deltas[2] * index / 1e27);
                }
                ++settledEvents;
            }
        }
        assertEq(settledEvents, 3);
    }

    /// E-18.01/.02/.04: Tests manual real supply reserve binding and referral.
    function test_E18_ManualRealSupplyReserveBindingAndReferral() public {
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        uint256 scaledBefore = aUSDC.scaledBalanceOf(users[0]);
        uint256 nominalBefore = aUSDC.balanceOf(users[0]);
        vm.recordLogs();
        vm.prank(users[0]);
        (uint256 amountIn, uint256 nominalOut) = core.claimAndExecute(strategy, 1, 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(amountIn, 100e6);
        assertGt(nominalOut, 0);
        uint256 scaledOut = aUSDC.scaledBalanceOf(users[0]) - scaledBefore;
        uint256 index = pool.getReserveNormalizedIncome(USDC);
        assertEq(nominalOut, scaledOut * index / 1e27);
        assertApproxEqAbs(aUSDC.balanceOf(users[0]) - nominalBefore, nominalOut, 1);
        assertEq(_assertSupply(logs, users[0], 100e6, 37), 1);
        assertEq(core.claimable(users[0]), 0);
        assertEq(IERC20(USDC).allowance(proxy, AAVE_V3_POOL), 0);
        emit log_named_uint("Aave V3 manual scaled aUSDC", scaledOut);
    }

    /// E-18.01/.04: Tests config update changes actual pool referral.
    function test_E18_ConfigUpdateChangesActualPoolReferral() public {
        strategy = IXMetroAdapterAdminFork(proxy).setAaveV3Config(AAVE_V3_POOL, A_USDC, 42, true, true);
        _mintAndStake(users[0], 1 ether);
        _distribute(100e6);
        vm.recordLogs();
        vm.prank(users[0]);
        core.claimAndExecute(strategy, 1, 0, "");
        assertEq(_assertSupply(vm.getRecordedLogs(), users[0], 100e6, 42), 1);
    }

    /// E-18.03/.05: Tests batch single supply scaled conservation and donations.
    function test_E18_BatchSingleSupplyScaledConservationAndDonations() public {
        _stakeThree();
        for (uint256 i; i < 3; ++i) {
            vm.prank(users[i]);
            core.enableAutoStrategy(strategy);
        }
        _distribute(100e6);
        // The real Pool mints aUSDC to the test account, which transfers it to the Proxy; USDC donations transfer normally.
        _fundUSDC(address(this), 25e6);
        IERC20(USDC).approve(AAVE_V3_POOL, 25e6);
        pool.supply(USDC, 25e6, address(this), 0);
        IERC20(USDC).approve(AAVE_V3_POOL, 0);
        assertTrue(aUSDC.transfer(proxy, 10e6));
        _fundUSDC(proxy, 5e6);
        uint256 donatedScaled = aUSDC.scaledBalanceOf(proxy);
        uint256[3] memory beforeScaled;
        for (uint256 i; i < 3; ++i) beforeScaled[i] = aUSDC.scaledBalanceOf(users[i]);
        vm.recordLogs();
        (uint256 amountIn, uint256 nominalOut) =
            core.executeAutoStrategyBatch(strategy, _three(), 1, new uint256[](0), 0, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(amountIn, 100e6);
        assertGt(nominalOut, 0);
        assertEq(_assertSupply(logs, proxy, 100e6, 37), 1);
        uint256 totalScaled;
        uint256[3] memory deltas;
        for (uint256 i; i < 3; ++i) {
            uint256 delta = aUSDC.scaledBalanceOf(users[i]) - beforeScaled[i];
            assertGt(delta, 0);
            deltas[i] = delta;
            totalScaled += delta;
            assertEq(core.claimable(users[i]), 0);
        }
        assertEq(deltas[0], totalScaled * 20 / 100);
        assertEq(deltas[1], totalScaled * 30 / 100);
        assertEq(deltas[2], totalScaled - deltas[0] - deltas[1]);
        uint256 index = pool.getReserveNormalizedIncome(USDC);
        _assertTransferEvents(logs, deltas, index);
        _assertSettledEvents(logs, deltas, index);
        assertEq(nominalOut, totalScaled * index / 1e27);
        assertEq(aUSDC.scaledBalanceOf(proxy), donatedScaled);
        assertEq(IERC20(USDC).balanceOf(proxy), 5e6);
        assertEq(IERC20(USDC).allowance(proxy, AAVE_V3_POOL), 0);
    }

    /// E-18.06: Tests minimum and disable rollback then resume.
    function test_E18_MinimumAndDisableRollbackThenResume() public {
        _mintAndStake(users[0], 1 ether);
        vm.prank(users[0]);
        core.enableAutoStrategy(strategy);
        _distribute(100e6);
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(strategy, type(uint256).max, 0, "");
        assertEq(core.claimable(users[0]), 100e6);
        assertEq(aUSDC.scaledBalanceOf(users[0]), 0);
        IXMetroAdapterAdminFork(proxy).setAaveV3Config(address(0), address(0), 0, false, false);
        vm.prank(users[0]);
        vm.expectRevert();
        core.claimAndExecute(strategy, 1, 0, "");
        vm.expectRevert();
        core.executeAutoStrategyBatch(strategy, _three(), 1, new uint256[](0), 0, "");
        strategy = IXMetroAdapterAdminFork(proxy).setAaveV3Config(AAVE_V3_POOL, A_USDC, 37, true, true);
        vm.prank(users[0]);
        core.enableAutoStrategy(strategy);
        vm.prank(users[0]);
        (uint256 amountIn,) = core.claimAndExecute(strategy, 1, 0, "");
        assertEq(amountIn, 100e6);
        assertEq(core.claimable(users[0]), 0);
    }
}
