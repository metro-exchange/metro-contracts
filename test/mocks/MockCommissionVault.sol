// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockCommissionVault {
    IERC20 public immutable usdc;
    address public distributor;
    uint256 public targetBalance;
    bool public revertRequiredTopUp;
    bool public migrationFinalized = true;
    bool public paused;

    constructor(address usdc_, uint256 targetBalance_, address distributor_) {
        usdc = IERC20(usdc_);
        targetBalance = targetBalance_;
        distributor = distributor_;
    }

    function setTargetBalance(uint256 value) external {
        targetBalance = value;
    }

    function setRevertRequiredTopUp(bool value) external {
        revertRequiredTopUp = value;
    }

    function setDistributor(address value) external {
        distributor = value;
    }

    function setMigrationFinalized(bool value) external {
        migrationFinalized = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function requiredTopUp() external view returns (uint256) {
        require(!revertRequiredTopUp, "MockVault: requiredTopUp failed");
        uint256 currentBalance = usdc.balanceOf(address(this));
        return currentBalance >= targetBalance ? 0 : targetBalance - currentBalance;
    }
}
