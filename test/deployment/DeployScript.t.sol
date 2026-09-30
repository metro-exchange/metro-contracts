// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockAaveV4Giver} from "../mocks/MockAaveV4Giver.sol";

import {stdJson} from "forge-std/StdJson.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {UpgradeDeFiAdapter} from "../../script/UpgradeDeFiAdapter.s.sol";
import {ReplaceDeFiAdapter} from "../../script/ReplaceDeFiAdapter.s.sol";
import {VerifyDeployment} from "../../script/VerifyDeployment.s.sol";
import {IXMetroDeFiAdapterAdmin} from "../../script/DeFiAdapterScriptBase.sol";
import {RewardDistributor} from "../../src/RewardDistributor.sol";
import {MetroToken} from "../../src/metro.sol";
import {xMETRO as XMetroCore} from "../../src/xMETRO.sol";
import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";
import {ERC20Mintable} from "../mocks/ERC20Mintable.sol";
import {MockSyrupUSDC} from "../mocks/MockSyrupUSDC.sol";
import {MockCommissionVault} from "../mocks/MockCommissionVault.sol";
import {
    MockAaveV3Pool,
    MockAaveV4Spoke,
    MockPoolPermissionManager,
    MockSyrupRouter
} from "../mocks/MockDepositProtocols.sol";

