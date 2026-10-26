// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetroToken} from "../../src/metro.sol";
import {xMETRO} from "../../src/xMETRO.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";

contract RewardDistributorInvariantTest is StdInvariant, Test {
    ERC20Mintable internal usdc;
    MetroToken internal metro;
    xMETRO internal xmetro;
    RewardDistributor internal distributor;
    MockCommissionVault internal vault;
    RewardDistributorHandler internal handler;

    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        metro = new MetroToken("METRO", "METRO", address(this));
        metro.setMinter(address(this), true);
        xmetro = new xMETRO(address(this), address(metro), address(usdc), makeAddr("forfeiture"), 20_000);
        distributor = new RewardDistributor(address(xmetro), address(this));
        vault = new MockCommissionVault(address(usdc), 0, address(distributor));

        xmetro.setRewardDistributor(address(distributor));

        address staker = makeAddr("staker");
        metro.mint(staker, 1 ether);
        vm.prank(staker);
        metro.approve(address(xmetro), 1 ether);
        vm.prank(staker);
        xmetro.stake(1 ether);
        distributor.setCommissionVault(address(vault));

        handler = new RewardDistributorHandler(distributor, xmetro, usdc, vault);
        distributor.setOperator(address(handler), true);
        distributor.transferOwnership(address(handler));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.distribute.selector;
        selectors[1] = handler.increaseVaultTarget.selector;
        selectors[2] = handler.setBps.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_GrossAlwaysEqualsCommissionPlusNet() public view {
        assertEq(handler.totalGross(), handler.totalCommission() + handler.totalNet());
    }

    function invariant_RoutedTokenBalancesMatchAccountingAndDistributorRetainsNothing() public view {
        assertEq(usdc.balanceOf(address(vault)), handler.totalCommission());
        assertEq(usdc.balanceOf(address(xmetro)), handler.totalNet());
        assertEq(usdc.balanceOf(address(distributor)), 0);
        assertEq(usdc.allowance(address(distributor), address(xmetro)), 0);
    }

    function invariant_VaultIsNeverFundedAboveItsNondecreasingTarget() public view {
        assertLe(usdc.balanceOf(address(vault)), vault.targetBalance());
    }
}

contract RewardDistributorHandler is Test {
    RewardDistributor internal immutable distributor;
    xMETRO internal immutable xmetro;
    ERC20Mintable internal immutable usdc;
    MockCommissionVault internal immutable vault;

    uint256 public totalGross;
    uint256 public totalCommission;
    uint256 public totalNet;

    constructor(RewardDistributor distributor_, xMETRO xmetro_, ERC20Mintable usdc_, MockCommissionVault vault_) {
        distributor = distributor_;
        xmetro = xmetro_;
        usdc = usdc_;
        vault = vault_;
        usdc.approve(address(distributor_), type(uint256).max);
    }

    function setBps(uint16 seed) external {
        distributor.setMaxCommissionSplitBps(uint16(bound(uint256(seed), 0, 10_000)));
    }

    function increaseVaultTarget(uint96 seed) external {
        uint256 increase = bound(uint256(seed), 0, 1_000_000e6);
        vault.setTargetBalance(vault.targetBalance() + increase);
    }

    function distribute(uint96 grossSeed, bool fromBalance) external {
        uint256 gross = bound(uint256(grossSeed), 1, 1_000_000e6);
        uint256 shortfallBefore = vault.requiredTopUp();
        uint256 cap = Math.mulDiv(gross, distributor.maxCommissionSplitBps(), 10_000);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 xmetroBefore = usdc.balanceOf(address(xmetro));

        if (fromBalance) {
            usdc.mint(address(distributor), gross);
            distributor.distributeFromBalance(gross);
        } else {
            usdc.mint(address(this), gross);
            distributor.distribute(gross);
        }

        uint256 commission = usdc.balanceOf(address(vault)) - vaultBefore;
        uint256 net = usdc.balanceOf(address(xmetro)) - xmetroBefore;
        assertEq(commission, Math.min(cap, shortfallBefore));
        assertLe(commission, cap);
        assertLe(commission, shortfallBefore);
        assertEq(gross, commission + net);

        totalGross += gross;
        totalCommission += commission;
        totalNet += net;
    }
}
