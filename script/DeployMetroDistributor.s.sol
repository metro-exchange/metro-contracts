// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MetroDistributorBase, IxMETRO, ICommissionVault} from "../src/MetroDistributorBase.sol";
import {MetroDistributorV1} from "../src/MetroDistributorV1.sol";
import {MetroDistributorV2} from "../src/MetroDistributorV2.sol";

contract DeployMetroDistributor is Script {
    struct Input {
        uint256 version;
        address deployer;
        uint256 deployerPk;
        address owner;
        address xMetro;
        address commissionVault;
        address forwarder;
        address treasury;
        address polVault;
        uint256 maxCommissionSplitBps;
        address[] operators;
    }

    function run() external returns (address) {
        Input memory input = _loadAndValidateInput();

        if (input.deployerPk != 0) vm.startBroadcast(input.deployerPk);
        else vm.startBroadcast(input.deployer);

        MetroDistributorBase distributor = input.version == 1
            ? MetroDistributorBase(new MetroDistributorV1(input.xMetro, input.treasury, input.polVault, input.deployer))
            : MetroDistributorBase(new MetroDistributorV2(input.xMetro, input.treasury, input.deployer));
        if (input.forwarder != address(0)) distributor.setForwarder(input.forwarder);
        for (uint256 i; i < input.operators.length; ++i) {
            distributor.setOperator(input.operators[i], true);
        }
        if (input.owner != input.deployer) distributor.transferOwnership(input.owner);
        vm.stopBroadcast();

        _writeDeployment(input, distributor);
        _logOwnerBatch(input, distributor);
        return address(distributor);
    }

    function _loadAndValidateInput() internal view returns (Input memory i) {
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "DeployMetroDistributor: wrong chainId");
        i.version = vm.envUint("DISTRIBUTOR_VERSION");
        require(i.version == 1 || i.version == 2, "DeployMetroDistributor: version must be 1 or 2");
        i.deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        i.deployer = i.deployerPk != 0 ? vm.addr(i.deployerPk) : vm.envAddress("DEPLOYER_ADDRESS");
        i.owner = vm.envAddress("DISTRIBUTOR_OWNER");
        i.xMetro = vm.envAddress("DISTRIBUTOR_XMETRO");
        i.commissionVault = vm.envAddress("DISTRIBUTOR_COMMISSION_VAULT");
        i.forwarder = vm.envOr("DISTRIBUTOR_FORWARDER", address(0));
        i.treasury = vm.envAddress("DISTRIBUTOR_TREASURY");
        if (i.version == 1) i.polVault = vm.envAddress("DISTRIBUTOR_POL_VAULT");
        i.maxCommissionSplitBps = vm.envUint("DISTRIBUTOR_MAX_COMMISSION_SPLIT_BPS");
        i.operators = vm.envOr("DISTRIBUTOR_OPERATORS", ",", new address[](0));

        require(i.owner != address(0), "DeployMetroDistributor: zero owner");
        require(i.xMetro.code.length != 0, "DeployMetroDistributor: xMETRO has no code");
        require(i.commissionVault.code.length != 0, "DeployMetroDistributor: commission vault has no code");
        require(
            ICommissionVault(i.commissionVault).usdc() == address(IxMETRO(i.xMetro).rewardToken()),
            "DeployMetroDistributor: commission vault token mismatch"
        );
        require(i.maxCommissionSplitBps <= 10_000, "DeployMetroDistributor: bps above 10000");
    }

    function _writeDeployment(Input memory i, MetroDistributorBase distributor) internal {
        string memory dir = string.concat("deployments/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory obj = "metroDistributor";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeUint(obj, "version", i.version);
        vm.serializeAddress(obj, "distributor", address(distributor));
        vm.serializeBytes32(obj, "distributorCodehash", address(distributor).codehash);
        vm.serializeAddress(obj, "deployer", i.deployer);
        vm.serializeAddress(obj, "owner", distributor.owner());
        vm.serializeAddress(obj, "pendingOwner", distributor.pendingOwner());
        vm.serializeAddress(obj, "xMETRO", i.xMetro);
        vm.serializeAddress(obj, "commissionVault", i.commissionVault);
        vm.serializeUint(obj, "maxCommissionSplitBps", i.maxCommissionSplitBps);
        vm.serializeAddress(obj, "forwarder", i.forwarder);
        vm.serializeAddress(obj, "treasury", i.treasury);
        vm.serializeAddress(obj, "operators", i.operators);
        string memory json = vm.serializeAddress(obj, "polVault", i.polVault);
        vm.writeJson(json, string.concat(dir, "/metro-distributor-v", vm.toString(i.version), ".json"));
    }

    function _logOwnerBatch(Input memory i, MetroDistributorBase distributor) internal pure {
        console2.log("MetroDistributor version", i.version);
        console2.log("MetroDistributor", address(distributor));
        console2.log("Owner batch, in order:");
        if (i.owner != i.deployer) console2.log("- distributor.acceptOwnership()");
        console2.log("- CommissionVault(%s).setDistributor(%s)", i.commissionVault, address(distributor));
        console2.log("- distributor.setCommissionVault(%s)", i.commissionVault);
        console2.log("- distributor.setMaxCommissionSplitBps(%s)", i.maxCommissionSplitBps);
        console2.log("- xMETRO(%s).setRewardDistributor(%s)", i.xMetro, address(distributor));
        if (i.forwarder != address(0)) {
            console2.log("- Forwarder(%s).setRecipient(%s)", i.forwarder, address(distributor));
        }
    }
}
