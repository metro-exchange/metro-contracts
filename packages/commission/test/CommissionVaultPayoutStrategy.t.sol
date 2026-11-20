// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CommissionVault} from "../contracts/CommissionVault.sol";
import {ICommissionVault} from "../contracts/interfaces/ICommissionVault.sol";
import {ICommissionPayoutAdapter} from "../contracts/interfaces/ICommissionPayoutAdapter.sol";
import {MockToken, FakeXMetro, MockPayoutAdapter} from "./mocks/MockPayoutAdapter.sol";

contract CommissionVaultPayoutStrategyTest is Test {
    CommissionVault vault;
    MockToken usdc;
    MockToken metro;
    MockToken wbtc;
    FakeXMetro xMetro;
    MockPayoutAdapter adapter;

    address owner = address(this);
    address operator = makeAddr("operator");
    address guardian = makeAddr("guardian");
    address affiliate1 = makeAddr("affiliate1");
    address affiliate2 = makeAddr("affiliate2");
    address affiliate3 = makeAddr("affiliate3");

    bytes32 constant SWAP_METRO = keccak256("swapMetro");
    bytes32 constant AUTO_SWAP = keccak256("autoSwap");
    uint256 constant MIN_CLAIM = 50e6;

    string constant CODE_A = "CODE_A";
    string constant CODE_B = "CODE_B";
    string constant CODE_C = "CODE_C";
    bytes32 constant CODE_A_HASH = keccak256("CODE_A");
    bytes32 constant CODE_B_HASH = keccak256("CODE_B");

    function setUp() public {
        usdc = new MockToken("USDC");
        metro = new MockToken("METRO");
        wbtc = new MockToken("WBTC");
        xMetro = new FakeXMetro(metro);
        adapter = new MockPayoutAdapter(usdc);
        adapter.setStrategy(SWAP_METRO, ICommissionPayoutAdapter.StrategyKind.SwapMetro, address(metro));
        adapter.setStrategy(AUTO_SWAP, ICommissionPayoutAdapter.StrategyKind.AutoSwap, address(wbtc));

        vault = new CommissionVault(
            address(usdc), makeAddr("distributor"), operator, guardian, 1000e6, 10000e6, false, 1 hours, 1 hours
        );
        vault.setMinClaimAmount(MIN_CLAIM);
        vault.setDeFiAdapter(address(adapter), address(xMetro));
        vault.setPayoutStrategyAllowed(SWAP_METRO, true);
        vault.setPayoutStrategyAllowed(AUTO_SWAP, true);

        _settle(CODE_A, affiliate1, 100e6);
        _settle(CODE_B, affiliate2, 60e6);
        _settle(CODE_C, affiliate3, 30e6);
        usdc.mint(address(vault), 190e6);
    }

    // ── Helpers ─────────────────────────────────────────────

    function _settle(string memory code, address addr, uint256 amount) internal {
        string[] memory codes = new string[](1);
        codes[0] = code;
        address[] memory addrs = new address[](1);
        addrs[0] = addr;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(operator);
        vault.proposeSettlement(codes, addrs, amounts);
        vm.warp(block.timestamp + vault.settlementTimelock());
        vault.activateSettlement();
    }

    function _codes() internal pure returns (string[] memory codes) {
        codes = new string[](3);
        codes[0] = CODE_A;
        codes[1] = CODE_B;
        codes[2] = CODE_C;
    }

    function _one(string memory code) internal pure returns (string[] memory codes) {
        codes = new string[](1);
        codes[0] = code;
    }

    function _prefer(address affiliate, string memory code, bytes32 strategyId) internal {
        vm.prank(affiliate);
        vault.setPayoutStrategy(code, strategyId);
    }

    function _optInAll(bytes32 strategyId) internal {
        _prefer(affiliate1, CODE_A, strategyId);
        _prefer(affiliate2, CODE_B, strategyId);
        _prefer(affiliate3, CODE_C, strategyId);
    }

    function _convert(bytes32 strategyId, string[] memory codes) internal {
        vm.prank(operator);
        vault.convertEligible(strategyId, codes, 1, block.timestamp + 1, "route");
    }

    function _assertVaultHoldsNoOutput() internal view {
        assertEq(metro.balanceOf(address(vault)), 0);
        assertEq(xMetro.balanceOf(address(vault)), 0);
        assertEq(wbtc.balanceOf(address(vault)), 0);
        assertEq(metro.allowance(address(vault), address(xMetro)), 0);
    }

    // ── Owner setters ───────────────────────────────────────

    function test_setDeFiAdapter_onlyOwner() public {
        vm.prank(operator);
        vm.expectRevert("Not owner");
        vault.setDeFiAdapter(address(1), address(2));
    }

    function test_setDeFiAdapter_setsBothAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit ICommissionVault.DeFiAdapterSet(address(1), address(2));
        vault.setDeFiAdapter(address(1), address(2));
        assertEq(vault.deFiAdapter(), address(1));
        assertEq(vault.xMetro(), address(2));
    }

    function test_setPayoutStrategyAllowed_onlyOwner() public {
        vm.prank(operator);
        vm.expectRevert("Not owner");
        vault.setPayoutStrategyAllowed(SWAP_METRO, false);
    }

    function test_setPayoutStrategyAllowed_rejectsZeroId() public {
        vm.expectRevert("Zero strategy");
        vault.setPayoutStrategyAllowed(bytes32(0), true);
    }

    function test_setPayoutStrategyAllowed_emits() public {
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.PayoutStrategyAllowed(SWAP_METRO, false);
        vault.setPayoutStrategyAllowed(SWAP_METRO, false);
        assertFalse(vault.payoutStrategyAllowed(SWAP_METRO));
    }

    // ── Affiliate preference ────────────────────────────────

    function test_setPayoutStrategy_setsAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.PayoutStrategySet(CODE_A_HASH, SWAP_METRO);
        _prefer(affiliate1, CODE_A, SWAP_METRO);
        assertEq(vault.payoutStrategy(CODE_A_HASH), SWAP_METRO);
    }

    function test_setPayoutStrategy_wrongSender() public {
        vm.expectRevert("Wrong sender");
        _prefer(affiliate2, CODE_A, SWAP_METRO);
    }

    function test_setPayoutStrategy_unboundCode() public {
        vm.expectRevert("Code not on-chain yet");
        _prefer(affiliate1, "UNBOUND", SWAP_METRO);
    }

    function test_setPayoutStrategy_notAllowed() public {
        vm.expectRevert("Strategy not allowed");
        _prefer(affiliate1, CODE_A, keccak256("other"));
    }

    function test_setPayoutStrategy_paused() public {
        vm.prank(guardian);
        vault.pause();
        vm.expectRevert("Paused");
        _prefer(affiliate1, CODE_A, SWAP_METRO);
    }

    // ── Owner override ──────────────────────────────────────

    function test_ownerSetPayoutStrategy_onlyOwner() public {
        vm.prank(operator);
        vm.expectRevert("Not owner");
        vault.ownerSetPayoutStrategy(CODE_A, SWAP_METRO);
    }

    function test_ownerSetPayoutStrategy_notAllowed() public {
        vm.expectRevert("Strategy not allowed");
        vault.ownerSetPayoutStrategy(CODE_A, keccak256("other"));
    }

    function test_ownerSetPayoutStrategy_worksBeforeBind() public {
        vault.ownerSetPayoutStrategy("UNBOUND", SWAP_METRO);
        assertEq(vault.payoutStrategy(keccak256("UNBOUND")), SWAP_METRO);
    }

    function test_override_winsAndPreferenceResumesWhenCleared() public {
        _prefer(affiliate1, CODE_A, AUTO_SWAP);

        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.PayoutStrategyOverridden(CODE_A_HASH, SWAP_METRO);
        vault.ownerSetPayoutStrategy(CODE_A, SWAP_METRO);
        assertEq(vault.payoutStrategy(CODE_A_HASH), SWAP_METRO);

        _prefer(affiliate1, CODE_A, bytes32(0));
        assertEq(vault.payoutStrategy(CODE_A_HASH), SWAP_METRO);
        _prefer(affiliate1, CODE_A, AUTO_SWAP);

        vault.ownerSetPayoutStrategy(CODE_A, bytes32(0));
        assertEq(vault.payoutStrategy(CODE_A_HASH), AUTO_SWAP);
    }

    function test_dewhitelist_fallsBackToPreferenceThenUsdc() public {
        _prefer(affiliate1, CODE_A, AUTO_SWAP);
        vault.ownerSetPayoutStrategy(CODE_A, SWAP_METRO);

        vault.setPayoutStrategyAllowed(SWAP_METRO, false);
        assertEq(vault.payoutStrategy(CODE_A_HASH), AUTO_SWAP);

        vault.setPayoutStrategyAllowed(AUTO_SWAP, false);
        assertEq(vault.payoutStrategy(CODE_A_HASH), bytes32(0));

        vm.prank(affiliate1);
        vault.claim(CODE_A);
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    // ── USDC paths closed to strategy codes ─────────────────

    function test_claim_revertsForStrategyCode() public {
        _prefer(affiliate1, CODE_A, SWAP_METRO);
        vm.prank(affiliate1);
        vm.expectRevert("Paid in strategy");
        vault.claim(CODE_A);
    }

    function test_claim_reopensAfterSwitchBackToUsdc() public {
        _prefer(affiliate1, CODE_A, SWAP_METRO);
        _prefer(affiliate1, CODE_A, bytes32(0));
        vm.prank(affiliate1);
        vault.claim(CODE_A);
        assertEq(usdc.balanceOf(affiliate1), 100e6);
    }

    function test_distributeEligible_skipsStrategyCode() public {
        _prefer(affiliate1, CODE_A, SWAP_METRO);
        vm.prank(operator);
        vault.distributeEligible(_codes());
        assertEq(usdc.balanceOf(affiliate1), 0);
        assertEq(usdc.balanceOf(affiliate2), 60e6);
        assertEq(vault.totalClaimed(), 60e6);
    }

    function test_ownerDistribute_skipsStrategyCode() public {
        vault.ownerSetPayoutStrategy(CODE_B, SWAP_METRO);
        vault.ownerDistribute(_codes());
        assertEq(usdc.balanceOf(affiliate1), 100e6);
        assertEq(usdc.balanceOf(affiliate2), 0);
        assertEq(usdc.balanceOf(affiliate3), 30e6);
        assertEq(vault.totalClaimed(), 130e6);
    }

    // ── convertEligible: SwapMetro ──────────────────────────

    function test_convertEligible_swapMetro_paysXMetroProRata() public {
        _optInAll(SWAP_METRO);

        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CommissionClaimed(CODE_A_HASH, affiliate1, 100e6, 100e6);
        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CommissionClaimed(CODE_B_HASH, affiliate2, 60e6, 60e6);
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.CommissionsConverted(SWAP_METRO, address(metro), 2, 160e6, 160e18);
        _convert(SWAP_METRO, _codes());

        assertEq(xMetro.balanceOf(affiliate1), 100e18);
        assertEq(xMetro.balanceOf(affiliate2), 60e18);
        assertEq(xMetro.balanceOf(affiliate3), 0);
        assertEq(vault.claimed(CODE_A_HASH), 100e6);
        assertEq(vault.claimed(CODE_B_HASH), 60e6);
        assertEq(vault.totalClaimed(), 160e6);
        assertEq(vault.requiredReserve(), 30e6);
        assertEq(usdc.balanceOf(address(vault)), 30e6);
        _assertVaultHoldsNoOutput();
    }

    function test_convertEligible_swapMetro_remainderToLargest() public {
        _optInAll(SWAP_METRO);
        adapter.setRate(1, 3);
        _convert(SWAP_METRO, _codes());

        uint256 out = uint256(160e6) / 3;
        uint256 shareB = out * 60e6 / 160e6;
        assertEq(xMetro.balanceOf(affiliate2), shareB);
        assertEq(xMetro.balanceOf(affiliate1), out - shareB);
        assertGt(xMetro.balanceOf(affiliate1), out * 100e6 / 160e6);
        _assertVaultHoldsNoOutput();
    }

    function test_convertEligible_skipsIneligibleCodes() public {
        _optInAll(SWAP_METRO);
        _prefer(affiliate2, CODE_B, AUTO_SWAP);
        _settle("UNBOUND_PENDING", affiliate3, 80e6);
        vault.ownerSetPayoutStrategy("UNBOUND", SWAP_METRO);
        vault.ownerSetPayoutStrategy("UNBOUND_PENDING", SWAP_METRO);
        vault.ownerSetPayoutAddress("UNBOUND_PENDING", affiliate2);
        vm.prank(affiliate1);
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");

        string[] memory codes = new string[](5);
        codes[0] = CODE_A;
        codes[1] = CODE_B;
        codes[2] = CODE_C;
        codes[3] = "UNBOUND";
        codes[4] = "UNBOUND_PENDING";
        _convert(SWAP_METRO, codes);

        assertEq(adapter.calls(), 1);
        assertEq(vault.totalClaimed(), 100e6);
    }

    function test_convertEligible_onlyStrategyCodesConverted() public {
        _prefer(affiliate2, CODE_B, SWAP_METRO);
        _convert(SWAP_METRO, _codes());
        (address[] memory accounts, uint256[] memory amounts) = adapter.lastRequest();
        assertEq(accounts.length, 1);
        assertEq(accounts[0], affiliate2);
        assertEq(amounts[0], 60e6);
        assertEq(vault.claimed(CODE_A_HASH), 0);
    }

    function test_convertEligible_allSkipped_noAdapterCall() public {
        _convert(SWAP_METRO, _codes());
        assertEq(adapter.calls(), 0);
        assertEq(vault.totalClaimed(), 0);
    }

    // ── convertEligible: reverts ────────────────────────────

    function test_convertEligible_emptyBatch() public {
        vm.expectRevert("Empty batch");
        _convert(SWAP_METRO, new string[](0));
    }

    function test_convertEligible_batchTooLarge() public {
        string[] memory codes = new string[](vault.MAX_BATCH_SIZE() + 1);
        vm.expectRevert("Batch too large");
        _convert(SWAP_METRO, codes);
    }

    function test_convertEligible_zeroStrategy() public {
        vm.expectRevert("Zero strategy");
        _convert(bytes32(0), _codes());
    }

    function test_convertEligible_onlyOperator() public {
        vm.expectRevert("Not operator");
        vault.convertEligible(SWAP_METRO, _codes(), 1, block.timestamp + 1, "route");
    }

    function test_convertEligible_paused() public {
        vm.prank(guardian);
        vault.pause();
        vm.expectRevert("Paused");
        _convert(SWAP_METRO, _codes());
    }

    function test_convertEligible_noAdapter() public {
        _optInAll(SWAP_METRO);
        vault.setDeFiAdapter(address(0), address(0));
        vm.expectRevert("No adapter");
        _convert(SWAP_METRO, _codes());
    }

    function test_convertEligible_underfunded() public {
        _optInAll(SWAP_METRO);
        vm.prank(address(vault));
        usdc.transfer(owner, 100e6);
        vm.expectRevert();
        _convert(SWAP_METRO, _codes());
    }

    function test_convertEligible_slippageRevertRollsBackAccounting() public {
        _optInAll(SWAP_METRO);
        vm.prank(operator);
        vm.expectRevert("Slippage");
        vault.convertEligible(SWAP_METRO, _codes(), 160e18 + 1, block.timestamp + 1, "route");
        assertEq(vault.totalClaimed(), 0);
        assertEq(vault.claimed(CODE_A_HASH), 0);
        assertEq(usdc.balanceOf(address(vault)), 190e6);
    }

    function test_convertEligible_xMetroPaused() public {
        _optInAll(SWAP_METRO);
        xMetro.setPaused(true);
        vm.expectRevert("xMETRO paused");
        _convert(SWAP_METRO, _codes());
    }

    function test_convertEligible_reentrancyRejected() public {
        _optInAll(SWAP_METRO);
        adapter.setReenter(address(vault), abi.encodeCall(vault.claimConverted, (CODE_A, 1, 0, "")));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        _convert(SWAP_METRO, _codes());
    }

    // ── convertEligible: AutoSwap passthrough ───────────────

    function test_convertEligible_autoSwap_adapterPaysAccounts() public {
        _optInAll(AUTO_SWAP);

        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.CommissionsConverted(AUTO_SWAP, address(wbtc), 2, 160e6, 160e18);
        _convert(AUTO_SWAP, _codes());

        (address[] memory accounts, uint256[] memory amounts) = adapter.lastRequest();
        assertEq(accounts.length, 2);
        assertEq(accounts[0], affiliate1);
        assertEq(accounts[1], affiliate2);
        assertEq(amounts[0], 100e6);
        assertEq(amounts[1], 60e6);
        assertEq(wbtc.balanceOf(affiliate1), 100e18);
        assertEq(wbtc.balanceOf(affiliate2), 60e18);
        assertEq(vault.totalClaimed(), 160e6);
        _assertVaultHoldsNoOutput();
    }

    // ── claimConverted ──────────────────────────────────────

    function test_claimConverted_swapMetro() public {
        _prefer(affiliate1, CODE_A, SWAP_METRO);

        vm.expectEmit(true, true, false, true);
        emit ICommissionVault.CommissionClaimed(CODE_A_HASH, affiliate1, 100e6, 100e6);
        vm.expectEmit(true, false, false, true);
        emit ICommissionVault.CommissionsConverted(SWAP_METRO, address(metro), 1, 100e6, 100e18);
        vm.prank(affiliate1);
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");

        assertEq(xMetro.balanceOf(affiliate1), 100e18);
        assertEq(vault.totalClaimed(), 100e6);
        assertEq(vault.claimed(CODE_A_HASH), 100e6);
        _assertVaultHoldsNoOutput();
    }

    function test_claimConverted_autoSwap() public {
        vault.ownerSetPayoutStrategy(CODE_A, AUTO_SWAP);
        vm.prank(affiliate1);
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");
        assertEq(wbtc.balanceOf(affiliate1), 100e18);
        assertEq(vault.totalClaimed(), 100e6);
        _assertVaultHoldsNoOutput();
    }

    function test_claimConverted_wrongSender() public {
        _prefer(affiliate1, CODE_A, SWAP_METRO);
        vm.prank(affiliate2);
        vm.expectRevert("Wrong sender");
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");
    }

    function test_claimConverted_usdcCode() public {
        vm.prank(affiliate1);
        vm.expectRevert("Paid in USDC");
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");
    }

    function test_claimConverted_nothingOwed() public {
        _prefer(affiliate1, CODE_A, SWAP_METRO);
        vm.startPrank(affiliate1);
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");
        vm.expectRevert("Nothing to claim");
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");
        vm.stopPrank();
    }

    function test_claimConverted_belowMinimum() public {
        _prefer(affiliate3, CODE_C, SWAP_METRO);
        vm.prank(affiliate3);
        vm.expectRevert("Below minimum claim");
        vault.claimConverted(CODE_C, 1, block.timestamp + 1, "route");
    }

    function test_claimConverted_reentrancyRejected() public {
        _prefer(affiliate1, CODE_A, SWAP_METRO);
        adapter.setReenter(address(vault), abi.encodeCall(vault.claimConverted, (CODE_A, 1, 0, "")));
        vm.prank(affiliate1);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.claimConverted(CODE_A, 1, block.timestamp + 1, "route");
    }
}
