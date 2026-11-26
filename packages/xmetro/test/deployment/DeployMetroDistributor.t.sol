// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {stdJson} from "forge-std/StdJson.sol";

import {DeployMetroDistributor} from "../../script/DeployMetroDistributor.s.sol";
import {MetroDistributorBase} from "../../src/MetroDistributorBase.sol";
import {MetroDistributorV1} from "../../src/MetroDistributorV1.sol";
import {MetroDistributorV2} from "../../src/MetroDistributorV2.sol";
import {xMETRO as XMetroCore} from "../../src/xMETRO.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {MetroDistributorFixture} from "../mocks/MetroDistributorFixture.sol";
import {MockRateLimitedForwarder} from "../mocks/MockRateLimitedForwarder.sol";

contract DeployMetroDistributorTest is MetroDistributorFixture {
    using stdJson for string;

    uint256 internal constant DEPLOYER_KEY = 0xD3F10;

    address internal finalOwner = makeAddr("owner-safe");
    address internal treasury = makeAddr("treasury");
    address internal polVault = makeAddr("pol-vault");
    address internal operatorA = makeAddr("operator-a");
    address internal operatorB = makeAddr("operator-b");
    XMetroCore internal core;
    MockCommissionVault internal vault;
    MockRateLimitedForwarder internal forwarder;

    function setUp() public {
        _deployTokens();
        core = _deployCoreWithStaker(100 ether);
        vault = new MockCommissionVault(address(usdc), 50e6, makeAddr("old-distributor"));
        forwarder = new MockRateLimitedForwarder(address(usdc), makeAddr("old-distributor"));

        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.setEnv("DISTRIBUTOR_OWNER", vm.toString(finalOwner));
        vm.setEnv("DISTRIBUTOR_XMETRO", vm.toString(address(core)));
        vm.setEnv("DISTRIBUTOR_COMMISSION_VAULT", vm.toString(address(vault)));
        vm.setEnv("DISTRIBUTOR_FORWARDER", vm.toString(address(forwarder)));
        vm.setEnv("DISTRIBUTOR_TREASURY", vm.toString(treasury));
        vm.setEnv("DISTRIBUTOR_POL_VAULT", vm.toString(polVault));
        vm.setEnv("DISTRIBUTOR_MAX_COMMISSION_SPLIT_BPS", "1000");
        vm.setEnv("DISTRIBUTOR_OPERATORS", string.concat(vm.toString(operatorA), ",", vm.toString(operatorB)));
    }

    // vm.setEnv is process-wide; keep every scenario in one test so parallel tests cannot interleave env values.
    function test_DeploysBothVersionsAndOwnerBatchActivatesThem() public {
        vm.setEnv("DISTRIBUTOR_VERSION", "1");
        MockCommissionVault wrongVault = new MockCommissionVault(address(new ERC20Mintable("X", "X", 6)), 0, address(0));
        vm.setEnv("DISTRIBUTOR_COMMISSION_VAULT", vm.toString(address(wrongVault)));
        DeployMetroDistributor rejected = new DeployMetroDistributor();
        vm.expectRevert(bytes("DeployMetroDistributor: commission vault token mismatch"));
        rejected.run();
        vm.setEnv("DISTRIBUTOR_COMMISSION_VAULT", vm.toString(address(vault)));

        MetroDistributorV1 v1 = MetroDistributorV1(new DeployMetroDistributor().run());
        _assertDeployment(v1, 1);
        assertEq(v1.polVault(), polVault);
        assertEq(vm.readFile(_path(1)).readAddress(".polVault"), polVault);
        _executeOwnerBatch(v1);
        _distribute(v1);
        assertEq(usdc.balanceOf(address(vault)), 10e6);
        assertEq(usdc.balanceOf(polVault), 22_500_000);

        vm.setEnv("DISTRIBUTOR_VERSION", "2");
        MetroDistributorV2 v2 = MetroDistributorV2(new DeployMetroDistributor().run());
        _assertDeployment(v2, 2);
        assertEq(vm.readFile(_path(2)).readAddress(".polVault"), address(0));
        _executeOwnerBatch(v2);
        usdc.mint(address(forwarder), 100e6);
        vm.prank(operatorA);
        vm.expectRevert(MetroDistributorV2.BuybackNotImplemented.selector);
        v2.distribute(0);
        vm.prank(finalOwner);
        v2.setBucketBps(7_500, 2_500, 0);
        _distribute(v2);
    }

    function _assertDeployment(MetroDistributorBase distributor, uint256 version) internal view {
        assertEq(address(distributor.xMETRO()), address(core));
        assertEq(distributor.treasury(), treasury);
        assertEq(address(distributor.forwarder()), address(forwarder));
        assertTrue(distributor.operators(operatorA));
        assertTrue(distributor.operators(operatorB));
        assertEq(distributor.owner(), vm.addr(DEPLOYER_KEY));
        assertEq(distributor.pendingOwner(), finalOwner);

        string memory json = vm.readFile(_path(version));
        assertEq(json.readUint(".chainId"), block.chainid);
        assertEq(json.readUint(".version"), version);
        assertEq(json.readAddress(".distributor"), address(distributor));
        assertEq(json.readAddress(".xMETRO"), address(core));
        assertEq(json.readAddress(".plannedCommissionVault"), address(vault));
        assertEq(json.readAddress(".forwarder"), address(forwarder));
        assertEq(json.readAddress(".treasury"), treasury);
        assertEq(json.readAddress(".pendingOwner"), finalOwner);
        assertEq(json.readUint(".plannedMaxCommissionSplitBps"), 1_000);
    }

    function _executeOwnerBatch(MetroDistributorBase distributor) internal {
        vm.startPrank(finalOwner);
        distributor.acceptOwnership();
        vault.setDistributor(address(distributor));
        distributor.setCommissionVault(address(vault));
        distributor.setMaxCommissionSplitBps(1_000);
        vm.stopPrank();
        core.setRewardDistributor(address(distributor));
        forwarder.setRecipient(address(distributor));
    }

    function _distribute(MetroDistributorBase distributor) internal {
        usdc.mint(address(forwarder), 100e6);
        uint256 coreBefore = usdc.balanceOf(address(core));
        vm.prank(operatorA);
        distributor.distribute(0);
        assertGt(usdc.balanceOf(address(core)), coreBefore);
        assertEq(usdc.balanceOf(address(distributor)), 0);
    }

    function _path(uint256 version) internal view returns (string memory) {
        return string.concat(
            "deployments/", vm.toString(block.chainid), "/metro-distributor-v", vm.toString(version), ".json"
        );
    }
}
