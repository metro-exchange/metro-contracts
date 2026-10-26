// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {MetroToken} from "../src/metro.sol";
import {xMETRO} from "../src/xMETRO.sol";
import {RewardDistributor, ICommissionVault} from "../src/RewardDistributor.sol";
import {ThorMigrationEscrow} from "../src/ThorMigrationEscrow.sol";
import {IXMetroDeFiAdapter} from "../src/interfaces/IXMetroDeFiAdapter.sol";
import {DeFiAdapterScriptBase, IXMetroDeFiAdapterAdmin} from "./DeFiAdapterScriptBase.sol";

/// @notice Read-only post-broadcast check against the real target-chain RPC.
/// @dev The deployment script's JSON is a simulation record, not proof that transactions landed.
contract VerifyDeployment is DeFiAdapterScriptBase {
    using stdJson for string;

    function run() external view {
        string memory record = vm.readFile(vm.envString("DEPLOYMENT_JSON"));
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "VerifyDeploy: wrong chainId");
        require(record.readUint(".chainId") == block.chainid, "VerifyDeploy: manifest chainId");
        require(
            record.readBytes32(".adapterInitcodeHash") == vm.envBytes32("EXPECTED_ADAPTER_INITCODE_HASH"),
            "VerifyDeploy: approved artifact"
        );

        address deployer = record.readAddress(".deployer");
        uint256 nonce = record.readUint(".deploymentNonce");
        address metroAddress = record.readAddress(".metro");
        address coreAddress = record.readAddress(".xMETRO");
        address implementation = record.readAddress(".deFiAdapterImplementation");
        address proxy = record.readAddress(".deFiAdapterProxy");
        address distributorAddress = record.readAddress(".rewardDistributor");
        address escrowAddress = record.readAddress(".escrow");
        require(
            metroAddress == vm.computeCreateAddress(deployer, nonce)
                && coreAddress == vm.computeCreateAddress(deployer, nonce + 1)
                && implementation == vm.computeCreateAddress(deployer, nonce + 2)
                && proxy == vm.computeCreateAddress(deployer, nonce + 3)
                && distributorAddress == vm.computeCreateAddress(deployer, nonce + 4)
                && escrowAddress == vm.computeCreateAddress(deployer, nonce + 5),
            "VerifyDeploy: CREATE addresses"
        );
        _requireCodehash(metroAddress, record.readBytes32(".metroCodehash"));
        _requireCodehash(coreAddress, record.readBytes32(".xMetroCodehash"));
        _requireCodehash(implementation, record.readBytes32(".deFiAdapterImplementationCodehash"));
        _requireCodehash(proxy, record.readBytes32(".deFiAdapterProxyCodehash"));
        _requireCodehash(distributorAddress, record.readBytes32(".rewardDistributorCodehash"));
        _requireCodehash(escrowAddress, record.readBytes32(".escrowCodehash"));

        MetroToken metro = MetroToken(metroAddress);
        xMETRO core = xMETRO(coreAddress);
        IXMetroDeFiAdapterAdmin adapter = IXMetroDeFiAdapterAdmin(proxy);
        RewardDistributor distributor = RewardDistributor(distributorAddress);
        ThorMigrationEscrow escrow = ThorMigrationEscrow(escrowAddress);
        address owner = record.readAddress(".owner");
        address usdc = record.readAddress(".rewardToken");

        require(
            metro.owner() == owner && metro.cap() == 100_000_000 ether && metro.MAX_SUPPLY() == 100_000_000 ether
                && metro.cap() == record.readUint(".metroMaxSupply"),
            "VerifyDeploy: METRO"
        );
        require(metro.isMinter(coreAddress) && !metro.isMinter(deployer), "VerifyDeploy: minter");
        require(!core.paused(), "VerifyDeploy: Core paused");
        require(core.owner() == owner, "VerifyDeploy: Core ownership");
        require(
            address(core.METRO()) == metroAddress && address(core.rewardToken()) == usdc
                && core.forfeitureRecipient() == record.readAddress(".forfeitureRecipient")
                && core.migrationRewardExcludedAddress() == record.readAddress(".migrationRewardExcludedAddress")
                && core.rewardDistributor() == distributorAddress && core.migrationEscrow() == escrowAddress
                && core.deFiAdapter() == proxy && core.deFiAdapterEpoch() == record.readUint(".adapterEpoch")
                && core.yThorRewardWeightBps() == record.readUint(".yThorRewardWeightBps"),
            "VerifyDeploy: Core bindings"
        );
        address keeper = record.readAddress(".autoCompoundOperator");
        if (keeper != address(0)) require(core.autoCompoundOperators(keeper), "VerifyDeploy: Keeper");

        _requireImplementation(implementation, 1);
        _requireProxySlots(proxy, implementation);
        require(record.readAddress(".proxyImplementationReadback") == implementation, "VerifyDeploy: proxy record");
        AdapterConfiguration memory config = _requireProxyBindings(proxy, coreAddress, usdc, metroAddress);
        require(
            config.epoch == record.readUint(".adapterLogicEpoch")
                && adapter.implementationVersion() == record.readUint(".adapterImplementationVersion")
                && config.routerV2 == record.readAddress(".routerV2")
                && config.routerV3 == record.readAddress(".routerV3")
                && config.oneInchRouter == record.readAddress(".oneInchRouter"),
            "VerifyDeploy: Adapter config"
        );
        _verifyStrategies(record, adapter, metroAddress, config);
        _requireNoAllowance(usdc, coreAddress, proxy);
        _requireNoAllowance(usdc, proxy, config.routerV2);
        _requireNoAllowance(usdc, proxy, config.routerV3);
        _requireNoAllowance(usdc, proxy, config.oneInchRouter);
        _requireNoAllowance(usdc, proxy, config.aaveV3.pool);
        _requireNoAllowance(usdc, proxy, config.aaveV4.spoke);
        _requireNoAllowance(usdc, proxy, config.aaveV4Giver);
        _requireNoAllowance(usdc, proxy, config.maple.router);

        require(distributor.owner() == owner, "VerifyDeploy: Distributor owner");
        require(
            address(distributor.xMETRO()) == coreAddress && address(distributor.rewardToken()) == usdc
                && distributor.commissionVault() == record.readAddress(".commissionVault")
                && distributor.maxCommissionSplitBps() == record.readUint(".maxCommissionSplitBps"),
            "VerifyDeploy: Distributor config"
        );
        address operator = record.readAddress(".distributorOperator");
        if (operator != address(0)) require(distributor.operators(operator), "VerifyDeploy: Distributor operator");
        _verifyCommissionVault(record, distributorAddress, usdc);

        require(
            escrow.owner() == owner && address(escrow.xMETRO()) == coreAddress
                && address(escrow.thorToken()) == record.readAddress(".thor")
                && address(escrow.yThorToken()) == record.readAddress(".yThor")
                && escrow.migrationStartTime() == record.readUint(".migrationStartTime")
                && escrow.capThor() == record.readUint(".capThor") && escrow.capYThor() == record.readUint(".capYThor")
                && escrow.ratioThor() == record.readUint(".ratioThor")
                && escrow.ratioYThor() == record.readUint(".ratioYThor")
                && escrow.deadlineThor() == record.readUint(".deadlineThor")
                && escrow.deadlineYThor() == record.readUint(".deadlineYThor"),
            "VerifyDeploy: Escrow"
        );
        console2.log("Deployment verified on chain", block.chainid);
        console2.log("xMETRO:", coreAddress);
        console2.log("Adapter Proxy:", proxy);
    }

    function _verifyStrategies(
        string memory record,
        IXMetroDeFiAdapterAdmin adapter,
        address metroAddress,
        AdapterConfiguration memory config
    ) internal view {
        bool swapEnabled = config.routerV2 != address(0);
        _checkStrategy(
            adapter,
            record.readBytes32(".swapMetroStrategyId"),
            IXMetroDeFiAdapter.StrategyKind.SwapMetro,
            metroAddress,
            swapEnabled
        );
        _checkOutput(record, adapter, ".tokenOutUsdt", ".swapUsdtStrategyId");
        _checkOutput(record, adapter, ".tokenOutWbtc", ".swapWbtcStrategyId");
        _checkOutput(record, adapter, ".tokenOutGho", ".swapGhoStrategyId");
        _checkOutput(record, adapter, ".tokenOutXaut", ".swapXautStrategyId");
        _checkOutput(record, adapter, ".tokenOutSyrupUsdc", ".swapSyrupUsdcStrategyId");

        bool v3Enabled = record.readBool(".aaveV3Enabled");
        bool v4Enabled = record.readBool(".aaveV4Enabled");
        bool mapleEnabled = record.readBool(".mapleEnabled");
        require(
            config.aaveV3.pool == record.readAddress(".aaveV3Pool")
                && config.aaveV3.aToken == record.readAddress(".aaveV3AUsdc")
                && config.aaveV3.referralCode == record.readUint(".aaveV3ReferralCode")
                && config.aaveV4.spoke == record.readAddress(".aaveV4Spoke")
                && config.aaveV4Giver == record.readAddress(".aaveV4Giver")
                && config.aaveV4.reserveId == record.readUint(".aaveV4UsdcReserveId")
                && config.maple.router == record.readAddress(".mapleSyrupRouter")
                && config.maple.syrupToken == record.readAddress(".mapleSyrupUsdc")
                && config.maple.depositData == record.readBytes32(".mapleDepositData"),
            "VerifyDeploy: deposit configs"
        );
        _checkStrategy(
            adapter,
            record.readBytes32(".aaveV3StrategyId"),
            IXMetroDeFiAdapter.StrategyKind.AaveV3,
            config.aaveV3.aToken,
            v3Enabled
        );
        _checkStrategy(
            adapter,
            record.readBytes32(".aaveV4StrategyId"),
            IXMetroDeFiAdapter.StrategyKind.AaveV4,
            address(0),
            v4Enabled
        );
        _checkStrategy(
            adapter,
            record.readBytes32(".mapleStrategyId"),
            IXMetroDeFiAdapter.StrategyKind.Maple,
            config.maple.syrupToken,
            mapleEnabled
        );
    }

    function _checkOutput(
        string memory record,
        IXMetroDeFiAdapterAdmin adapter,
        string memory tokenKey,
        string memory idKey
    ) internal view {
        address token = record.readAddress(tokenKey);
        bytes32 id = record.readBytes32(idKey);
        require((token == address(0)) == (id == bytes32(0)), "VerifyDeploy: output inventory");
        if (token != address(0)) {
            _checkStrategy(adapter, id, IXMetroDeFiAdapter.StrategyKind.AutoSwap, token, true);
        }
    }

    function _checkStrategy(
        IXMetroDeFiAdapterAdmin adapter,
        bytes32 id,
        IXMetroDeFiAdapter.StrategyKind kind,
        address token,
        bool enabled
    ) internal view {
        if (id == bytes32(0)) {
            require(!enabled, "VerifyDeploy: missing strategy");
            return;
        }
        require(id == _strategyId(kind, token), "VerifyDeploy: strategy id");
        IXMetroDeFiAdapter.StrategyInfo memory info = adapter.strategyInfo(id);
        require(
            info.kind == kind && info.outputToken == token && info.enabled == enabled && info.autoEnabled == enabled,
            "VerifyDeploy: strategy state"
        );
    }

    function _verifyCommissionVault(string memory record, address distributor, address usdc) internal view {
        address vault = record.readAddress(".commissionVault");
        if (vault == address(0)) return;
        _requireCodehash(vault, record.readBytes32(".commissionVaultCodehash"));
        require(
            ICommissionVault(vault).usdc() == usdc && ICommissionVault(vault).distributor() == distributor
                && ICommissionVault(vault).migrationFinalized() && !ICommissionVault(vault).paused(),
            "VerifyDeploy: Commission Vault"
        );
    }

    function _requireCodehash(address target, bytes32 expected) internal view {
        require(
            target.code.length != 0 && expected != bytes32(0) && target.codehash == expected, "VerifyDeploy: codehash"
        );
    }
}
