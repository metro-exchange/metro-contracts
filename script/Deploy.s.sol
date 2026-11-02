// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/**
 * @title Deploy
 * @notice Deploys the immutable xMETRO Core and the fixed-address UUPS DeFi Adapter Proxy.
 * @dev Build the Adapter artifact with FOUNDRY_PROFILE=adapter before running this script with
 *      FOUNDRY_PROFILE=deploy. xMETRO deploys unpaused; business-contract ownership requires acceptance by the target owner.
 */

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MetroToken} from "../src/metro.sol";
import {xMETRO} from "../src/xMETRO.sol";
import {RewardDistributor, ICommissionVault} from "../src/RewardDistributor.sol";
import {ThorMigrationEscrow} from "../src/ThorMigrationEscrow.sol";
import {IXMetroDeFiAdapter} from "../src/interfaces/IXMetroDeFiAdapter.sol";
import {DeFiAdapterScriptBase, IXMetroDeFiAdapterAdmin} from "./DeFiAdapterScriptBase.sol";

contract Deploy is DeFiAdapterScriptBase {
    using stdJson for string;

    struct Addresses {
        uint256 chainId;
        address deployer;
        uint256 deploymentNonce;
        address metro;
        bytes32 metroCodehash;
        address xMETRO;
        bytes32 xMetroCodehash;
        address deFiAdapterImplementation;
        bytes32 adapterInitcodeHash;
        bytes32 deFiAdapterImplementationCodehash;
        address deFiAdapterProxy;
        bytes32 deFiAdapterProxyCodehash;
        address proxyImplementationReadback;
        bytes32 proxyImplementationSlot;
        bytes32 proxyAdminSlotValue;
        bytes32 proxyBeaconSlotValue;
        bytes32 adapterFamilyId;
        bytes32 adapterStorageNamespace;
        uint256 adapterEpoch;
        address rewardDistributor;
        bytes32 rewardDistributorCodehash;
        address distributorOperator;
        address escrow;
        bytes32 escrowCodehash;
        address autoCompoundOperator;
        address owner;
        address coreOwner;
        address corePendingOwner;
        address escrowOwner;
        address escrowPendingOwner;
        address distributorOwner;
        address distributorPendingOwner;
        address forfeitureRecipient;
        address migrationRewardExcludedAddress;
        address commissionVault;
        address commissionVaultUsdc;
        address commissionVaultDistributor;
        bytes32 commissionVaultCodehash;
        bool commissionVaultMigrationFinalized;
        bool commissionVaultPaused;
        address rewardToken;
        address thor;
        address yThor;
        address routerV2;
        address routerV3;
        address oneInchRouter;
        address tokenOutUsdt;
        address tokenOutWbtc;
        address tokenOutGho;
        address tokenOutXaut;
        address tokenOutSyrupUsdc;
        bytes32 swapMetroStrategyId;
        bytes32 swapUsdtStrategyId;
        bytes32 swapWbtcStrategyId;
        bytes32 swapGhoStrategyId;
        bytes32 swapXautStrategyId;
        bytes32 swapSyrupUsdcStrategyId;
        bytes32 aaveV3StrategyId;
        bytes32 aaveV4StrategyId;
        bytes32 mapleStrategyId;
        address aaveV3Pool;
        address aaveV3AUsdc;
        uint256 aaveV3ReferralCode;
        bool aaveV3Enabled;
        address aaveV4Spoke;
        address aaveV4Giver;
        uint256 aaveV4UsdcReserveId;
        bool aaveV4Enabled;
        address mapleSyrupRouter;
        address mapleSyrupUsdc;
        bytes32 mapleDepositData;
        bool mapleEnabled;
        uint256 adapterLogicEpoch;
        uint256 adapterImplementationVersion;
        uint256 metroMaxSupply;
        uint256 maxCommissionSplitBps;
        uint256 capThor;
        uint256 capYThor;
        uint256 ratioThor;
        uint256 ratioYThor;
        uint256 yThorRewardWeightBps;
        uint256 migrationStartTime;
        uint256 deadlineThor;
        uint256 deadlineYThor;
    }

    struct Input {
        address owner;
        address deployer;
        uint256 deployerPk;
        address usdc;
        string metroName;
        string metroSymbol;
        address forfeitureRecipient;
        address routerV2;
        address routerV3;
        address oneInchRouter;
        address tokenOutUsdt;
        address tokenOutWbtc;
        address tokenOutGho;
        address tokenOutXaut;
        address tokenOutSyrupUsdc;
        bool aaveV3Enabled;
        address aaveV3Pool;
        address aaveV3AUsdc;
        uint16 aaveV3ReferralCode;
        bool aaveV4Enabled;
        address aaveV4Spoke;
        address aaveV4Giver;
        uint256 aaveV4UsdcReserveId;
        bool mapleEnabled;
        address mapleSyrupRouter;
        address expectedMapleSyrupUsdc;
        bytes32 mapleDepositData;
        address distributorOperator;
        address autoCompoundOperator;
        address commissionVault;
        uint16 maxCommissionSplitBps;
        string contributors;
        address thor;
        address yThor;
        uint256 migrationStartTime;
        uint256 capThor;
        uint256 capYThor;
        uint256 ratioThor;
        uint256 ratioYThor;
        uint256 yThorRewardWeightBps;
        uint256 deadlineThor;
        uint256 deadlineYThor;
        string adapterArtifact;
        bytes32 adapterInitcodeHash;
    }

    function run() external {
        Input memory input = _loadAndValidateInput();
        bytes memory implementationInitCode = _adapterCreationCode(input.adapterArtifact);
        require(input.adapterInitcodeHash != bytes32(0), "Deploy: missing approved Adapter initcode hash");
        require(keccak256(implementationInitCode) == input.adapterInitcodeHash, "Deploy: Adapter artifact mismatch");
        uint256 startingNonce = vm.getNonce(input.deployer);

        address predictedMetro = vm.computeCreateAddress(input.deployer, startingNonce);
        address predictedCore = vm.computeCreateAddress(input.deployer, startingNonce + 1);
        address predictedImplementation = vm.computeCreateAddress(input.deployer, startingNonce + 2);
        address predictedProxy = vm.computeCreateAddress(input.deployer, startingNonce + 3);
        address predictedDistributor = vm.computeCreateAddress(input.deployer, startingNonce + 4);
        address predictedEscrow = vm.computeCreateAddress(input.deployer, startingNonce + 5);
        require(
            predictedMetro.code.length == 0 && predictedCore.code.length == 0
                && predictedImplementation.code.length == 0 && predictedProxy.code.length == 0
                && predictedDistributor.code.length == 0 && predictedEscrow.code.length == 0,
            "Deploy: predicted address occupied"
        );
        _requireCommissionVault(input, predictedDistributor);

        if (input.deployerPk != 0) vm.startBroadcast(input.deployerPk);
        else vm.startBroadcast(input.deployer);

        MetroToken metro = new MetroToken(input.metroName, input.metroSymbol, input.deployer);
        xMETRO core = new xMETRO(
            input.deployer, address(metro), input.usdc, input.forfeitureRecipient, input.yThorRewardWeightBps
        );
        address implementation = _deployCreationCode(implementationInitCode);
        bytes memory initData =
            abi.encodeCall(IXMetroDeFiAdapterAdmin.initialize, (address(core), input.usdc, address(metro)));
        address proxy = address(new ERC1967Proxy(implementation, initData));
        RewardDistributor distributor = new RewardDistributor(address(core), input.deployer);
        ThorMigrationEscrow escrow =
            new ThorMigrationEscrow(input.deployer, address(core), input.thor, input.yThor, input.migrationStartTime);

        require(
            address(metro) == predictedMetro && address(core) == predictedCore
                && implementation == predictedImplementation && proxy == predictedProxy
                && address(distributor) == predictedDistributor && address(escrow) == predictedEscrow,
            "Deploy: CREATE address mismatch"
        );
        _requireImplementation(implementation, 2);
        _requireProxySlots(proxy, implementation);

        metro.setMinter(address(core), true);
        core.setDeFiAdapter(proxy);
        IXMetroDeFiAdapterAdmin adapter = IXMetroDeFiAdapterAdmin(proxy);
        Addresses memory output;
        _configureAdapter(adapter, core, input, output);

        if (input.distributorOperator != address(0)) distributor.setOperator(input.distributorOperator, true);
        if (input.commissionVault != address(0)) distributor.setCommissionVault(input.commissionVault);
        if (input.maxCommissionSplitBps != 0) distributor.setMaxCommissionSplitBps(input.maxCommissionSplitBps);
        core.setRewardDistributor(address(distributor));
        if (input.autoCompoundOperator != address(0)) core.setAutoCompoundOperator(input.autoCompoundOperator, true);
        if (bytes(input.contributors).length != 0) {
            address[] memory list = _parseAddressList(input.contributors);
            for (uint256 i; i < list.length; ++i) {
                core.setContributor(list[i], true);
            }
        }

        escrow.setCaps(input.capThor, input.capYThor);
        escrow.setRatios(input.ratioThor, input.ratioYThor);
        escrow.setDeadlines(input.deadlineThor, input.deadlineYThor);
        core.setMigrationEscrow(address(escrow));

        metro.transferOwnership(input.owner);
        if (input.owner != input.deployer) {
            distributor.transferOwnership(input.owner);
            escrow.transferOwnership(input.owner);
            core.transferOwnership(input.owner);
        }
        vm.stopBroadcast();

        _fillOutput(output, input, startingNonce, metro, core, implementation, proxy, distributor, escrow);
        _verifyDeployment(output, input, metro, core, adapter, distributor, escrow);
        _writeAddresses(_addressesPath(), output);
        _logDeployment(output);
    }

    function _loadAndValidateInput() internal view returns (Input memory i) {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == expectedChainId, "Deploy: wrong chainId");
        i.owner = vm.envAddress("OWNER");
        i.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        i.deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        require(i.deployerPk == 0 || vm.addr(i.deployerPk) == i.deployer, "Deploy: signer/deployer mismatch");
        i.usdc = vm.envAddress("USDC");
        i.metroName = vm.envString("METRO_NAME");
        i.metroSymbol = vm.envString("METRO_SYMBOL");
        i.forfeitureRecipient = vm.envAddress("FORFEITURE_RECIPIENT");
        require(i.owner != address(0) && i.deployer != address(0), "Deploy: zero owner");
        require(i.forfeitureRecipient != address(0), "Deploy: zero forfeiture recipient");
        _requireToken(i.usdc, 6, "USDC");

        i.routerV2 = vm.envOr("ROUTER_V2", address(0));
        i.routerV3 = vm.envOr("ROUTER_V3", address(0));
        i.oneInchRouter = vm.envOr("ONEINCH_ROUTER", address(0));
        bool anyRouter = i.routerV2 != address(0) || i.routerV3 != address(0) || i.oneInchRouter != address(0);
        bool allRouters = i.routerV2 != address(0) && i.routerV3 != address(0) && i.oneInchRouter != address(0);
        require(!anyRouter || allRouters, "Deploy: partial router config");
        if (allRouters) {
            require(
                i.routerV2.code.length != 0 && i.routerV3.code.length != 0 && i.oneInchRouter.code.length != 0,
                "Deploy: router no code"
            );
            require(
                i.routerV2 != i.routerV3 && i.routerV2 != i.oneInchRouter && i.routerV3 != i.oneInchRouter,
                "Deploy: duplicate router"
            );
        }
        i.tokenOutUsdt = vm.envOr("REWARD_TOKEN_OUT_USDT", address(0));
        i.tokenOutWbtc = vm.envOr("REWARD_TOKEN_OUT_WBTC", address(0));
        i.tokenOutGho = vm.envOr("REWARD_TOKEN_OUT_GHO", address(0));
        i.tokenOutXaut = vm.envOr("REWARD_TOKEN_OUT_XAUT", address(0));
        i.tokenOutSyrupUsdc = vm.envOr("REWARD_TOKEN_OUT_SYRUP_USDC", address(0));
        if (allRouters) {
            if (i.tokenOutUsdt != address(0)) _requireOutputToken(i.tokenOutUsdt, i.usdc, "USDT");
            if (i.tokenOutWbtc != address(0)) _requireOutputToken(i.tokenOutWbtc, i.usdc, "WBTC");
            if (i.tokenOutGho != address(0)) _requireOutputToken(i.tokenOutGho, i.usdc, "GHO");
            if (i.tokenOutXaut != address(0)) _requireOutputToken(i.tokenOutXaut, i.usdc, "XAUT");
            if (i.tokenOutSyrupUsdc != address(0)) _requireOutputToken(i.tokenOutSyrupUsdc, i.usdc, "syrupUSDC");
            address[5] memory outputs =
                [i.tokenOutUsdt, i.tokenOutWbtc, i.tokenOutGho, i.tokenOutXaut, i.tokenOutSyrupUsdc];
            for (uint256 n; n < outputs.length; ++n) {
                if (outputs[n] == address(0)) continue;
                for (uint256 m = n + 1; m < outputs.length; ++m) {
                    require(outputs[n] != outputs[m], "Deploy: duplicate output token");
                }
            }
        } else {
            require(
                i.tokenOutUsdt == address(0) && i.tokenOutWbtc == address(0) && i.tokenOutGho == address(0)
                    && i.tokenOutXaut == address(0) && i.tokenOutSyrupUsdc == address(0),
                "Deploy: output without routers"
            );
        }

        i.aaveV3Enabled = vm.envOr("AAVE_V3_ENABLED", false);
        i.aaveV3Pool = vm.envOr("AAVE_V3_POOL", address(0));
        i.aaveV3AUsdc = vm.envOr("AAVE_V3_AUSDC", address(0));
        uint256 referralCode = vm.envOr("AAVE_V3_REFERRAL_CODE", uint256(0));
        require(referralCode <= type(uint16).max, "Deploy: Aave referral overflow");
        i.aaveV3ReferralCode = uint16(referralCode);
        i.aaveV4Enabled = vm.envOr("AAVE_V4_ENABLED", false);
        i.aaveV4Spoke = vm.envOr("AAVE_V4_SPOKE", address(0));
        i.aaveV4Giver = vm.envOr("AAVE_V4_GIVER", address(0));
        i.aaveV4UsdcReserveId = vm.envOr("AAVE_V4_USDC_RESERVE_ID", uint256(0));
        i.mapleEnabled = vm.envOr("MAPLE_ENABLED", false);
        i.mapleSyrupRouter = vm.envOr("MAPLE_SYRUP_ROUTER", address(0));
        i.expectedMapleSyrupUsdc = vm.envOr("MAPLE_SYRUP_USDC", address(0));
        i.mapleDepositData = vm.envOr("MAPLE_DEPOSIT_DATA", bytes32(0));

        i.distributorOperator = vm.envOr("REWARD_DISTRIBUTOR_OPERATOR", address(0));
        i.autoCompoundOperator = vm.envOr("AUTO_COMPOUND_OPERATOR", address(0));
        i.commissionVault = vm.envOr("COMMISSION_VAULT", address(0));
        uint256 commissionBps = vm.envOr("MAX_COMMISSION_SPLIT_BPS", uint256(0));
        require(commissionBps <= 10_000, "Deploy: commission overflow");
        i.maxCommissionSplitBps = uint16(commissionBps);
        require(commissionBps == 0 || i.commissionVault != address(0), "Deploy: zero commission vault");
        i.contributors = vm.envOr("CONTRIBUTORS", string(""));

        i.thor = vm.envAddress("THOR");
        i.yThor = vm.envAddress("YTHOR");
        _requireToken(i.thor, 18, "THOR");
        _requireToken(i.yThor, 18, "yTHOR");
        require(i.usdc != i.thor && i.usdc != i.yThor && i.thor != i.yThor, "Deploy: duplicate token");
        i.migrationStartTime = vm.envUint("MIGRATION_START_TIME");
        i.capThor = vm.envUint("CAP_THOR");
        i.capYThor = vm.envUint("CAP_YTHOR");
        i.ratioThor = vm.envUint("RATIO_THOR");
        i.ratioYThor = vm.envUint("RATIO_YTHOR");
        i.yThorRewardWeightBps = vm.envUint("YTHOR_REWARD_WEIGHT_BPS");
        i.deadlineThor = vm.envUint("DEADLINE_THOR");
        i.deadlineYThor = vm.envUint("DEADLINE_YTHOR");
        require(i.capThor > 0 && i.capYThor > 0, "Deploy: zero migration cap");
        require(
            i.capThor <= 100_000_000 ether && i.capYThor <= 100_000_000 ether - i.capThor,
            "Deploy: migration caps exceed supply"
        );
        require(i.ratioThor > 0 && i.ratioYThor > 0, "Deploy: zero migration ratio");
        require(i.yThorRewardWeightBps <= type(uint128).max, "Deploy: bad yTHOR reward weight");
        require(
            i.migrationStartTime >= block.timestamp && i.deadlineThor > i.migrationStartTime
                && i.deadlineYThor > i.migrationStartTime,
            "Deploy: bad migration window"
        );
        i.adapterArtifact = vm.envOr("ADAPTER_ARTIFACT", DEFAULT_ADAPTER_ARTIFACT);
        i.adapterInitcodeHash = vm.envBytes32("EXPECTED_ADAPTER_INITCODE_HASH");
    }

    function _configureAdapter(IXMetroDeFiAdapterAdmin adapter, xMETRO core, Input memory i, Addresses memory a)
        internal
    {
        if (i.routerV2 != address(0)) {
            adapter.setRouters(i.routerV2, i.routerV3, i.oneInchRouter);
            adapter.setSwapMetroConfig(true, true);
            if (i.tokenOutUsdt != address(0)) {
                a.swapUsdtStrategyId = adapter.setSwapTokenConfig(i.tokenOutUsdt, true, true);
            }
            if (i.tokenOutWbtc != address(0)) {
                a.swapWbtcStrategyId = adapter.setSwapTokenConfig(i.tokenOutWbtc, true, true);
            }
            if (i.tokenOutGho != address(0)) {
                a.swapGhoStrategyId = adapter.setSwapTokenConfig(i.tokenOutGho, true, true);
            }
            if (i.tokenOutXaut != address(0)) {
                a.swapXautStrategyId = adapter.setSwapTokenConfig(i.tokenOutXaut, true, true);
            }
            if (i.tokenOutSyrupUsdc != address(0)) {
                a.swapSyrupUsdcStrategyId = adapter.setSwapTokenConfig(i.tokenOutSyrupUsdc, true, true);
            }
        }
        a.swapMetroStrategyId = _strategyId(IXMetroDeFiAdapter.StrategyKind.SwapMetro, address(core.METRO()));
        a.aaveV4StrategyId = _strategyId(IXMetroDeFiAdapter.StrategyKind.AaveV4, address(0));
        if (i.aaveV3Enabled) {
            a.aaveV3StrategyId = adapter.setAaveV3Config(i.aaveV3Pool, i.aaveV3AUsdc, i.aaveV3ReferralCode, true, true);
        }
        if (i.aaveV4Enabled) adapter.setAaveV4Config(i.aaveV4Spoke, i.aaveV4Giver, i.aaveV4UsdcReserveId, true, true);
        if (i.mapleEnabled) {
            a.mapleStrategyId = adapter.setMapleConfig(i.mapleSyrupRouter, i.mapleDepositData, true, true);
        }
    }

    function _fillOutput(
        Addresses memory a,
        Input memory i,
        uint256 startingNonce,
        MetroToken metro,
        xMETRO core,
        address implementation,
        address proxy,
        RewardDistributor distributor,
        ThorMigrationEscrow escrow
    ) internal view {
        AdapterConfiguration memory config = _requireProxyBindings(proxy, address(core), i.usdc, address(metro));
        a.chainId = block.chainid;
        a.deployer = i.deployer;
        a.deploymentNonce = startingNonce;
        a.metro = address(metro);
        a.metroCodehash = address(metro).codehash;
        a.xMETRO = address(core);
        a.xMetroCodehash = address(core).codehash;
        a.deFiAdapterImplementation = implementation;
        a.adapterInitcodeHash = i.adapterInitcodeHash;
        a.deFiAdapterImplementationCodehash = implementation.codehash;
        a.deFiAdapterProxy = proxy;
        a.deFiAdapterProxyCodehash = proxy.codehash;
        a.proxyImplementationReadback = _proxyImplementation(proxy);
        a.proxyImplementationSlot = IMPLEMENTATION_SLOT;
        a.proxyAdminSlotValue = vm.load(proxy, ADMIN_SLOT);
        a.proxyBeaconSlotValue = vm.load(proxy, BEACON_SLOT);
        a.adapterFamilyId = config.family;
        a.adapterStorageNamespace = ADAPTER_STORAGE_NAMESPACE;
        a.adapterEpoch = core.deFiAdapterEpoch();
        a.rewardDistributor = address(distributor);
        a.rewardDistributorCodehash = address(distributor).codehash;
        a.distributorOperator = i.distributorOperator;
        a.escrow = address(escrow);
        a.escrowCodehash = address(escrow).codehash;
        a.autoCompoundOperator = i.autoCompoundOperator;
        a.owner = i.owner;
        a.coreOwner = core.owner();
        a.corePendingOwner = core.pendingOwner();
        a.escrowOwner = escrow.owner();
        a.escrowPendingOwner = escrow.pendingOwner();
        a.distributorOwner = distributor.owner();
        a.distributorPendingOwner = distributor.pendingOwner();
        a.forfeitureRecipient = i.forfeitureRecipient;
        a.migrationRewardExcludedAddress = core.migrationRewardExcludedAddress();
        a.commissionVault = i.commissionVault;
        a.commissionVaultUsdc =
            i.commissionVault == address(0) ? address(0) : ICommissionVault(i.commissionVault).usdc();
        a.commissionVaultDistributor =
            i.commissionVault == address(0) ? address(0) : ICommissionVault(i.commissionVault).distributor();
        a.commissionVaultCodehash = i.commissionVault.codehash;
        a.commissionVaultMigrationFinalized =
            i.commissionVault != address(0) && ICommissionVault(i.commissionVault).migrationFinalized();
        a.commissionVaultPaused = i.commissionVault != address(0) && ICommissionVault(i.commissionVault).paused();
        a.rewardToken = i.usdc;
        a.thor = i.thor;
        a.yThor = i.yThor;
        a.routerV2 = config.routerV2;
        a.routerV3 = config.routerV3;
        a.oneInchRouter = config.oneInchRouter;
        a.tokenOutUsdt = i.routerV2 == address(0) ? address(0) : i.tokenOutUsdt;
        a.tokenOutWbtc = i.routerV2 == address(0) ? address(0) : i.tokenOutWbtc;
        a.tokenOutGho = i.routerV2 == address(0) ? address(0) : i.tokenOutGho;
        a.tokenOutXaut = i.routerV2 == address(0) ? address(0) : i.tokenOutXaut;
        a.tokenOutSyrupUsdc = i.routerV2 == address(0) ? address(0) : i.tokenOutSyrupUsdc;
        a.aaveV3Pool = config.aaveV3.pool;
        a.aaveV3AUsdc = config.aaveV3.aToken;
        a.aaveV3ReferralCode = config.aaveV3.referralCode;
        a.aaveV3Enabled = i.aaveV3Enabled;
        a.aaveV4Spoke = config.aaveV4.spoke;
        a.aaveV4Giver = config.aaveV4Giver;
        a.aaveV4UsdcReserveId = config.aaveV4.reserveId;
        a.aaveV4Enabled = i.aaveV4Enabled;
        a.mapleSyrupRouter = config.maple.router;
        a.mapleSyrupUsdc = config.maple.syrupToken;
        a.mapleDepositData = config.maple.depositData;
        a.mapleEnabled = i.mapleEnabled;
        a.adapterLogicEpoch = config.epoch;
        a.adapterImplementationVersion = IXMetroDeFiAdapter(proxy).implementationVersion();
        a.metroMaxSupply = metro.cap();
        a.maxCommissionSplitBps = i.maxCommissionSplitBps;
        a.capThor = i.capThor;
        a.capYThor = i.capYThor;
        a.ratioThor = i.ratioThor;
        a.ratioYThor = i.ratioYThor;
        a.yThorRewardWeightBps = core.yThorRewardWeightBps();
        a.migrationStartTime = i.migrationStartTime;
        a.deadlineThor = i.deadlineThor;
        a.deadlineYThor = i.deadlineYThor;
    }

    function _verifyDeployment(
        Addresses memory a,
        Input memory i,
        MetroToken metro,
        xMETRO core,
        IXMetroDeFiAdapterAdmin adapter,
        RewardDistributor distributor,
        ThorMigrationEscrow escrow
    ) internal view {
        require(
            a.chainId == block.chainid && a.proxyImplementationReadback == a.deFiAdapterImplementation,
            "Deploy: identity"
        );
        require(
            a.proxyImplementationSlot == IMPLEMENTATION_SLOT && a.proxyAdminSlotValue == bytes32(0)
                && a.proxyBeaconSlotValue == bytes32(0) && a.adapterFamilyId == ADAPTER_FAMILY_ID
                && a.adapterStorageNamespace == ADAPTER_STORAGE_NAMESPACE && a.adapterEpoch == 1,
            "Deploy: proxy metadata"
        );
        require(
            metro.owner() == i.owner && metro.cap() == 100_000_000 ether && metro.MAX_SUPPLY() == 100_000_000 ether,
            "Deploy: METRO readback"
        );
        require(metro.isMinter(address(core)), "Deploy: xMETRO not minter");
        require(!metro.isMinter(i.deployer) && !metro.isMinter(i.owner), "Deploy: unexpected EOA minter");
        address expectedPending = i.owner == i.deployer ? address(0) : i.owner;
        require(
            core.owner() == i.deployer && core.pendingOwner() == expectedPending && !core.paused(),
            "Deploy: xMETRO ownership/pause"
        );
        require(
            address(core.METRO()) == address(metro) && address(core.rewardToken()) == i.usdc
                && core.forfeitureRecipient() == i.forfeitureRecipient
                && core.migrationRewardExcludedAddress() == i.forfeitureRecipient
                && core.deFiAdapter() == address(adapter) && core.deFiAdapterEpoch() == 1
                && core.rewardDistributor() == address(distributor) && core.migrationEscrow() == address(escrow),
            "Deploy: xMETRO binding"
        );

        AdapterConfiguration memory config =
            _requireProxyBindings(address(adapter), address(core), i.usdc, address(metro));
        require(config.epoch == 1 && adapter.implementationVersion() == 2, "Deploy: adapter version");
        require(
            config.routerV2 == i.routerV2 && config.routerV3 == i.routerV3 && config.oneInchRouter == i.oneInchRouter,
            "Deploy: router readback"
        );
        require(
            config.aaveV3.pool == (i.aaveV3Enabled ? i.aaveV3Pool : address(0))
                && config.aaveV3.aToken == (i.aaveV3Enabled ? i.aaveV3AUsdc : address(0))
                && config.aaveV3.referralCode == (i.aaveV3Enabled ? i.aaveV3ReferralCode : 0),
            "Deploy: Aave V3 readback"
        );
        require(
            config.aaveV4.spoke == (i.aaveV4Enabled ? i.aaveV4Spoke : address(0))
                && config.aaveV4.reserveId == (i.aaveV4Enabled ? i.aaveV4UsdcReserveId : 0)
                && config.aaveV4Giver == (i.aaveV4Enabled ? i.aaveV4Giver : address(0)),
            "Deploy: Aave V4 readback"
        );
        require(
            config.maple.router == (i.mapleEnabled ? i.mapleSyrupRouter : address(0))
                && config.maple.depositData == (i.mapleEnabled ? i.mapleDepositData : bytes32(0))
                && (!i.mapleEnabled
                    || i.expectedMapleSyrupUsdc == address(0)
                    || config.maple.syrupToken == i.expectedMapleSyrupUsdc),
            "Deploy: Maple readback"
        );

        _requireStrategy(
            adapter, a.swapMetroStrategyId, IXMetroDeFiAdapter.StrategyKind.SwapMetro, i.routerV2 != address(0)
        );
        if (i.routerV2 != address(0)) {
            if (i.tokenOutUsdt != address(0)) {
                _requireStrategy(adapter, a.swapUsdtStrategyId, IXMetroDeFiAdapter.StrategyKind.AutoSwap, true);
            }
            if (i.tokenOutWbtc != address(0)) {
                _requireStrategy(adapter, a.swapWbtcStrategyId, IXMetroDeFiAdapter.StrategyKind.AutoSwap, true);
            }
            if (i.tokenOutGho != address(0)) {
                _requireStrategy(adapter, a.swapGhoStrategyId, IXMetroDeFiAdapter.StrategyKind.AutoSwap, true);
            }
            if (i.tokenOutXaut != address(0)) {
                _requireStrategy(adapter, a.swapXautStrategyId, IXMetroDeFiAdapter.StrategyKind.AutoSwap, true);
            }
            if (i.tokenOutSyrupUsdc != address(0)) {
                _requireStrategy(adapter, a.swapSyrupUsdcStrategyId, IXMetroDeFiAdapter.StrategyKind.AutoSwap, true);
            }
        }
        if (i.aaveV3Enabled) {
            _requireStrategy(adapter, a.aaveV3StrategyId, IXMetroDeFiAdapter.StrategyKind.AaveV3, true);
        }
        _requireStrategy(adapter, a.aaveV4StrategyId, IXMetroDeFiAdapter.StrategyKind.AaveV4, i.aaveV4Enabled);
        if (i.mapleEnabled) _requireStrategy(adapter, a.mapleStrategyId, IXMetroDeFiAdapter.StrategyKind.Maple, true);

        require(
            distributor.owner() == i.deployer && distributor.pendingOwner() == expectedPending,
            "Deploy: distributor owner"
        );
        require(
            address(distributor.xMETRO()) == address(core) && address(distributor.rewardToken()) == i.usdc
                && distributor.commissionVault() == i.commissionVault
                && distributor.maxCommissionSplitBps() == i.maxCommissionSplitBps,
            "Deploy: distributor readback"
        );
        if (i.distributorOperator != address(0)) {
            require(distributor.operators(i.distributorOperator), "Deploy: distributor operator");
        }
        if (i.autoCompoundOperator != address(0)) {
            require(core.autoCompoundOperators(i.autoCompoundOperator), "Deploy: keeper");
        }
        require(
            escrow.owner() == i.deployer && escrow.pendingOwner() == expectedPending
                && address(escrow.xMETRO()) == address(core) && address(escrow.thorToken()) == i.thor
                && address(escrow.yThorToken()) == i.yThor && escrow.migrationStartTime() == i.migrationStartTime
                && escrow.capThor() == i.capThor && escrow.capYThor() == i.capYThor && escrow.ratioThor() == i.ratioThor
                && escrow.ratioYThor() == i.ratioYThor && escrow.deadlineThor() == i.deadlineThor
                && escrow.deadlineYThor() == i.deadlineYThor,
            "Deploy: escrow readback"
        );
        require(core.yThorRewardWeightBps() == i.yThorRewardWeightBps, "Deploy: yTHOR reward weight");

        if (i.commissionVault != address(0)) {
            require(
                a.commissionVaultUsdc == i.usdc && a.commissionVaultDistributor == address(distributor)
                    && a.commissionVaultMigrationFinalized && !a.commissionVaultPaused
                    && a.commissionVaultCodehash != bytes32(0),
                "Deploy: commission vault readback"
            );
        }

        require(
            IXMetroDeFiAdapter(a.deFiAdapterImplementation).xMETRO() == address(0)
                && IXMetroDeFiAdapter(a.deFiAdapterImplementation).USDC() == address(0)
                && IXMetroDeFiAdapter(a.deFiAdapterImplementation).METRO() == address(0),
            "Deploy: implementation initialized"
        );
        require(
            IERC20(i.usdc).balanceOf(a.deFiAdapterImplementation) == 0
                && IERC20(address(metro)).balanceOf(a.deFiAdapterImplementation) == 0,
            "Deploy: implementation balance"
        );
        _requireNoAllowance(i.usdc, address(core), address(adapter));
        _requireNoAllowance(i.usdc, address(adapter), i.routerV2);
        _requireNoAllowance(i.usdc, address(adapter), i.routerV3);
        _requireNoAllowance(i.usdc, address(adapter), i.oneInchRouter);
        _requireNoAllowance(i.usdc, address(adapter), i.aaveV3Pool);
        _requireNoAllowance(i.usdc, address(adapter), i.aaveV4Spoke);
        _requireNoAllowance(i.usdc, address(adapter), i.aaveV4Giver);
        _requireNoAllowance(i.usdc, address(adapter), i.mapleSyrupRouter);
    }

    function _requireStrategy(
        IXMetroDeFiAdapterAdmin adapter,
        bytes32 id,
        IXMetroDeFiAdapter.StrategyKind kind,
        bool enabled
    ) internal view {
        IXMetroDeFiAdapter.StrategyInfo memory info = adapter.strategyInfo(id);
        require(info.kind == kind && info.enabled == enabled, "Deploy: strategy readback");
        require(
            !enabled || (info.autoEnabled && info.logicEpoch == 1 && info.strategyRevision != 0),
            "Deploy: strategy version"
        );
    }

    function _requireToken(address token, uint8 expectedDecimals, string memory symbol) internal view {
        require(token.code.length != 0, string.concat("Deploy: ", symbol, " no code"));
        require(IERC20Metadata(token).decimals() == expectedDecimals, string.concat("Deploy: ", symbol, " decimals"));
    }

    function _requireOutputToken(address token, address usdc, string memory symbol) internal view {
        require(token != address(0) && token != usdc && token.code.length != 0, string.concat("Deploy: bad ", symbol));
        IERC20Metadata(token).decimals();
    }

    function _requireCommissionVault(Input memory i, address predictedDistributor) internal view {
        address vault = i.commissionVault;
        if (vault == address(0)) return;
        require(vault.code.length != 0, "Deploy: commission vault no code");
        require(ICommissionVault(vault).usdc() == i.usdc, "Deploy: commission token mismatch");
        require(
            ICommissionVault(vault).distributor() == predictedDistributor, "Deploy: commission distributor mismatch"
        );
        require(ICommissionVault(vault).migrationFinalized(), "Deploy: commission migration pending");
        require(!ICommissionVault(vault).paused(), "Deploy: commission vault paused");
    }

    function _parseAddressList(string memory list) internal pure returns (address[] memory addrs) {
        bytes memory b = bytes(list);
        uint256 count;
        bool inToken;
        for (uint256 i; i < b.length; ++i) {
            if (_isDelimiter(b[i])) {
                if (inToken) {
                    ++count;
                    inToken = false;
                }
            } else {
                inToken = true;
            }
        }
        if (inToken) ++count;
        addrs = new address[](count);
        uint256 index;
        uint256 start;
        inToken = false;
        for (uint256 i; i <= b.length; ++i) {
            bool end = i == b.length;
            if (end || _isDelimiter(b[i])) {
                if (inToken) {
                    addrs[index++] = vm.parseAddress(_substring(b, start, i));
                    inToken = false;
                }
            } else if (!inToken) {
                inToken = true;
                start = i;
            }
        }
        require(index == count, "Deploy: bad CONTRIBUTORS");
    }

    function _isDelimiter(bytes1 c) internal pure returns (bool) {
        return c == bytes1(",") || c == bytes1(" ") || c == bytes1("\n") || c == bytes1("\r") || c == bytes1("\t");
    }

    function _substring(bytes memory data, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
        return string(out);
    }

    function _addressesPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), "/addresses.json");
    }

    function _writeAddresses(string memory path, Addresses memory a) internal {
        vm.createDir(string.concat("deployments/", vm.toString(block.chainid)), true);
        string memory obj = "addresses";
        string memory json;
        json = vm.serializeUint(obj, "chainId", a.chainId);
        json = vm.serializeAddress(obj, "deployer", a.deployer);
        json = vm.serializeUint(obj, "deploymentNonce", a.deploymentNonce);
        json = vm.serializeAddress(obj, "metro", a.metro);
        json = vm.serializeBytes32(obj, "metroCodehash", a.metroCodehash);
        json = vm.serializeAddress(obj, "xMETRO", a.xMETRO);
        json = vm.serializeBytes32(obj, "xMetroCodehash", a.xMetroCodehash);
        json = vm.serializeAddress(obj, "deFiAdapterImplementation", a.deFiAdapterImplementation);
        json = vm.serializeBytes32(obj, "adapterInitcodeHash", a.adapterInitcodeHash);
        json = vm.serializeBytes32(obj, "deFiAdapterImplementationCodehash", a.deFiAdapterImplementationCodehash);
        json = vm.serializeAddress(obj, "deFiAdapterProxy", a.deFiAdapterProxy);
        json = vm.serializeBytes32(obj, "deFiAdapterProxyCodehash", a.deFiAdapterProxyCodehash);
        json = vm.serializeAddress(obj, "proxyImplementationReadback", a.proxyImplementationReadback);
        json = vm.serializeBytes32(obj, "proxyImplementationSlot", a.proxyImplementationSlot);
        json = vm.serializeBytes32(obj, "proxyAdminSlotValue", a.proxyAdminSlotValue);
        json = vm.serializeBytes32(obj, "proxyBeaconSlotValue", a.proxyBeaconSlotValue);
        json = vm.serializeBytes32(obj, "adapterFamilyId", a.adapterFamilyId);
        json = vm.serializeBytes32(obj, "adapterStorageNamespace", a.adapterStorageNamespace);
        json = vm.serializeUint(obj, "adapterEpoch", a.adapterEpoch);
        json = vm.serializeAddress(obj, "rewardDistributor", a.rewardDistributor);
        json = vm.serializeBytes32(obj, "rewardDistributorCodehash", a.rewardDistributorCodehash);
        json = vm.serializeAddress(obj, "distributorOperator", a.distributorOperator);
        json = vm.serializeAddress(obj, "escrow", a.escrow);
        json = vm.serializeBytes32(obj, "escrowCodehash", a.escrowCodehash);
        json = vm.serializeAddress(obj, "autoCompoundOperator", a.autoCompoundOperator);
        json = vm.serializeAddress(obj, "owner", a.owner);
        json = vm.serializeAddress(obj, "distributorPendingOwner", a.distributorPendingOwner);
        json = vm.serializeAddress(obj, "distributorOwner", a.distributorOwner);
        json = vm.serializeAddress(obj, "escrowPendingOwner", a.escrowPendingOwner);
        json = vm.serializeAddress(obj, "escrowOwner", a.escrowOwner);
        json = vm.serializeAddress(obj, "corePendingOwner", a.corePendingOwner);
        json = vm.serializeAddress(obj, "coreOwner", a.coreOwner);
        json = vm.serializeAddress(obj, "forfeitureRecipient", a.forfeitureRecipient);
        json = vm.serializeAddress(obj, "migrationRewardExcludedAddress", a.migrationRewardExcludedAddress);
        json = vm.serializeAddress(obj, "commissionVault", a.commissionVault);
        json = vm.serializeAddress(obj, "commissionVaultUsdc", a.commissionVaultUsdc);
        json = vm.serializeAddress(obj, "commissionVaultDistributor", a.commissionVaultDistributor);
        json = vm.serializeBytes32(obj, "commissionVaultCodehash", a.commissionVaultCodehash);
        json = vm.serializeBool(obj, "commissionVaultMigrationFinalized", a.commissionVaultMigrationFinalized);
        json = vm.serializeBool(obj, "commissionVaultPaused", a.commissionVaultPaused);
        json = vm.serializeAddress(obj, "rewardToken", a.rewardToken);
        json = vm.serializeAddress(obj, "thor", a.thor);
        json = vm.serializeAddress(obj, "yThor", a.yThor);
        json = vm.serializeAddress(obj, "routerV2", a.routerV2);
        json = vm.serializeAddress(obj, "routerV3", a.routerV3);
        json = vm.serializeAddress(obj, "oneInchRouter", a.oneInchRouter);
        json = vm.serializeAddress(obj, "tokenOutUsdt", a.tokenOutUsdt);
        json = vm.serializeAddress(obj, "tokenOutWbtc", a.tokenOutWbtc);
        json = vm.serializeAddress(obj, "tokenOutGho", a.tokenOutGho);
        json = vm.serializeAddress(obj, "tokenOutXaut", a.tokenOutXaut);
        json = vm.serializeAddress(obj, "tokenOutSyrupUsdc", a.tokenOutSyrupUsdc);
        json = vm.serializeBytes32(obj, "swapMetroStrategyId", a.swapMetroStrategyId);
        json = vm.serializeBytes32(obj, "swapUsdtStrategyId", a.swapUsdtStrategyId);
        json = vm.serializeBytes32(obj, "swapWbtcStrategyId", a.swapWbtcStrategyId);
        json = vm.serializeBytes32(obj, "swapGhoStrategyId", a.swapGhoStrategyId);
        json = vm.serializeBytes32(obj, "swapXautStrategyId", a.swapXautStrategyId);
        json = vm.serializeBytes32(obj, "swapSyrupUsdcStrategyId", a.swapSyrupUsdcStrategyId);
        json = vm.serializeBytes32(obj, "aaveV3StrategyId", a.aaveV3StrategyId);
        json = vm.serializeBytes32(obj, "aaveV4StrategyId", a.aaveV4StrategyId);
        json = vm.serializeBytes32(obj, "mapleStrategyId", a.mapleStrategyId);
        json = vm.serializeAddress(obj, "aaveV3Pool", a.aaveV3Pool);
        json = vm.serializeAddress(obj, "aaveV3AUsdc", a.aaveV3AUsdc);
        json = vm.serializeUint(obj, "aaveV3ReferralCode", a.aaveV3ReferralCode);
        json = vm.serializeBool(obj, "aaveV3Enabled", a.aaveV3Enabled);
        json = vm.serializeAddress(obj, "aaveV4Spoke", a.aaveV4Spoke);
        json = vm.serializeAddress(obj, "aaveV4Giver", a.aaveV4Giver);
        json = vm.serializeUint(obj, "aaveV4UsdcReserveId", a.aaveV4UsdcReserveId);
        json = vm.serializeBool(obj, "aaveV4Enabled", a.aaveV4Enabled);
        json = vm.serializeAddress(obj, "mapleSyrupRouter", a.mapleSyrupRouter);
        json = vm.serializeAddress(obj, "mapleSyrupUsdc", a.mapleSyrupUsdc);
        json = vm.serializeBytes32(obj, "mapleDepositData", a.mapleDepositData);
        json = vm.serializeBool(obj, "mapleEnabled", a.mapleEnabled);
        json = vm.serializeUint(obj, "adapterLogicEpoch", a.adapterLogicEpoch);
        json = vm.serializeUint(obj, "adapterImplementationVersion", a.adapterImplementationVersion);
        json = vm.serializeUint(obj, "metroMaxSupply", a.metroMaxSupply);
        json = vm.serializeUint(obj, "maxCommissionSplitBps", a.maxCommissionSplitBps);
        json = vm.serializeUint(obj, "capThor", a.capThor);
        json = vm.serializeUint(obj, "capYThor", a.capYThor);
        json = vm.serializeUint(obj, "ratioThor", a.ratioThor);
        json = vm.serializeUint(obj, "ratioYThor", a.ratioYThor);
        json = vm.serializeUint(obj, "yThorRewardWeightBps", a.yThorRewardWeightBps);
        json = vm.serializeUint(obj, "migrationStartTime", a.migrationStartTime);
        json = vm.serializeUint(obj, "deadlineThor", a.deadlineThor);
        json = vm.serializeUint(obj, "deadlineYThor", a.deadlineYThor);
        vm.writeJson(json, path);
    }

    function _logDeployment(Addresses memory a) internal view {
        console2.log("=== xMETRO Deployment ===");
        console2.log("Chain ID:", a.chainId);
        console2.log("Deployer:", a.deployer);
        console2.log("Starting nonce:", a.deploymentNonce);
        console2.log("METRO:", a.metro);
        console2.log("xMETRO Core:", a.xMETRO);
        console2.log("Adapter Implementation:", a.deFiAdapterImplementation);
        console2.logBytes32(a.deFiAdapterImplementationCodehash);
        console2.log("Adapter Proxy:", a.deFiAdapterProxy);
        console2.log("Core adapter epoch:", a.adapterEpoch);
        console2.log("Adapter logic epoch:", a.adapterLogicEpoch);
        console2.log("Target owner:", a.owner);
        console2.log("Core owner:", a.coreOwner);
        console2.log("Core pending owner:", a.corePendingOwner);
        console2.log("Escrow owner:", a.escrowOwner);
        console2.log("Escrow pending owner:", a.escrowPendingOwner);
        console2.log("Distributor owner:", a.distributorOwner);
        console2.log("Distributor pending owner:", a.distributorPendingOwner);
        console2.log(
            a.corePendingOwner == address(0) && a.escrowPendingOwner == address(0)
                && a.distributorPendingOwner == address(0)
                ? "Ownership: Accepted"
                : "Ownership: Pending acceptance"
        );
        console2.log("RewardDistributor:", a.rewardDistributor);
        console2.log("ThorMigrationEscrow:", a.escrow);
        console2.log("Addresses written to:", _addressesPath());
    }
}
