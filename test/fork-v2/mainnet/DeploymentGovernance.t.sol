// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MetroToken} from "../../../src/metro.sol";
import {xMETRO} from "../../../src/xMETRO.sol";
import {ThorMigrationEscrow} from "../../../src/ThorMigrationEscrow.sol";
import {RewardDistributor} from "../../../src/RewardDistributor.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase, IUniswapV2RouterMainnet} from "./MainnetForkBase.sol";

interface IAdapterInitializer {
    function initialize(address core, address usdc, address metro) external;
}

interface IAdapterRescue {
    function rescueERC20(address token, address recipient, uint256 amount) external;
}

contract DeploymentGovernanceMainnetTest is MainnetForkBase {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 private constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 private constant ADAPTER_NAMESPACE = 0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;

    function setUp() public {
        _fork();
        _deploySystem();
    }

    /// E-01.01/.02/.03: Tests normal CREATE deployment and all initial bindings.
    function test_E01_FormalCreateAndReadback() public {
        assertEq(core.YTHOR_EXIT_RAMP(), 126_144_000);
        assertEq(core.thorPositionCount(address(this)), 0);
        assertEq(core.yThorPositionCount(address(this)), 0);
        assertEq(block.chainid, 1);
        assertEq(block.number, FORK_BLOCK);
        assertGt(address(metro).code.length, 0);
        assertEq(address(core).code.length, 23_394);
        assertEq(implementation.code.length, 20_487);
        assertEq(proxy.code.length, 76);
        assertGt(address(distributor).code.length, 0);
        assertGt(address(escrow).code.length, 0);
        assertGt(address(vault).code.length, 0);
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), implementation);
        assertEq(vm.load(proxy, ADMIN_SLOT), bytes32(0));
        assertEq(vm.load(proxy, BEACON_SLOT), bytes32(0));
        assertEq(address(core.METRO()), address(metro));
        assertEq(address(core.rewardToken()), USDC);
        assertEq(core.deFiAdapter(), proxy);
        assertEq(core.rewardDistributor(), address(distributor));
        assertEq(adapter.xMETRO(), address(core));
        assertEq(adapter.USDC(), USDC);
        assertEq(adapter.METRO(), address(metro));
        assertEq(address(distributor.xMETRO()), address(core));
        assertEq(address(distributor.rewardToken()), USDC);
        assertEq(distributor.commissionVault(), address(vault));
        assertEq(distributor.maxCommissionSplitBps(), 0);
        assertEq(address(vault.usdc()), USDC);
        assertEq(vault.distributor(), address(distributor));
        assertTrue(vault.migrationFinalized());
        assertFalse(vault.paused());
        assertEq(vault.settlementTimelock(), 1 days);
        assertEq(vault.payoutTimelock(), 1 days);
        assertEq(distributor.owner(), address(this));
        assertEq(core.owner(), address(this));
        assertEq(metro.owner(), address(this));
        assertEq(vault.owner(), address(this));
        assertTrue(distributor.operators(address(this)));
        assertTrue(metro.isMinter(address(core)));
        assertFalse(metro.isMinter(address(this)));
        assertEq(core.yThorRewardWeightBps(), 20_000);
        assertEq(core.deFiAdapterEpoch(), 1);
        assertEq(address(escrow.xMETRO()), address(core));
        assertEq(address(escrow.thorToken()), THOR);
        assertEq(address(escrow.yThorToken()), YTHOR);
        assertEq(core.migrationEscrow(), address(escrow));
        assertEq(escrow.ratioThor(), 1e18);
        assertEq(escrow.ratioYThor(), 1e18);
        assertEq(escrow.capThor(), 20_000_000 ether);
        assertEq(escrow.capYThor(), 20_000_000 ether);
        assertEq(escrow.owner(), address(this));
        emit log_named_address("METRO", address(metro));
        emit log_named_address("Core", address(core));
        emit log_named_address("Adapter implementation", implementation);
        emit log_named_address("Adapter proxy", proxy);
        emit log_named_address("Distributor", address(distributor));
        emit log_named_address("Escrow", address(escrow));
        emit log_named_address("Commission Vault", address(vault));
    }

    /// E-01.04: Tests explicit pause configuration and single step ownership.
    function test_E01_ExplicitPauseConfigurationAndSingleStepOwnership() public {
        assertTrue(core.paused());
        IXMetroAdapterAdminFork(proxy).setRouters(V2_ROUTER, V3_ROUTER, ONEINCH_ROUTER);
        IXMetroAdapterAdminFork(proxy).setSwapMetroConfig(true, true);
        address nextOwner = makeAddr("next-governance-owner");
        core.transferOwnership(nextOwner);
        assertEq(core.owner(), nextOwner);
        vm.expectRevert();
        core.unpause();
        vm.prank(nextOwner);
        core.unpause();
        assertFalse(core.paused());
    }

    /// E-01.05: Tests initializer and binding guards.
    function test_E01_InitializerAndBindingGuards() public {
        vm.expectRevert();
        IAdapterInitializer(proxy).initialize(address(core), USDC, address(metro));
        vm.expectRevert();
        IAdapterInitializer(implementation).initialize(address(core), USDC, address(metro));
        vm.expectRevert();
        core.setDeFiAdapter(address(0));
        vm.expectRevert();
        core.setDeFiAdapter(makeAddr("no-code-adapter"));
        vm.expectRevert();
        core.setDeFiAdapter(USDC);
        vm.expectRevert();
        core.setRewardDistributor(makeAddr("no-code-distributor"));
        assertEq(core.deFiAdapter(), proxy);
        assertEq(core.rewardDistributor(), address(distributor));
    }

    /// E-01.06: Tests artifact sizes and Proxy slots.
    function test_E01_ArtifactSizesAndProxySlots() public view {
        assertLt(address(core).code.length, 24_576);
        assertLt(implementation.code.length, 24_576);
        assertLt(_artifact("out-core/xMETRO.sol/xMETRO.json").length, 49_152);
        assertLt(_artifact("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json").length, 49_152);
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), implementation);
        assertEq(vm.load(proxy, ADMIN_SLOT), bytes32(0));
        assertEq(vm.load(proxy, BEACON_SLOT), bytes32(0));
        assertEq(address(uint160(uint256(vm.load(proxy, ADAPTER_NAMESPACE)))), address(core));
    }

    /// E-01.07: Tests real USDC and new METRO uniswap V2 liquidity.
    function test_E01_RealUsdcAndNewMetroUniswapV2Liquidity() public {
        address user = makeAddr("migration-token-recipient");
        _fundMigrationToken(THOR, THOR_HOLDER, user, 10 ether);
        _fundMigrationToken(YTHOR, YTHOR_HOLDER, user, 10 ether);
        assertEq(IERC20(THOR).balanceOf(user), 10 ether);
        assertEq(IERC20(YTHOR).balanceOf(user), 10 ether);
        address pair = _createMetroPool(10_000 ether, 10_000e6);
        assertGt(IERC20(USDC).balanceOf(pair), 0);
        assertGt(metro.balanceOf(pair), 0);
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(metro);
        uint256[] memory quote = IUniswapV2RouterMainnet(V2_ROUTER).getAmountsOut(100e6, path);
        assertGt(quote[1], 0);
        emit log_named_address("V2 METRO/USDC pair", pair);
        emit log_named_address("THOR funding EOA", THOR_HOLDER);
        emit log_named_address("yTHOR funding EOA", YTHOR_HOLDER);
        emit log_named_uint("V2 quote for 100 USDC", quote[1]);
    }

    /// E-09.01: Tests core and escrow pause boundaries.
    function test_E09_CoreAndEscrowPauseBoundaries() public {
        address user = makeAddr("pause-user");
        core.unpause();
        _fundMigrationToken(THOR, THOR_HOLDER, user, 1 ether);
        vm.prank(user);
        IERC20(THOR).approve(address(escrow), 1 ether);
        vm.prank(user);
        vm.expectRevert();
        core.pause();
        core.pause();
        vm.prank(user);
        vm.expectRevert();
        core.stake(1 ether);
        vm.prank(user);
        vm.expectRevert();
        core.creditThorFromMigration(user, 1 ether);
        core.unpause();
        escrow.pause();
        assertTrue(escrow.paused());
        vm.prank(user);
        vm.expectRevert();
        escrow.migrateThor(1 ether);
        vm.prank(user);
        vm.expectRevert();
        escrow.unpause();
        escrow.unpause();
        assertFalse(escrow.paused());
    }

    /// E-09.02: Tests pause allows reads approvals and disable.
    function test_E09_PauseAllowsReadsApprovalsAndDisable() public {
        core.unpause();
        _configureSwaps();
        address user = makeAddr("pause-preference-user");
        vm.prank(user);
        core.enableAutocompound();
        core.pause();
        assertEq(core.claimable(user), 0);
        assertEq(core.balanceOf(user), 0);
        vm.prank(user);
        assertTrue(core.approve(address(this), 7 ether));
        assertEq(core.allowance(user, address(this)), 7 ether);
        vm.prank(user);
        core.disableAutocompound();
        assertFalse(core.autocompoundEnabled(user));
    }

    function test_E09_PauseBlocksNormalUserMoneyPaths() public {
        address user = makeAddr("paused-money-user");
        core.unpause();
        _mintAndStake(user, 10 ether);
        _distribute(10e6);
        core.pause();
        vm.startPrank(user);
        vm.expectRevert();
        core.stake(1 ether);
        vm.expectRevert();
        core.stakeAndEnableAutocompound(1 ether);
        vm.expectRevert();
        core.requestUnstake(1 ether);
        vm.expectRevert();
        core.withdrawFree(0);
        vm.expectRevert();
        core.claimRewards();
        vm.expectRevert();
        core.autocompound(1, block.timestamp + 1 hours, "");
        vm.stopPrank();
        vm.expectRevert();
        core.autocompoundBatch(new address[](1), 1, block.timestamp + 1 hours, "");
        assertEq(core.claimable(user), 10e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 10e6);
        assertEq(core.balanceOf(user), 10 ether);
    }

    /// E-09.03: Tests protected tokens and legitimate rescue.
    function test_E09_ProtectedTokensAndLegitimateRescue() public {
        address recipient = makeAddr("rescue-recipient");
        _fundUSDC(address(core), 5e6);
        _fundUSDC(address(escrow), 7e6);
        _fundMigrationToken(THOR, THOR_HOLDER, address(escrow), 1 ether);
        _fundMigrationToken(YTHOR, YTHOR_HOLDER, address(escrow), 1 ether);
        vm.expectRevert();
        core.rescueERC20(address(metro), recipient, 1);
        vm.expectRevert("ThorEscrow: cannot rescue migration tokens");
        escrow.rescueTokens(THOR, recipient, 1);
        vm.expectRevert("ThorEscrow: cannot rescue migration tokens");
        escrow.rescueTokens(YTHOR, recipient, 1);
        vm.prank(recipient);
        vm.expectRevert();
        core.rescueERC20(USDC, recipient, 1);
        core.rescueERC20(USDC, recipient, 5e6);
        escrow.rescueTokens(USDC, recipient, 7e6);
        assertEq(IERC20(USDC).balanceOf(recipient), 12e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        assertEq(IERC20(USDC).balanceOf(address(escrow)), 0);
        assertEq(IERC20(THOR).balanceOf(address(escrow)), 1 ether);
        assertEq(IERC20(YTHOR).balanceOf(address(escrow)), 1 ether);
    }

    /// E-09.04: Tests distributor rescue owner only.
    function test_E09_DistributorRescueOwnerOnly() public {
        address recipient = makeAddr("distributor-rescue-recipient");
        _fundUSDC(address(distributor), 9e6);
        vm.prank(recipient);
        vm.expectRevert();
        distributor.rescueTokens(USDC, recipient, 1e6);
        distributor.rescueTokens(USDC, recipient, 9e6);
        assertEq(IERC20(USDC).balanceOf(recipient), 9e6);
        assertEq(IERC20(USDC).balanceOf(address(distributor)), 0);
    }

    /// E-09.05: Tests adapter rescue requires current owner and pause.
    function test_E09_AdapterRescueRequiresCurrentOwnerAndPause() public {
        address recipient = makeAddr("adapter-rescue-recipient");
        address nextOwner = makeAddr("adapter-rescue-new-owner");
        _fundUSDC(proxy, 9e6);
        core.unpause();
        vm.expectRevert();
        IAdapterRescue(proxy).rescueERC20(USDC, recipient, 1e6);
        core.pause();
        vm.prank(recipient);
        vm.expectRevert();
        IAdapterRescue(proxy).rescueERC20(USDC, recipient, 1e6);
        IAdapterRescue(proxy).rescueERC20(USDC, recipient, 4e6);
        assertEq(IERC20(USDC).balanceOf(recipient), 4e6);
        core.transferOwnership(nextOwner);
        vm.expectRevert();
        IAdapterRescue(proxy).rescueERC20(USDC, recipient, 1e6);
        vm.prank(nextOwner);
        IAdapterRescue(proxy).rescueERC20(USDC, recipient, 5e6);
        assertEq(IERC20(USDC).balanceOf(recipient), 9e6);
        assertEq(IERC20(USDC).balanceOf(proxy), 0);
    }

    /// E-09.06: Tests ownership semantics and isolated renounce.
    function test_E09_OwnershipSemanticsAndIsolatedRenounce() public {
        address nextOwner = makeAddr("one-step-owner");
        vm.prank(nextOwner);
        vm.expectRevert();
        core.renounceOwnership();
        core.transferOwnership(nextOwner);
        assertEq(core.owner(), nextOwner);
        metro.transferOwnership(nextOwner);
        escrow.transferOwnership(nextOwner);
        distributor.transferOwnership(nextOwner);
        assertEq(metro.owner(), nextOwner);
        assertEq(escrow.owner(), nextOwner);
        assertEq(distributor.owner(), nextOwner);
        vm.expectRevert();
        core.setYThorRewardWeightBps(10_000);
        vm.expectRevert();
        metro.setMinter(address(this), true);
        vm.expectRevert();
        escrow.setCaps(1 ether, 1 ether);
        vm.expectRevert();
        distributor.setOperator(address(this), false);
        MetroToken spareToken = new MetroToken("Spare", "SPARE", address(this));
        ThorMigrationEscrow spareEscrow =
            new ThorMigrationEscrow(address(this), address(core), THOR, YTHOR, block.timestamp);
        RewardDistributor spareDistributor = new RewardDistributor(address(core), address(this));
        spareToken.renounceOwnership();
        spareEscrow.renounceOwnership();
        spareDistributor.renounceOwnership();
        assertEq(spareToken.owner(), address(0));
        assertEq(spareEscrow.owner(), address(0));
        assertEq(spareDistributor.owner(), address(0));
        vm.prank(nextOwner);
        core.renounceOwnership();
        assertEq(core.owner(), address(0));
        vm.prank(nextOwner);
        vm.expectRevert();
        core.setYThorRewardWeightBps(10_000);
    }

    /// E-23.01: Tests emergency owner pause and real pending.
    function test_E23_EmergencyOwnerPauseAndRealPending() public {
        address alice = makeAddr("emergency-alice");
        address bob = makeAddr("emergency-bob");
        core.unpause();
        _mintAndStake(alice, 20 ether);
        _mintAndStake(bob, 30 ether);
        _distribute(50e6);
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        vm.expectRevert();
        core.emergencyDistribute(users);
        core.pause();
        vm.prank(alice);
        vm.expectRevert();
        core.emergencyDistribute(users);
        uint256 total = core.emergencyDistribute(users);
        assertEq(total, 50e6);
        assertEq(IERC20(USDC).balanceOf(alice), 20e6);
        assertEq(IERC20(USDC).balanceOf(bob), 30e6);
        assertEq(core.claimable(alice), 0);
        assertEq(core.claimable(bob), 0);
        assertEq(core.balanceOf(alice), 20 ether);
        assertEq(core.balanceOf(bob), 30 ether);
        assertEq(metro.balanceOf(address(core)), 50 ether);
    }

    /// E-23.02: Tests emergency filtering and over one hundred users.
    function test_E23_EmergencyFilteringAndOverOneHundredUsers() public {
        core.unpause();
        address[] memory accounts = new address[](101);
        for (uint256 i; i < 101; ++i) {
            accounts[i] = vm.addr(i + 10_001);
            _mintAndStake(accounts[i], 1 ether);
        }
        _distribute(101e6);
        core.pause();
        address[] memory empty = new address[](0);
        vm.expectRevert();
        core.emergencyDistribute(empty);
        address[] memory candidates = new address[](103);
        candidates[0] = address(0);
        for (uint256 i; i < 101; ++i) {
            candidates[i + 1] = accounts[i];
        }
        candidates[102] = accounts[0];
        uint256 gasBefore = gasleft();
        uint256 paid = core.emergencyDistribute(candidates);
        uint256 businessGas = gasBefore - gasleft();
        assertLt(businessGas, 16_777_216);
        assertEq(paid, 101e6);
        assertEq(IERC20(USDC).balanceOf(accounts[0]), 1e6);
        assertEq(IERC20(USDC).balanceOf(accounts[100]), 1e6);
        assertEq(core.claimable(accounts[0]), 0);
        vm.expectRevert();
        core.emergencyDistribute(candidates);
        address[] memory onlyZero = new address[](1);
        vm.expectRevert();
        core.emergencyDistribute(onlyZero);
        emit log_named_uint("Emergency 101 users business-call gas", businessGas);
    }

    /// E-23.03: Tests emergency insufficient balance rolls back whole batch.
    function test_E23_EmergencyInsufficientBalanceRollsBackWholeBatch() public {
        address alice = makeAddr("emergency-rollback-alice");
        address bob = makeAddr("emergency-rollback-bob");
        core.unpause();
        _mintAndStake(alice, 20 ether);
        _mintAndStake(bob, 30 ether);
        _distribute(50e6);
        core.rescueERC20(USDC, address(this), 25e6);
        core.pause();
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        vm.expectRevert();
        core.emergencyDistribute(users);
        assertEq(IERC20(USDC).balanceOf(alice), 0);
        assertEq(IERC20(USDC).balanceOf(bob), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 25e6);
        assertEq(core.claimable(alice), 20e6);
        assertEq(core.claimable(bob), 30e6);
        assertEq(core.balanceOf(alice), 20 ether);
        assertEq(core.balanceOf(bob), 30 ether);
    }

    /// E-23.04: Tests emergency preserves all principal ledgers.
    function test_E23_EmergencyPreservesAllPrincipalLedgers() public {
        address user = makeAddr("emergency-mixed-user");
        core.unpause();
        _mintAndStake(user, 10 ether);
        _fundMigrationToken(THOR, THOR_HOLDER, user, 10 ether);
        _fundMigrationToken(YTHOR, YTHOR_HOLDER, user, 10 ether);
        vm.startPrank(user);
        IERC20(THOR).approve(address(escrow), 10 ether);
        IERC20(YTHOR).approve(address(escrow), 10 ether);
        escrow.migrateThor(10 ether);
        escrow.migrateYThor(10 ether);
        vm.stopPrank();
        core.setContributor(address(this), true);
        metro.mint(address(this), 10 ether);
        metro.approve(address(core), 10 ether);
        core.stakeContributor(10 ether, user);
        uint256 metroBacking = metro.balanceOf(address(core));
        uint256 totalSharesBefore = core.totalShares();
        uint256 totalWeightBefore = core.totalRewardWeight();
        xMETRO.VestingSchedule memory schedule = core.contributorVesting(user, 0);
        _distribute(50e6);
        uint256 pending = core.claimable(user);
        assertGt(pending, 0);
        core.pause();
        address[] memory users = new address[](1);
        users[0] = user;
        assertEq(core.emergencyDistribute(users), pending);
        assertEq(metro.balanceOf(address(core)), metroBacking);
        assertEq(core.totalShares(), totalSharesBefore);
        assertEq(core.totalRewardWeight(), totalWeightBefore);
        (uint128 thorPrincipal,, uint64 thorExitedAt, bool thorExited) = core.thorPositions(user, 0);
        (uint128 yPrincipal,, uint64 yExitedAt, bool yExited) = core.yThorPositions(user, 0);
        assertEq(thorPrincipal, 10 ether);
        assertEq(yPrincipal, 10 ether);
        assertEq(thorExitedAt, 0);
        assertEq(yExitedAt, 0);
        assertFalse(thorExited);
        assertFalse(yExited);
        xMETRO.VestingSchedule memory afterSchedule = core.contributorVesting(user, 0);
        assertEq(keccak256(abi.encode(afterSchedule)), keccak256(abi.encode(schedule)));
        assertEq(core.claimable(user), 0);
    }

    /// E-23.05: Tests replace escrow and distributor revokes old roles.
    function test_E23_ReplaceEscrowAndDistributorRevokesOldRoles() public {
        address user = makeAddr("replace-governance-user");
        core.unpause();
        _mintAndStake(user, 100 ether);
        _distribute(10e6);
        uint256 originalPending = core.claimable(user);
        _fundMigrationToken(THOR, THOR_HOLDER, user, 2 ether);
        ThorMigrationEscrow nextEscrow =
            new ThorMigrationEscrow(address(this), address(core), THOR, YTHOR, block.timestamp);
        nextEscrow.setCaps(100 ether, 100 ether);
        nextEscrow.setRatios(1e18, 1e18);
        nextEscrow.setDeadlines(block.timestamp + 365 days, block.timestamp + 365 days);
        core.setMigrationEscrow(address(nextEscrow));
        assertEq(core.migrationEscrow(), address(nextEscrow));
        assertEq(core.balanceOf(user), 100 ether);
        assertEq(core.claimable(user), originalPending);
        vm.prank(user);
        IERC20(THOR).approve(address(escrow), 1 ether);
        vm.prank(user);
        vm.expectRevert();
        escrow.migrateThor(1 ether);
        vm.prank(user);
        IERC20(THOR).approve(address(nextEscrow), 1 ether);
        vm.prank(user);
        nextEscrow.migrateThor(1 ether);
        (uint128 principal,,,) = core.thorPositions(user, 0);
        assertEq(principal, 1 ether);
        assertEq(IERC20(THOR).balanceOf(address(nextEscrow)), 1 ether);
        RewardDistributor nextDistributor = new RewardDistributor(address(core), address(this));
        nextDistributor.setOperator(address(this), true);
        core.setRewardDistributor(address(nextDistributor));
        assertEq(core.claimable(user), originalPending);
        _fundUSDC(address(this), 100e6);
        IERC20(USDC).approve(address(distributor), 100e6);
        vm.expectRevert();
        distributor.distribute(100e6);
        IERC20(USDC).approve(address(nextDistributor), 100e6);
        nextDistributor.distribute(100e6);
        assertEq(core.rewardDistributor(), address(nextDistributor));
        assertGt(core.claimable(user), originalPending);
        assertEq(IERC20(USDC).balanceOf(address(core)), 110e6);
    }

    /// E-23.05: Tests replace auto compound operator uses new keeper.
    function test_E23_ReplaceAutoCompoundOperatorUsesNewKeeper() public {
        core.unpause();
        _configureSwaps();
        _createMetroPool(10_000 ether, 10_000e6);
        address user = makeAddr("new-keeper-staker");
        address newKeeper = makeAddr("new-keeper");
        _mintAndStake(user, 100 ether);
        vm.prank(user);
        core.enableAutocompound();
        _distribute(100e6);
        uint256 pendingBeforeRoles = core.claimable(user);
        core.setAutoCompoundOperator(address(this), false);
        core.setAutoCompoundOperator(newKeeper, true);
        assertEq(core.claimable(user), pendingBeforeRoles);
        assertFalse(core.autoCompoundOperators(address(this)));
        assertTrue(core.autoCompoundOperators(newKeeper));
        address[] memory users = new address[](1);
        users[0] = user;
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(metro);
        bytes memory executionData = abi.encode(uint8(0), abi.encode(path));
        vm.expectRevert();
        core.autocompoundBatch(users, 1, block.timestamp + 1 hours, executionData);
        vm.prank(newKeeper);
        uint256 metroOut = core.autocompoundBatch(users, 1, block.timestamp + 1 hours, executionData);
        assertGt(metroOut, 0);
        assertEq(core.claimable(user), 0);
        assertEq(core.balanceOf(user), 100 ether + metroOut);
    }
}