contract DeployScriptTest is Test {
    using stdJson for string;

    uint256 internal constant DEPLOYER_KEY = 0xD3F10;
    uint256 internal constant ADAPTER_RUNTIME = 20_487;
    uint256 internal constant CORE_RUNTIME = 22_514;
    bytes32 internal constant P_DEPOSIT = bytes32("P:deposit");
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    bytes32 internal constant ADAPTER_FAMILY_ID = keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    bytes32 internal constant ADAPTER_STORAGE_NAMESPACE =
        0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;

    address internal finalOwner;
    ERC20Mintable internal usdc;
    ERC20Mintable internal usdt;
    ERC20Mintable internal wbtc;
    ERC20Mintable internal gho;
    ERC20Mintable internal xaut;
    MockSyrupUSDC internal syrupUsdc;
    ERC20Mintable internal thor;
    ERC20Mintable internal yThor;
    MockAaveV3Pool internal aaveV3;
    MockAaveV4Spoke internal aaveV4;
    MockAaveV4Giver internal giver;
    MockPoolPermissionManager internal permissions;
    MockSyrupRouter internal mapleRouter;
    Deploy internal deployScript;

    function setUp() public {
        finalOwner = makeAddr("final-multisig");
        usdc = new ERC20Mintable("USDC", "USDC", 6);
        usdt = new ERC20Mintable("USDT", "USDT", 6);
        wbtc = new ERC20Mintable("WBTC", "WBTC", 8);
        gho = new ERC20Mintable("GHO", "GHO", 18);
        xaut = new ERC20Mintable("XAUT", "XAUT", 6);
        syrupUsdc = new MockSyrupUSDC(address(usdc));
        thor = new ERC20Mintable("THOR", "THOR", 18);
        yThor = new ERC20Mintable("yTHOR", "yTHOR", 18);
        aaveV3 = new MockAaveV3Pool(address(usdc), 11e26);
        aaveV4 = new MockAaveV4Spoke(address(usdc), 7);
        giver = new MockAaveV4Giver(address(aaveV4));
        aaveV4.updatePositionManager(address(giver), true);
        permissions = new MockPoolPermissionManager();
        mapleRouter =
            new MockSyrupRouter(address(usdc), address(syrupUsdc), address(permissions), makeAddr("maple-admin"));
        syrupUsdc.configureMock(address(mapleRouter), address(permissions));
        permissions.setPermissionAdmin(makeAddr("maple-admin"), true);
        permissions.setPermissionAdmin(address(mapleRouter), true);
        permissions.setPoolBitmap(address(mapleRouter), P_DEPOSIT, 16);
        permissions.setLenderBitmap(address(mapleRouter), 16);
        _setRequiredEnvironment();
        deployScript = new Deploy();
    }

    // vm.setEnv changes process-wide state; keep deployment scenarios in one test so Forge's
    // parallel test execution cannot mix chain addresses, signer keys, or approved hashes.
    function test_DeploymentScriptAndPreflight() public {
        uint256 initialState = vm.snapshotState();
        _artifactHashMustBeApproved();
        _restore(initialState);
        _duplicateSwapOutputFailsBeforeAnyDeployment();
        _restore(initialState);
        _mismatchedDeployerFailsBeforeAnyDeployment();
        _restore(initialState);
        _noSwapRoutersDeploysWithSwapDisabled();
        _restore(initialState);
        _optionalSwapOutputsCanBeSkipped();
        _restore(initialState);
        _wrongChainIdFailsBeforeAnyDeployment();
        _restore(initialState);
        _fullDryRunUsesReleaseArtifactsAndReadsEveryBinding();
    }

    function _fullDryRunUsesReleaseArtifactsAndReadsEveryBinding() private {
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        uint256 startingNonce = vm.getNonce(vm.addr(DEPLOYER_KEY));
        address predictedDistributor = vm.computeCreateAddress(vm.addr(DEPLOYER_KEY), startingNonce + 4);
        MockCommissionVault configuredVault = new MockCommissionVault(address(usdc), 100e6, predictedDistributor);
        _set("COMMISSION_VAULT", address(configuredVault));
        _set("MAX_COMMISSION_SPLIT_BPS", 1_000);
        deployScript.run();
        vm.setEnv("DEPLOYMENT_JSON", _deploymentPath());
        new VerifyDeployment().run();

        string memory json = vm.readFile(_deploymentPath());
        address deployer = vm.addr(DEPLOYER_KEY);
        MetroToken metro = MetroToken(json.readAddress(".metro"));
        XMetroCore core = XMetroCore(json.readAddress(".xMETRO"));
        address implementation = json.readAddress(".deFiAdapterImplementation");
        address proxy = json.readAddress(".deFiAdapterProxy");
        IXMetroDeFiAdapterAdmin adapter = IXMetroDeFiAdapterAdmin(proxy);
        RewardDistributor distributor = RewardDistributor(json.readAddress(".rewardDistributor"));

        assertEq(json.readUint(".chainId"), block.chainid);
        assertEq(json.readUint(".deploymentNonce"), startingNonce);
        assertEq(json.readBytes32(".metroCodehash"), address(metro).codehash);
        assertEq(json.readBytes32(".xMetroCodehash"), address(core).codehash);
        assertEq(
            json.readBytes32(".adapterInitcodeHash"),
            _artifactInitcodeHash("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json")
        );
        assertEq(address(metro), vm.computeCreateAddress(deployer, startingNonce));
        assertEq(address(core), vm.computeCreateAddress(deployer, startingNonce + 1));
        assertEq(implementation, vm.computeCreateAddress(deployer, startingNonce + 2));
        assertEq(proxy, vm.computeCreateAddress(deployer, startingNonce + 3));
        assertEq(implementation.code.length, ADAPTER_RUNTIME);
        assertEq(address(core).code.length, CORE_RUNTIME);
        assertEq(json.readBytes32(".deFiAdapterImplementationCodehash"), implementation.codehash);
        assertEq(json.readAddress(".proxyImplementationReadback"), implementation);
        assertEq(json.readBytes32(".proxyImplementationSlot"), IMPLEMENTATION_SLOT);
        assertEq(json.readBytes32(".proxyAdminSlotValue"), bytes32(0));
        assertEq(json.readBytes32(".proxyBeaconSlotValue"), bytes32(0));
        assertEq(json.readBytes32(".adapterFamilyId"), ADAPTER_FAMILY_ID);
        assertEq(json.readBytes32(".adapterStorageNamespace"), ADAPTER_STORAGE_NAMESPACE);
        assertEq(json.readUint(".adapterEpoch"), 1);
        assertEq(vm.load(proxy, IMPLEMENTATION_SLOT), bytes32(uint256(uint160(implementation))));
        assertEq(vm.load(proxy, ADMIN_SLOT), bytes32(0));
        assertEq(vm.load(proxy, BEACON_SLOT), bytes32(0));

        assertEq(core.owner(), finalOwner);
        assertFalse(core.paused());
        assertEq(core.deFiAdapter(), proxy);
        assertEq(core.deFiAdapterEpoch(), 1);
        assertEq(core.rewardDistributor(), address(distributor));
        assertEq(metro.owner(), finalOwner);
        assertTrue(metro.isMinter(address(core)));
        assertFalse(metro.isMinter(deployer));
        assertFalse(metro.isMinter(finalOwner));
        assertEq(distributor.owner(), finalOwner);
        assertEq(json.readBytes32(".rewardDistributorCodehash"), address(distributor).codehash);
        assertEq(json.readBytes32(".escrowCodehash"), json.readAddress(".escrow").codehash);
        assertEq(distributor.commissionVault(), address(configuredVault));
        assertEq(distributor.maxCommissionSplitBps(), 1_000);
        assertEq(json.readAddress(".commissionVault"), address(configuredVault));
        assertEq(json.readAddress(".commissionVaultUsdc"), address(usdc));
        assertEq(json.readAddress(".commissionVaultDistributor"), address(distributor));
        assertEq(json.readBytes32(".commissionVaultCodehash"), address(configuredVault).codehash);
        assertTrue(json.readBool(".commissionVaultMigrationFinalized"));
        assertFalse(json.readBool(".commissionVaultPaused"));
        assertEq(metro.cap(), 100_000_000 ether);
        assertEq(json.readUint(".metroMaxSupply"), 100_000_000 ether);
        assertEq(json.readUint(".yThorRewardWeightBps"), 17_500);

        assertEq(adapter.xMETRO(), address(core));
        assertEq(adapter.USDC(), address(usdc));
        assertEq(adapter.METRO(), address(metro));
        assertEq(adapter.logicEpoch(), 1);
        assertEq(adapter.implementationVersion(), 1);
        assertEq(json.readAddress(".routerV2"), address(usdt));
        assertEq(json.readAddress(".routerV3"), address(wbtc));
        assertEq(json.readAddress(".oneInchRouter"), address(gho));

        _assertStrategy(adapter, json.readBytes32(".swapMetroStrategyId"), IXMetroDeFiAdapter.StrategyKind.SwapMetro);
        _assertStrategy(adapter, json.readBytes32(".swapUsdtStrategyId"), IXMetroDeFiAdapter.StrategyKind.AutoSwap);
        _assertStrategy(adapter, json.readBytes32(".swapWbtcStrategyId"), IXMetroDeFiAdapter.StrategyKind.AutoSwap);
        _assertStrategy(adapter, json.readBytes32(".swapGhoStrategyId"), IXMetroDeFiAdapter.StrategyKind.AutoSwap);
        _assertStrategy(adapter, json.readBytes32(".swapXautStrategyId"), IXMetroDeFiAdapter.StrategyKind.AutoSwap);
        _assertStrategy(adapter, json.readBytes32(".swapSyrupUsdcStrategyId"), IXMetroDeFiAdapter.StrategyKind.AutoSwap);
        _assertStrategy(adapter, json.readBytes32(".aaveV3StrategyId"), IXMetroDeFiAdapter.StrategyKind.AaveV3);
        _assertStrategy(adapter, json.readBytes32(".aaveV4StrategyId"), IXMetroDeFiAdapter.StrategyKind.AaveV4);
        _assertStrategy(adapter, json.readBytes32(".mapleStrategyId"), IXMetroDeFiAdapter.StrategyKind.Maple);

        assertEq(json.readAddress(".aaveV3Pool"), address(aaveV3));
        assertEq(json.readAddress(".aaveV3AUsdc"), address(aaveV3.aUsdc()));
        assertEq(json.readUint(".aaveV3ReferralCode"), 42);
        assertEq(json.readAddress(".aaveV4Spoke"), address(aaveV4));
        assertEq(json.readAddress(".aaveV4Giver"), address(giver));
        assertEq(json.readUint(".aaveV4UsdcReserveId"), 7);
        assertEq(json.readAddress(".mapleSyrupRouter"), address(mapleRouter));
        assertEq(json.readAddress(".mapleSyrupUsdc"), address(syrupUsdc));
        assertEq(json.readBytes32(".mapleDepositData"), bytes32(0));

        assertEq(IXMetroDeFiAdapter(implementation).xMETRO(), address(0));
        assertEq(usdc.balanceOf(implementation), 0);
        assertEq(usdc.allowance(address(core), proxy), 0);
        assertEq(usdc.allowance(proxy, address(aaveV3)), 0);
        assertEq(usdc.allowance(proxy, address(aaveV4)), 0);
        assertEq(usdc.allowance(proxy, address(giver)), 0);
        assertEq(usdc.allowance(proxy, address(mapleRouter)), 0);

        _set("XMETRO", address(core));
        assertEq(core.owner(), finalOwner);
        assertFalse(core.paused());

        address implementationDeployer = makeAddr("implementation-deployer");
        _set("XMETRO", address(core));
        _set("DEFI_ADAPTER_PROXY", proxy);
        _set("UPGRADE_CALLER", finalOwner);
        _set("IMPLEMENTATION_DEPLOYER", implementationDeployer);
        _set("UPGRADE_CALLER_PRIVATE_KEY", 0);
        _set("IMPLEMENTATION_DEPLOYER_PRIVATE_KEY", 0);
        vm.setEnv("NEW_ADAPTER_ARTIFACT", "out-adapter/XMetroDeFiAdapterV2.sol/XMetroDeFiAdapterV2.json");
        vm.setEnv("DEPLOYMENT_JSON", _deploymentPath());
        vm.setEnv("ADAPTER_MIGRATION_DATA", "0x");
        UpgradeDeFiAdapter upgradeScript = new UpgradeDeFiAdapter();
        vm.setEnv("EXPECTED_NEW_IMPLEMENTATION_INITCODE_HASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert("Upgrade: artifact initcode hash");
        upgradeScript.run();
        vm.setEnv(
            "EXPECTED_NEW_IMPLEMENTATION_INITCODE_HASH",
            vm.toString(_artifactInitcodeHash("out-adapter/XMetroDeFiAdapterV2.sol/XMetroDeFiAdapterV2.json"))
        );

        address predictedV2 = vm.computeCreateAddress(implementationDeployer, 0);
        upgradeScript.run();
        string memory upgradeJson =
            vm.readFile(string.concat("deployments/", vm.toString(block.chainid), "/adapter-upgrade.json"));
        assertEq(upgradeJson.readAddress(".proxy"), proxy);
        assertEq(upgradeJson.readAddress(".oldImplementation"), implementation);
        assertEq(upgradeJson.readAddress(".newImplementation"), predictedV2);
        assertEq(predictedV2.code.length, ADAPTER_RUNTIME);
        assertEq(adapter.logicEpoch(), 2);
        assertEq(adapter.implementationVersion(), 2);
        assertEq(upgradeJson.readUint(".oldLogicEpoch"), 1);
        assertEq(upgradeJson.readUint(".newLogicEpoch"), 2);
        assertEq(upgradeJson.readUint(".oldImplementationVersion"), 1);
        assertEq(upgradeJson.readUint(".newImplementationVersion"), 2);
        assertEq(core.deFiAdapter(), proxy);
        assertFalse(core.paused());
        {
            string memory activeAddresses = vm.readFile(_deploymentPath());
            assertEq(activeAddresses.readAddress(".deFiAdapterImplementation"), predictedV2);
            assertEq(activeAddresses.readBytes32(".deFiAdapterImplementationCodehash"), predictedV2.codehash);
            assertEq(activeAddresses.readAddress(".proxyImplementationReadback"), predictedV2);
            assertEq(activeAddresses.readUint(".adapterEpoch"), 1);
            assertEq(activeAddresses.readUint(".adapterLogicEpoch"), 2);
            assertEq(activeAddresses.readUint(".adapterImplementationVersion"), 2);
        }

        bytes32 disabledAaveV3Id = vm.readFile(_deploymentPath()).readBytes32(".aaveV3StrategyId");
        aaveV3.setGetterRevert(true);
        vm.prank(finalOwner);
        adapter.setAaveV3Config(address(0), address(0), 0, false, false);
        assertFalse(adapter.strategyInfo(disabledAaveV3Id).enabled);

        address replacementDeployer = makeAddr("replacement-deployer");
        _set("DEFI_ADAPTER_PROXY", proxy);
        _set("REPLACEMENT_CALLER", finalOwner);
        _set("REPLACEMENT_DEPLOYER", replacementDeployer);
        _set("REPLACEMENT_CALLER_PRIVATE_KEY", 0);
        _set("REPLACEMENT_DEPLOYER_PRIVATE_KEY", 0);
        vm.setEnv("REPLACEMENT_ADAPTER_ARTIFACT", "out-adapter/XMetroDeFiAdapterV2.sol/XMetroDeFiAdapterV2.json");
        vm.setEnv(
            "EXPECTED_REPLACEMENT_IMPLEMENTATION_INITCODE_HASH",
            vm.toString(_artifactInitcodeHash("out-adapter/XMetroDeFiAdapterV2.sol/XMetroDeFiAdapterV2.json"))
        );
        vm.setEnv(
            "SWAP_OUTPUT_TOKENS",
            string.concat(
                vm.toString(address(usdt)),
                ",",
                vm.toString(address(wbtc)),
                ",",
                vm.toString(address(gho)),
                ",",
                vm.toString(address(xaut)),
                ",",
                vm.toString(address(syrupUsdc))
            )
        );
        address predictedReplacementImplementation = vm.computeCreateAddress(replacementDeployer, 0);
        address predictedReplacementProxy = vm.computeCreateAddress(replacementDeployer, 1);
        ReplaceDeFiAdapter replacementScript = new ReplaceDeFiAdapter();
        vm.expectRevert("Replace: core must be paused");
        replacementScript.run();
        vm.prank(finalOwner);
        core.pause();
        vm.setEnv("EXPECTED_REPLACEMENT_IMPLEMENTATION_INITCODE_HASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert("Replace: artifact initcode hash");
        replacementScript.run();
        vm.setEnv(
            "EXPECTED_REPLACEMENT_IMPLEMENTATION_INITCODE_HASH",
            vm.toString(_artifactInitcodeHash("out-adapter/XMetroDeFiAdapterV2.sol/XMetroDeFiAdapterV2.json"))
        );
        replacementScript.run();

        string memory replacementJson =
            vm.readFile(string.concat("deployments/", vm.toString(block.chainid), "/adapter-replacement.json"));
        assertEq(replacementJson.readAddress(".oldProxy"), proxy);
        assertEq(replacementJson.readAddress(".newProxy"), predictedReplacementProxy);
        assertEq(replacementJson.readAddress(".newImplementation"), predictedReplacementImplementation);
        assertEq(replacementJson.readUint(".oldAdapterEpoch"), 1);
        assertEq(replacementJson.readUint(".newAdapterEpoch"), 2);
        assertFalse(replacementJson.readBool(".requiresAaveV4Reauthorization"));
        assertTrue(replacementJson.readBool(".requiresMapleReauthorization"));
        assertEq(core.deFiAdapter(), predictedReplacementProxy);
        assertEq(core.deFiAdapterEpoch(), 2);
        assertTrue(core.paused());
        IXMetroDeFiAdapterAdmin replacementAdapter = IXMetroDeFiAdapterAdmin(predictedReplacementProxy);
        assertEq(replacementAdapter.logicEpoch(), 1);
        assertEq(replacementAdapter.implementationVersion(), 2);
        assertEq(replacementAdapter.xMETRO(), address(core));
        _assertAaveV3Cleared(replacementAdapter);
        assertFalse(replacementAdapter.strategyInfo(disabledAaveV3Id).enabled);
        assertEq(usdc.allowance(address(core), proxy), 0);
        assertEq(usdc.allowance(address(core), predictedReplacementProxy), 0);
        {
            string memory activeAddresses = vm.readFile(_deploymentPath());
            assertEq(activeAddresses.readAddress(".deFiAdapterProxy"), predictedReplacementProxy);
            assertEq(activeAddresses.readAddress(".deFiAdapterImplementation"), predictedReplacementImplementation);
            assertEq(activeAddresses.readAddress(".proxyImplementationReadback"), predictedReplacementImplementation);
            assertEq(activeAddresses.readUint(".adapterEpoch"), 2);
            assertEq(activeAddresses.readUint(".adapterLogicEpoch"), 1);
            assertEq(activeAddresses.readUint(".adapterImplementationVersion"), 2);
            assertFalse(activeAddresses.readBool(".aaveV3Enabled"));
            assertEq(activeAddresses.readAddress(".aaveV3Pool"), address(0));
            assertEq(activeAddresses.readAddress(".aaveV3AUsdc"), address(0));
            assertEq(activeAddresses.readBytes32(".aaveV3StrategyId"), bytes32(0));
        }
        _setRequiredEnvironment();
    }

    function _wrongChainIdFailsBeforeAnyDeployment() private {
        address deployer = vm.addr(DEPLOYER_KEY);
        uint256 nonceBefore = vm.getNonce(deployer);
        vm.chainId(block.chainid + 1);
        vm.expectRevert("Deploy: wrong chainId");
        deployScript.run();
        assertEq(vm.getNonce(deployer), nonceBefore);
    }

    function _mismatchedDeployerFailsBeforeAnyDeployment() private {
        _set("DEPLOYER_ADDRESS", makeAddr("wrong-deployer"));
        vm.expectRevert("Deploy: signer/deployer mismatch");
        deployScript.run();
        _setRequiredEnvironment();
    }

    function _artifactHashMustBeApproved() private {
        vm.setEnv("EXPECTED_ADAPTER_INITCODE_HASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert("Deploy: Adapter artifact mismatch");
        deployScript.run();
        _setRequiredEnvironment();
    }

    function _optionalSwapOutputsCanBeSkipped() private {
        _set("REWARD_TOKEN_OUT_GHO", address(0));
        _set("REWARD_TOKEN_OUT_XAUT", address(0));
        deployScript.run();
        string memory record = vm.readFile(_deploymentPath());
        assertEq(record.readAddress(".tokenOutGho"), address(0));
        assertEq(record.readBytes32(".swapGhoStrategyId"), bytes32(0));
        assertEq(record.readAddress(".tokenOutXaut"), address(0));
        assertEq(record.readBytes32(".swapXautStrategyId"), bytes32(0));
        vm.setEnv("DEPLOYMENT_JSON", _deploymentPath());
        new VerifyDeployment().run();
        _setRequiredEnvironment();
    }

    function _noSwapRoutersDeploysWithSwapDisabled() private {
        _set("ROUTER_V2", address(0));
        _set("ROUTER_V3", address(0));
        _set("ONEINCH_ROUTER", address(0));
        _set("REWARD_TOKEN_OUT_USDT", address(0));
        _set("REWARD_TOKEN_OUT_WBTC", address(0));
        _set("REWARD_TOKEN_OUT_GHO", address(0));
        _set("REWARD_TOKEN_OUT_XAUT", address(0));
        _set("REWARD_TOKEN_OUT_SYRUP_USDC", address(0));
        deployScript.run();
        string memory record = vm.readFile(_deploymentPath());
        assertEq(record.readAddress(".routerV2"), address(0));
        assertEq(record.readBytes32(".swapUsdtStrategyId"), bytes32(0));
        vm.setEnv("DEPLOYMENT_JSON", _deploymentPath());
        new VerifyDeployment().run();
        _setRequiredEnvironment();
    }

    function _duplicateSwapOutputFailsBeforeAnyDeployment() private {
        _set("REWARD_TOKEN_OUT_WBTC", address(usdt));
        vm.expectRevert("Deploy: duplicate output token");
        deployScript.run();
        _setRequiredEnvironment();
    }

    function _assertStrategy(IXMetroDeFiAdapterAdmin adapter, bytes32 id, IXMetroDeFiAdapter.StrategyKind expectedKind)
        private
        view
    {
        IXMetroDeFiAdapter.StrategyInfo memory info = adapter.strategyInfo(id);
        assertEq(uint8(info.kind), uint8(expectedKind));
        assertTrue(info.enabled);
        assertTrue(info.autoEnabled);
        assertEq(info.logicEpoch, 1);
        assertGt(info.domainRevision, 0);
        assertGt(info.strategyRevision, 0);
    }

    function _assertAaveV3Cleared(IXMetroDeFiAdapterAdmin adapter) private view {
        IXMetroDeFiAdapterAdmin.AaveV3Config memory config;
        (,,,,,,,, config,,) = adapter.configuration();
        assertEq(config.pool, address(0));
        assertEq(config.aToken, address(0));
        assertEq(config.referralCode, 0);
    }

    function _setRequiredEnvironment() private {
        _set("EXPECTED_CHAIN_ID", block.chainid);
        _set("DEPLOYER_PRIVATE_KEY", DEPLOYER_KEY);
        _set("DEPLOYER_ADDRESS", vm.addr(DEPLOYER_KEY));
        _set("OWNER", finalOwner);
        _set("USDC", address(usdc));
        vm.setEnv("METRO_NAME", "METRO");
        vm.setEnv("METRO_SYMBOL", "METRO");
        _set("FORFEITURE_RECIPIENT", makeAddr("forfeiture"));
        vm.setEnv("ADAPTER_ARTIFACT", "out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json");
        vm.setEnv(
            "EXPECTED_ADAPTER_INITCODE_HASH",
            vm.toString(_artifactInitcodeHash("out-adapter/XMetroDeFiAdapter.sol/XMetroDeFiAdapter.json"))
        );

        _set("ROUTER_V2", address(usdt));
        _set("ROUTER_V3", address(wbtc));
        _set("ONEINCH_ROUTER", address(gho));
        _set("REWARD_TOKEN_OUT_USDT", address(usdt));
        _set("REWARD_TOKEN_OUT_WBTC", address(wbtc));
        _set("REWARD_TOKEN_OUT_GHO", address(gho));
        _set("REWARD_TOKEN_OUT_XAUT", address(xaut));
        _set("REWARD_TOKEN_OUT_SYRUP_USDC", address(syrupUsdc));

        vm.setEnv("AAVE_V3_ENABLED", "true");
        _set("AAVE_V3_POOL", address(aaveV3));
        _set("AAVE_V3_AUSDC", address(aaveV3.aUsdc()));
        _set("AAVE_V3_REFERRAL_CODE", 42);
        vm.setEnv("AAVE_V4_ENABLED", "true");
        _set("AAVE_V4_SPOKE", address(aaveV4));
        _set("AAVE_V4_GIVER", address(giver));
        _set("AAVE_V4_USDC_RESERVE_ID", 7);
        vm.setEnv("MAPLE_ENABLED", "true");
        _set("MAPLE_SYRUP_ROUTER", address(mapleRouter));
        _set("MAPLE_SYRUP_USDC", address(syrupUsdc));
        vm.setEnv("MAPLE_DEPOSIT_DATA", vm.toString(bytes32(0)));

        _set("REWARD_DISTRIBUTOR_OPERATOR", address(0));
        _set("AUTO_COMPOUND_OPERATOR", makeAddr("keeper"));
        _set("COMMISSION_VAULT", address(0));
        _set("MAX_COMMISSION_SPLIT_BPS", 0);
        vm.setEnv("CONTRIBUTORS", "");

        _set("THOR", address(thor));
        _set("YTHOR", address(yThor));
        uint256 start = block.timestamp + 1 days;
        _set("MIGRATION_START_TIME", start);
        _set("CAP_THOR", 40_000_000 ether);
        _set("CAP_YTHOR", 40_000_000 ether);
        _set("RATIO_THOR", 1 ether);
        _set("RATIO_YTHOR", 1 ether);
        _set("YTHOR_REWARD_WEIGHT_BPS", 17_500);
        _set("DEADLINE_THOR", start + 30 days);
        _set("DEADLINE_YTHOR", start + 30 days);
    }

    function _set(string memory key, address value) private {
        vm.setEnv(key, vm.toString(value));
    }

    function _set(string memory key, uint256 value) private {
        vm.setEnv(key, vm.toString(value));
    }

    function _restore(uint256 initialState) private {
        assertTrue(vm.revertToState(initialState));
        _setRequiredEnvironment();
    }

    function _deploymentPath() private view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), "/addresses.json");
    }

    function _artifactInitcodeHash(string memory path) private view returns (bytes32) {
        return keccak256(vm.parseJsonBytes(vm.readFile(path), ".bytecode.object"));
    }
}
