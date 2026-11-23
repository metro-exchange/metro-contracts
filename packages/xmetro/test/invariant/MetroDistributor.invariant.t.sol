// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {MetroToken} from "../../src/metro.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {MetroDistributorBase} from "../../src/MetroDistributorBase.sol";
import {MetroDistributorV1} from "../../src/MetroDistributorV1.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {MockRateLimitedForwarder} from "../mocks/MockRateLimitedForwarder.sol";
import {MetroDistributorV2Harness} from "../mocks/MetroDistributorV2Harness.sol";

contract MetroDistributorInvariantTest is StdInvariant, Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ERC20Mintable internal usdc;
    MetroToken internal metro;
    xMETRO internal coreV1;
    xMETRO internal coreV2;
    MetroDistributorV1 internal v1;
    MetroDistributorV2Harness internal v2;
    MockCommissionVault internal vault;
    MockRateLimitedForwarder internal forwarderV1;
    MockRateLimitedForwarder internal forwarderV2;
    MetroDistributorHandler internal handler;

    address internal treasuryV1 = makeAddr("treasuryV1");
    address internal treasuryV2 = makeAddr("treasuryV2");
    address internal polVault = makeAddr("polVault");
    address internal swapSink = makeAddr("swapSink");

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        coreV1 = _core();
        coreV2 = _core();

        v1 = new MetroDistributorV1(address(coreV1), treasuryV1, polVault, address(this));
        v2 = new MetroDistributorV2Harness(address(coreV2), treasuryV2, address(this), swapSink);
        coreV1.setRewardDistributor(address(v1));
        coreV2.setRewardDistributor(address(v2));
        vault = new MockCommissionVault(address(usdc), 0, address(v1));
        v1.setCommissionVault(address(vault));
        forwarderV1 = new MockRateLimitedForwarder(address(usdc), address(v1));
        forwarderV2 = new MockRateLimitedForwarder(address(usdc), address(v2));
        v1.setForwarder(address(forwarderV1));
        v2.setForwarder(address(forwarderV2));

        handler = new MetroDistributorHandler(v1, v2, usdc, metro, vault, forwarderV1, forwarderV2);
        usdc.transferOwnership(address(handler));
        metro.setMinter(address(handler), true);
        _handOver(v1);
        _handOver(v2);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.inject.selector;
        selectors[1] = handler.setReleasable.selector;
        selectors[2] = handler.setCommission.selector;
        selectors[3] = handler.setBucketBps.selector;
        selectors[4] = handler.distributeV1.selector;
        selectors[5] = handler.distributeV2.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _core() internal returns (xMETRO core) {
        core = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);
        address staker = makeAddr("staker");
        metro.mint(staker, 1 ether);
        vm.startPrank(staker);
        metro.approve(address(core), 1 ether);
        core.stake(1 ether);
        vm.stopPrank();
    }

    function _handOver(MetroDistributorBase distributor) internal {
        distributor.setOperator(address(handler), true);
        distributor.transferOwnership(address(handler));
        vm.prank(address(handler));
        distributor.acceptOwnership();
    }

    function invariant_V1UsdcIsNeverCreatedOrLost() public view {
        assertEq(
            usdc.balanceOf(address(coreV1)) + usdc.balanceOf(address(vault)) + usdc.balanceOf(treasuryV1)
                + usdc.balanceOf(polVault) + usdc.balanceOf(address(v1)) + usdc.balanceOf(address(forwarderV1)),
            handler.injectedV1()
        );
    }

    function invariant_V2UsdcIsNeverCreatedOrLost() public view {
        assertEq(
            usdc.balanceOf(address(coreV2)) + usdc.balanceOf(treasuryV2) + usdc.balanceOf(swapSink)
                + usdc.balanceOf(address(v2)) + usdc.balanceOf(address(forwarderV2)),
            handler.injectedV2()
        );
    }

    function invariant_NoResidualAllowanceToXMetro() public view {
        assertEq(usdc.allowance(address(v1), address(coreV1)), 0);
        assertEq(usdc.allowance(address(v2), address(coreV2)), 0);
    }

    function invariant_BurnedMetroEqualsBoughtMetro() public view {
        assertEq(metro.balanceOf(DEAD), handler.totalMetroBought());
    }
}

contract MetroDistributorHandler is Test {
    MetroDistributorV1 internal immutable v1;
    MetroDistributorV2Harness internal immutable v2;
    ERC20Mintable internal immutable usdc;
    MetroToken internal immutable metro;
    MockCommissionVault internal immutable vault;
    MockRateLimitedForwarder internal immutable forwarderV1;
    MockRateLimitedForwarder internal immutable forwarderV2;

    uint256 public injectedV1;
    uint256 public injectedV2;
    uint256 public totalMetroBought;

    constructor(
        MetroDistributorV1 v1_,
        MetroDistributorV2Harness v2_,
        ERC20Mintable usdc_,
        MetroToken metro_,
        MockCommissionVault vault_,
        MockRateLimitedForwarder forwarderV1_,
        MockRateLimitedForwarder forwarderV2_
    ) {
        v1 = v1_;
        v2 = v2_;
        usdc = usdc_;
        metro = metro_;
        vault = vault_;
        forwarderV1 = forwarderV1_;
        forwarderV2 = forwarderV2_;
    }

    function inject(uint96 amountSeed, bool toV2, bool viaForwarder) external {
        uint256 amount = bound(uint256(amountSeed), 1, 1_000_000e6);
        address target = toV2
            ? (viaForwarder ? address(forwarderV2) : address(v2))
            : (viaForwarder ? address(forwarderV1) : address(v1));
        usdc.mint(target, amount);
        if (toV2) injectedV2 += amount;
        else injectedV1 += amount;
    }

    function setReleasable(uint96 seed, bool toV2) external {
        (toV2 ? forwarderV2 : forwarderV1).setReleasable(bound(uint256(seed), 0, 1_000_000e6));
    }

    function setCommission(uint16 bpsSeed, uint96 targetSeed) external {
        vault.setTargetBalance(bound(uint256(targetSeed), 0, 10_000_000e6));
        v1.setMaxCommissionSplitBps(uint16(bound(uint256(bpsSeed), 0, 10_000)));
    }

    function setBucketBps(uint16 treasurySeed, uint16 buybackSeed) external {
        uint16 treasuryBps = uint16(bound(uint256(treasurySeed), 0, 10_000));
        uint16 buybackBps = uint16(bound(uint256(buybackSeed), 0, 10_000 - treasuryBps));
        v2.setBucketBps(10_000 - treasuryBps - buybackBps, treasuryBps, buybackBps);
    }

    function distributeV1(uint96 maxSeed) external {
        v1.distribute(bound(uint256(maxSeed), 0, 2_000_000e6));
    }

    function distributeV2(uint96 maxSeed, uint96 metroOutSeed) external {
        uint256 metroOut = bound(uint256(metroOutSeed), 1, 1_000 ether);
        v2.setMetroOut(metroOut);
        metro.mint(address(v2), metroOut);
        uint256 metroBefore = metro.balanceOf(address(v2));
        v2.distribute(bound(uint256(maxSeed), 0, 2_000_000e6));
        if (metro.balanceOf(address(v2)) < metroBefore) totalMetroBought += metroOut;
    }
}
