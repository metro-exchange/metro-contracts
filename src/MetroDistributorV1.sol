// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MetroDistributorBase} from "./MetroDistributorBase.sol";

contract MetroDistributorV1 is MetroDistributorBase {
    error ZeroPolVault();

    using SafeERC20 for IERC20;

    uint256 public constant STAKERS_BPS = 5_000;
    uint256 public constant TREASURY_BPS = 2_500;
    uint256 public constant POL_BUYBACK_BPS = 1_000;
    uint256 public constant POL_LIQUIDITY_BPS = 1_500;

    address public polVault;

    event PolVaultUpdated(address indexed oldPolVault, address indexed newPolVault);
    event PolVaultFunded(address indexed polVault, uint256 amount);
    event PolBuybackAllocated(uint256 amount);
    event PolLiquidityAllocated(uint256 amount);

    constructor(address xMetro_, address treasury_, address polVault_, address owner_)
        MetroDistributorBase(xMetro_, treasury_, owner_)
    {
        _setPolVault(polVault_);
    }

    function setPolVault(address newPolVault) external onlyOwner {
        _setPolVault(newPolVault);
    }

    function _bucketBps() internal pure override returns (uint256, uint256) {
        return (TREASURY_BPS, POL_BUYBACK_BPS + POL_LIQUIDITY_BPS);
    }

    function _routeThirdBucket(uint256 amount) internal override {
        address vault = polVault;
        rewardToken.safeTransfer(vault, amount);
        uint256 buybackAmount = Math.mulDiv(amount, POL_BUYBACK_BPS, POL_BUYBACK_BPS + POL_LIQUIDITY_BPS);
        emit PolVaultFunded(vault, amount);
        emit PolBuybackAllocated(buybackAmount);
        emit PolLiquidityAllocated(amount - buybackAmount);
    }

    function _setPolVault(address newPolVault) private {
        require(newPolVault != address(0), ZeroPolVault());
        emit PolVaultUpdated(polVault, newPolVault);
        polVault = newPolVault;
    }
}
