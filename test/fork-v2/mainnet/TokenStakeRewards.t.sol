// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {MetroToken} from "../../../src/metro.sol";
import {xMETRO} from "../../../src/xMETRO.sol";
import {IXMetroAdapterAdminFork} from "../XMetroForkBase.sol";
import {MainnetForkBase} from "./MainnetForkBase.sol";

contract TokenStakeRewardsMainnetTest is MainnetForkBase {
    event Staked(address indexed user, uint256 amount, uint256 mintedShares);
    event UnstakeRequested(
        address indexed user, xMETRO.UnstakeSource indexed source, uint256 amount, uint64 unlockTime
    );
    event Withdrawn(address indexed user, xMETRO.UnstakeSource indexed source, uint256 amount);
    event RewardsDeposited(address indexed payer, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardsDistributed(address indexed caller, uint256 amount, uint64 timestamp);
    event DistributionRouted(
        address indexed caller,
        address indexed commissionVault,
        uint256 grossAmount,
        uint256 commissionAmount,
        uint256 netReward,
        uint64 timestamp
    );

    address private alice;
    address private bob;
    address private spender;

    function setUp() public {
        _fork();
        _deploySystem();
        core.unpause();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    /// E-02.01: Tests metadata and initial supply.
    function test_E02_MetadataAndInitialSupply() public view {
        assertEq(metro.name(), "Metro");
        assertEq(metro.symbol(), "METRO");
        assertEq(metro.decimals(), 18);
        assertEq(metro.cap(), 100_000_000 ether);
        assertEq(metro.MAX_SUPPLY(), 100_000_000 ether);
        assertEq(metro.totalSupply(), 0);
        assertEq(metro.balanceOf(alice), 0);
    }

    /// E-02.02: Tests ERC-20 transfers and allowances.
    function test_E02_Erc20TransfersAndAllowances() public {
        metro.setMinter(address(this), true);
        metro.mint(alice, 100 ether);
        vm.prank(alice);
        assertTrue(metro.transfer(bob, 20 ether));
        assertEq(metro.balanceOf(alice), 80 ether);
        assertEq(metro.balanceOf(bob), 20 ether);
        vm.prank(alice);
        assertTrue(metro.approve(spender, 30 ether));
        vm.prank(spender);
        assertTrue(metro.transferFrom(alice, bob, 25 ether));
        assertEq(metro.balanceOf(alice), 55 ether);
        assertEq(metro.balanceOf(bob), 45 ether);
        assertEq(metro.allowance(alice, spender), 5 ether);
        vm.prank(spender);
        vm.expectRevert();
        metro.transferFrom(alice, bob, 6 ether);
        vm.prank(alice);
        vm.expectRevert();
        metro.transfer(bob, 56 ether);
        assertEq(metro.totalSupply(), 100 ether);
    }

    /// E-02.03: Tests permit nonce domain expiry replay and wrong signer.
    function test_E02_PermitNonceDomainExpiryReplayAndWrongSigner() public {
        uint256 key = 0xA11CE;
        address signer = vm.addr(key);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 domain = metro.DOMAIN_SEPARATOR();
        assertNotEq(domain, bytes32(0));
        assertEq(metro.nonces(signer), 0);
        bytes32 structHash = keccak256(abi.encode(typehash, signer, spender, 123 ether, uint256(0), deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domain, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        metro.permit(signer, spender, 123 ether, deadline, v, r, s);
        assertEq(metro.allowance(signer, spender), 123 ether);
        assertEq(metro.nonces(signer), 1);
        vm.expectRevert();
        metro.permit(signer, spender, 123 ether, deadline, v, r, s);
        bytes32 laterHash = keccak256(abi.encode(typehash, signer, spender, 1 ether, uint256(1), deadline));
        (uint8 badV, bytes32 badR, bytes32 badS) =
            vm.sign(0xB0B, keccak256(abi.encodePacked(hex"1901", domain, laterHash)));
        vm.expectRevert();
        metro.permit(signer, spender, 1 ether, deadline, badV, badR, badS);
        vm.warp(deadline + 1);
        vm.expectRevert();
        metro.permit(signer, spender, 123 ether, deadline, v, r, s);
        assertEq(metro.nonces(signer), 1);
    }

    /// E-02.04: Tests minter grant revoke and owner not minter.
    function test_E02_MinterGrantRevokeAndOwnerNotMinter() public {
        assertFalse(metro.isMinter(address(this)));
        vm.expectRevert("MetroToken: not minter");
        metro.mint(alice, 1 ether);
        metro.setMinter(spender, true);
        vm.prank(spender);
        metro.mint(alice, 1 ether);
        assertEq(metro.balanceOf(alice), 1 ether);
        metro.setMinter(spender, false);
        vm.prank(spender);
        vm.expectRevert("MetroToken: not minter");
        metro.mint(alice, 1 ether);
    }

    /// E-02.05: Tests isolated global cap and invalid mint.
    function test_E02_IsolatedGlobalCapAndInvalidMint() public {
        MetroToken capped = MetroToken(
            _create(
                abi.encodePacked(
                    _artifact("out-core/metro.sol/MetroToken.json"), abi.encode("Metro", "METRO", address(this))
                )
            )
        );
        capped.setMinter(alice, true);
        capped.setMinter(bob, true);
        vm.prank(alice);
        capped.mint(alice, 60_000_000 ether);
        vm.prank(bob);
        capped.mint(bob, 40_000_000 ether);
        assertEq(capped.totalSupply(), capped.MAX_SUPPLY());
        vm.prank(bob);
        vm.expectRevert();
        capped.mint(bob, 1);
        vm.prank(bob);
        vm.expectRevert("MetroToken: zero amount");
        capped.mint(bob, 0);
        vm.prank(bob);
        vm.expectRevert("MetroToken: bad to");
        capped.mint(address(0), 1);
    }

    /// E-03.01: Tests locked shares are not transferable ERC-20.
    function test_E03_LockedSharesAreNotTransferableErc20() public {
        metro.setMinter(address(this), true);
        metro.mint(alice, 100 ether);
        core.setContributor(alice, true);
        vm.startPrank(alice);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, alice);
        assertEq(core.balanceOf(alice), 0);
        assertEq(core.lockedShares(alice), 100 ether);
        vm.expectRevert();
        core.transfer(bob, 1 ether);
        vm.stopPrank();
        assertEq(core.totalSharesOf(alice), 100 ether);
        assertEq(core.totalSupply(), 0);
        assertEq(core.totalLockedShares(), 100 ether);
    }

    /// E-03.02: Tests transfer preserves old pending and moves future weight.
    function test_E03_TransferPreservesOldPendingAndMovesFutureWeight() public {
        _mintAndStake(alice, 100 ether);
        _distribute(100e6);
        assertEq(core.claimable(alice), 100e6);
        vm.prank(alice);
        core.transfer(bob, 100 ether);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.claimable(bob), 0);
        _distribute(100e6);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.claimable(bob), 100e6);
        assertEq(core.rewardDebt(alice), -100e6);
        assertEq(core.rewardDebt(bob), 100e6);
        assertEq(core.totalRewardWeight(), 100 ether);
        assertEq(IERC20(USDC).balanceOf(address(core)), 200e6);
    }

    /// E-03.03: Tests mixed shares transfer from conservation.
    function test_E03_MixedSharesTransferFromConservation() public {
        _mintAndStake(alice, 100 ether);
        metro.mint(alice, 50 ether);
        core.setContributor(alice, true);
        vm.startPrank(alice);
        metro.approve(address(core), 50 ether);
        core.stakeContributor(50 ether, alice);
        vm.stopPrank();
        _distribute(150e6);
        assertEq(core.claimable(alice), 150e6);
        vm.prank(alice);
        core.approve(spender, 40 ether);
        vm.prank(spender);
        core.transferFrom(alice, bob, 40 ether);
        assertEq(core.allowance(alice, spender), 0);
        assertEq(core.balanceOf(alice), 60 ether);
        assertEq(core.balanceOf(bob), 40 ether);
        assertEq(core.lockedShares(alice), 50 ether);
        assertEq(core.totalSupply(), 100 ether);
        assertEq(core.totalShares(), 150 ether);
        assertEq(core.totalRewardWeight(), 150 ether);
        assertEq(core.claimable(alice), 150e6);
        assertEq(core.claimable(bob), 0);
    }

    /// E-03.04: Tests self zero allowance and pause boundaries.
    function test_E03_SelfZeroAllowanceAndPauseBoundaries() public {
        _mintAndStake(alice, 100 ether);
        vm.startPrank(alice);
        core.transfer(alice, 10 ether);
        core.transfer(bob, 0);
        core.approve(spender, 5 ether);
        vm.stopPrank();
        assertEq(core.balanceOf(alice), 100 ether);
        vm.prank(spender);
        vm.expectRevert();
        core.transferFrom(alice, bob, 6 ether);
        core.pause();
        vm.prank(alice);
        vm.expectRevert();
        core.transfer(bob, 1 ether);
        (bool hasPermit,) = address(core).staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertFalse(hasPermit);
        vm.prank(alice);
        core.approve(spender, 10 ether);
        assertEq(core.allowance(alice, spender), 10 ether);
        assertEq(core.balanceOf(alice), 100 ether);
    }

    /// E-04.01: Tests stake one to one and old pending.
    function test_E04_StakeOneToOneAndOldPending() public {
        vm.recordLogs();
        _mintAndStake(alice, 100 ether);
        Vm.Log memory stakeLog = _eventLog(vm.getRecordedLogs(), address(core), Staked.selector);
        assertEq(address(uint160(uint256(stakeLog.topics[1]))), alice);
        (uint256 staked, uint256 minted) = abi.decode(stakeLog.data, (uint256, uint256));
        assertEq(staked, 100 ether);
        assertEq(minted, 100 ether);
        _distribute(100e6);
        _mintAndStake(bob, 100 ether);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.claimable(bob), 0);
        assertEq(core.balanceOf(alice), 100 ether);
        assertEq(core.balanceOf(bob), 100 ether);
        assertEq(core.totalSupply(), 200 ether);
        assertEq(metro.balanceOf(address(core)), 200 ether);
        assertEq(metro.allowance(bob, address(core)), 0);
        assertEq(core.rewardDebt(bob), 100e6);
    }

    /// E-04.02: Tests stake and enable autocompound atomicity.
    function test_E04_StakeAndEnableAutocompoundAtomicity() public {
        metro.setMinter(address(this), true);
        metro.mint(alice, 100 ether);
        vm.startPrank(alice);
        metro.approve(address(core), 100 ether);
        vm.expectRevert();
        core.stakeAndEnableAutocompound(50 ether);
        assertEq(core.balanceOf(alice), 0);
        assertEq(metro.balanceOf(alice), 100 ether);
        vm.stopPrank();
        _configureSwaps();
        vm.prank(alice);
        core.stakeAndEnableAutocompound(50 ether);
        assertEq(core.balanceOf(alice), 50 ether);
        assertTrue(core.autocompoundEnabled(alice));
        assertEq(metro.balanceOf(alice), 50 ether);
        assertEq(metro.balanceOf(address(core)), 50 ether);
    }

    /// E-04.03: Tests request unstake preserves old pending.
    function test_E04_RequestUnstakePreservesOldPending() public {
        _mintAndStake(alice, 100 ether);
        _distribute(100e6);
        vm.expectEmit(true, true, false, true, address(core));
        emit UnstakeRequested(alice, xMETRO.UnstakeSource.Free, 40 ether, uint64(block.timestamp + 72 hours));
        vm.prank(alice);
        core.requestUnstake(40 ether);
        assertEq(core.balanceOf(alice), 60 ether);
        assertEq(core.totalShares(), 60 ether);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.unstakeRequestCountFree(alice), 1);
        xMETRO.UnstakeRequest memory r = core.unstakeRequestFree(alice, 0);
        assertEq(r.amount, 40 ether);
        assertEq(r.unlockTime, block.timestamp + 72 hours);
        _distribute(60e6);
        assertEq(core.claimable(alice), 160e6);
    }

    /// E-04.04: Tests exact72 hour free withdrawal boundary.
    function test_E04_Exact72HourFreeWithdrawalBoundary() public {
        _mintAndStake(alice, 100 ether);
        vm.prank(alice);
        core.requestUnstake(40 ether);
        uint256 unlock = core.unstakeRequestFree(alice, 0).unlockTime;
        uint256 snapshot = vm.snapshotState();
        vm.warp(unlock - 1);
        vm.prank(alice);
        vm.expectRevert(xMETRO.NothingToWithdraw.selector);
        core.withdrawFree(0);
        vm.warp(unlock);
        vm.expectEmit(true, true, false, true, address(core));
        emit Withdrawn(alice, xMETRO.UnstakeSource.Free, 40 ether);
        vm.prank(alice);
        assertEq(core.withdrawFree(0), 40 ether);
        assertEq(metro.balanceOf(alice), 40 ether);
        assertEq(core.unstakeCursorFree(alice), 1);
        vm.prank(alice);
        assertEq(core.withdrawFree(0), 0);
        vm.revertToState(snapshot);
        vm.warp(unlock + 1);
        vm.prank(alice);
        assertEq(core.withdrawFree(0), 40 ether);
        assertEq(metro.balanceOf(alice), 40 ether);
    }

    /// E-04.05: Tests queue pagination and empty semantics.
    function test_E04_QueuePaginationAndEmptySemantics() public {
        vm.prank(alice);
        assertEq(core.withdrawFree(0), 0);
        _mintAndStake(alice, 100 ether);
        vm.startPrank(alice);
        core.requestUnstake(20 ether);
        core.requestUnstake(30 ether);
        core.requestUnstake(10 ether);
        vm.stopPrank();
        assertEq(core.unstakeRequestCountFree(alice), 3);
        assertEq(core.unstakeRequestCountThor(alice), 0);
        assertEq(core.unstakeRequestCountYThor(alice), 0);
        assertEq(core.unstakeRequestCountContributor(alice), 0);
        vm.warp(core.unstakeRequestFree(alice, 0).unlockTime);
        vm.prank(alice);
        assertEq(core.withdrawFree(1), 20 ether);
        assertEq(core.unstakeCursorFree(alice), 1);
        vm.prank(alice);
        assertEq(core.withdrawFree(0), 40 ether);
        assertEq(core.unstakeCursorFree(alice), 3);
        assertEq(metro.balanceOf(alice), 60 ether);
        vm.prank(alice);
        assertEq(core.withdrawFree(1), 0);
    }

    /// E-04.06: Tests invalid stake and unstake amounts.
    function test_E04_InvalidStakeAndUnstakeAmounts() public {
        vm.prank(alice);
        vm.expectRevert(xMETRO.InvalidAmount.selector);
        core.stake(0);
        _mintAndStake(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(xMETRO.InvalidAmount.selector);
        core.requestUnstake(0);
        vm.prank(alice);
        vm.expectRevert(xMETRO.InvalidAmount.selector);
        core.requestUnstake(2 ether);
        vm.prank(alice);
        vm.expectRevert(xMETRO.InvalidAmount.selector);
        core.requestUnstake(uint256(type(uint128).max) + 1);
        assertEq(core.unstakeRequestCountFree(alice), 0);
        assertEq(core.unstakeRequestCountThor(alice), 0);
    }

    /// E-05.01: Tests operator distribute uses real USDC.
    function test_E05_OperatorDistributeUsesRealUsdc() public {
        _mintAndStake(alice, 20 ether);
        _mintAndStake(bob, 30 ether);
        vm.recordLogs();
        _distribute(100e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory depositLog = _eventLog(logs, address(core), RewardsDeposited.selector);
        assertEq(address(uint160(uint256(depositLog.topics[1]))), address(distributor));
        assertEq(abi.decode(depositLog.data, (uint256)), 100e6);
        Vm.Log memory routedLog = _eventLog(logs, address(distributor), DistributionRouted.selector);
        assertEq(address(uint160(uint256(routedLog.topics[1]))), address(this));
        assertEq(address(uint160(uint256(routedLog.topics[2]))), address(0));
        (uint256 gross, uint256 commission, uint256 net, uint64 timestamp) =
            abi.decode(routedLog.data, (uint256, uint256, uint256, uint64));
        assertEq(gross, 100e6);
        assertEq(commission, 0);
        assertEq(net, 100e6);
        assertEq(timestamp, block.timestamp);
        Vm.Log memory distributedLog = _eventLog(logs, address(distributor), RewardsDistributed.selector);
        assertEq(address(uint160(uint256(distributedLog.topics[1]))), address(this));
        (uint256 distributedAmount, uint64 distributedAt) = abi.decode(distributedLog.data, (uint256, uint64));
        assertEq(distributedAmount, 100e6);
        assertEq(distributedAt, timestamp);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(IERC20(USDC).balanceOf(address(distributor)), 0);
        assertEq(IERC20(USDC).allowance(address(distributor), address(core)), 0);
        assertEq(core.claimable(alice), 40e6);
        assertEq(core.claimable(bob), 60e6);
        assertEq(core.rewardDebt(alice), 0);
        assertEq(core.rewardDebt(bob), 0);
        emit log_named_uint("Core USDC after distribute", IERC20(USDC).balanceOf(address(core)));
    }

    /// E-05.02: Tests distribute from balance.
    function test_E05_DistributeFromBalance() public {
        _mintAndStake(alice, 1 ether);
        _fundUSDC(address(distributor), 120e6);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit DistributionRouted(address(this), address(0), 100e6, 0, 100e6, uint64(block.timestamp));
        distributor.distributeFromBalance(100e6);
        assertEq(IERC20(USDC).balanceOf(address(distributor)), 20e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 100e6);
        assertEq(core.claimable(alice), 100e6);
        assertEq(IERC20(USDC).allowance(address(distributor), address(core)), 0);
    }

    /// E-05.03: Tests operator and distributor access.
    function test_E05_OperatorAndDistributorAccess() public {
        _mintAndStake(alice, 1 ether);
        _fundUSDC(bob, 10e6);
        vm.startPrank(bob);
        IERC20(USDC).approve(address(distributor), 10e6);
        vm.expectRevert("RewardDistributor: only operator");
        distributor.distribute(10e6);
        vm.expectRevert(xMETRO.Unauthorized.selector);
        core.depositRewards(10e6);
        vm.stopPrank();
        distributor.setOperator(bob, true);
        vm.prank(bob);
        distributor.distribute(10e6);
        assertEq(core.claimable(alice), 10e6);
        distributor.setOperator(bob, false);
        vm.prank(bob);
        vm.expectRevert("RewardDistributor: only operator");
        distributor.distribute(1);
    }

    /// E-05.04: Tests claim all and repeated zero.
    function test_E05_ClaimAllAndRepeatedZero() public {
        _mintAndStake(alice, 2 ether);
        _mintAndStake(bob, 3 ether);
        _distribute(500e6);
        vm.expectEmit(true, false, false, true, address(core));
        emit RewardClaimed(alice, 200e6);
        vm.prank(alice);
        assertEq(core.claimRewards(), 200e6);
        vm.prank(bob);
        assertEq(core.claimRewards(), 300e6);
        assertEq(IERC20(USDC).balanceOf(alice), 200e6);
        assertEq(IERC20(USDC).balanceOf(bob), 300e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        vm.prank(alice);
        assertEq(core.claimRewards(), 0);
        assertEq(core.claimable(alice), 0);
    }

    /// E-05.05: Tests claimable many and duplicate quote boundary.
    function test_E05_ClaimableManyAndDuplicateQuoteBoundary() public {
        _mintAndStake(alice, 2 ether);
        _mintAndStake(bob, 3 ether);
        _distribute(500e6);
        address[] memory unique = new address[](2);
        unique[0] = alice;
        unique[1] = bob;
        (uint256 total, uint256[] memory quotes) = core.claimableMany(unique);
        assertEq(total, 500e6);
        assertEq(quotes[0], 200e6);
        assertEq(quotes[1], 300e6);
        unique[1] = alice;
        (total, quotes) = core.claimableMany(unique);
        assertEq(total, 400e6);
        assertEq(quotes[0], 200e6);
        assertEq(quotes[1], 200e6);
        vm.prank(alice);
        assertEq(core.claimRewards(), 200e6);
        assertEq(core.claimable(alice), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 300e6);
    }

    /// E-05.06: Tests mixed shares stake transfer unstake accounting.
    function test_E05_MixedSharesStakeTransferUnstakeAccounting() public {
        _mintAndStake(alice, 100 ether);
        metro.mint(bob, 100 ether);
        core.setContributor(bob, true);
        vm.startPrank(bob);
        metro.approve(address(core), 100 ether);
        core.stakeContributor(100 ether, bob);
        vm.stopPrank();
        _distribute(200e6);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.claimable(bob), 100e6);
        vm.prank(alice);
        core.transfer(bob, 50 ether);
        vm.prank(bob);
        core.requestUnstake(20 ether);
        assertEq(core.claimable(alice), 100e6);
        assertEq(core.claimable(bob), 100e6);
        assertEq(core.totalShares(), 180 ether);
        assertEq(core.totalRewardWeight(), 180 ether);
        _distribute(180e6);
        assertEq(core.claimable(alice), 150e6);
        assertEq(core.claimable(bob), 230e6);
        assertEq(IERC20(USDC).balanceOf(address(core)), 380e6);
    }

    /// E-05.07: Tests zero weight and zero delta revert without funds loss.
    function test_E05_ZeroWeightAndZeroDeltaRevertWithoutFundsLoss() public {
        vm.expectRevert("RewardDistributor: zero amount");
        distributor.distribute(0);
        _fundUSDC(address(this), 2);
        IERC20(USDC).approve(address(distributor), 2);
        uint256 beforeOwner = IERC20(USDC).balanceOf(address(this));
        vm.expectRevert(xMETRO.InvalidConfiguration.selector);
        distributor.distribute(1);
        assertEq(IERC20(USDC).balanceOf(address(this)), beforeOwner);
        assertEq(IERC20(USDC).balanceOf(address(distributor)), 0);
        metro.setMinter(address(this), true);
        metro.mint(alice, 100_000_000 ether);
        vm.startPrank(alice);
        metro.approve(address(core), 100_000_000 ether);
        core.stake(100_000_000 ether);
        vm.stopPrank();
        assertEq(core.totalRewardWeight(), 100_000_000 ether);
        vm.expectRevert(xMETRO.InvalidAmount.selector);
        distributor.distribute(1);
        assertEq(IERC20(USDC).balanceOf(address(this)), beforeOwner);
        assertEq(IERC20(USDC).balanceOf(address(distributor)), 0);
        assertEq(IERC20(USDC).balanceOf(address(core)), 0);
        assertEq(core.accRewardPerShare(), 0);
    }

    /// E-05.07: Tests tiny rewards rounding and no overclaim.
    function test_E05_TinyRewardsRoundingAndNoOverclaim() public {
        address carol = makeAddr("carol");
        _mintAndStake(alice, 1 ether);
        _mintAndStake(bob, 1 ether);
        _mintAndStake(carol, 1 ether);
        _distribute(2);
        assertEq(core.claimable(alice), 0);
        assertEq(core.claimable(bob), 0);
        assertEq(core.claimable(carol), 0);
        vm.prank(alice);
        assertEq(core.claimRewards(), 0);
        vm.prank(alice);
        core.transfer(bob, 1 ether);
        assertEq(core.rewardDebt(alice), 0); // Fractional negative debt is truncated for display.
        vm.prank(bob);
        core.transfer(alice, 1 ether);
        _distribute(2);
        assertEq(core.claimable(alice), 1);
        assertEq(core.claimable(bob), 1);
        assertEq(core.claimable(carol), 1);
        vm.prank(alice);
        assertEq(core.claimRewards(), 1);
        vm.prank(bob);
        assertEq(core.claimRewards(), 1);
        vm.prank(carol);
        assertEq(core.claimRewards(), 1);
        assertEq(IERC20(USDC).balanceOf(address(core)), 1);
        vm.prank(alice);
        assertEq(core.claimRewards(), 0);
    }

    function _eventLog(Vm.Log[] memory logs, address emitter, bytes32 signature) private pure returns (Vm.Log memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == signature) {
                return logs[i];
            }
        }
        revert("expected event absent");
    }
}
