// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MetroDistributorBase} from "./MetroDistributorBase.sol";

contract MetroDistributorV2 is MetroDistributorBase {
    error InvalidBucketBps();
    error BuybackNotImplemented();

    using SafeERC20 for IERC20;

    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable metro;

    uint16 public treasuryBps = 2_500;
    uint16 public buybackBps = 2_000;

    event BucketBpsUpdated(uint16 stakersBps, uint16 treasuryBps, uint16 buybackBps);
    event BuybackExecuted(uint256 usdcIn, uint256 metroOut);
    event MetroBurned(uint256 amount);

    constructor(address xMetro_, address treasury_, address owner_) MetroDistributorBase(xMetro_, treasury_, owner_) {
        metro = xMETRO.METRO();
        emit BucketBpsUpdated(stakersBps(), treasuryBps, buybackBps);
    }

    function setBucketBps(uint16 stakers, uint16 treasury_, uint16 buyback) external onlyOwner {
        require(uint256(stakers) + treasury_ + buyback == BPS_DENOMINATOR, InvalidBucketBps());
        treasuryBps = treasury_;
        buybackBps = buyback;
        emit BucketBpsUpdated(stakers, treasury_, buyback);
    }

    function stakersBps() public view returns (uint16) {
        return uint16(BPS_DENOMINATOR - treasuryBps - buybackBps);
    }

    function _bucketBps() internal view override returns (uint256, uint256) {
        return (treasuryBps, buybackBps);
    }

    function _routeMarketSupport(uint256 amount, uint256) internal override {
        uint256 metroOut = _buyMetro(amount);
        emit BuybackExecuted(amount, metroOut);
        if (metroOut != 0) {
            metro.safeTransfer(BURN_ADDRESS, metroOut);
            emit MetroBurned(metroOut);
        }
    }

    function _buyMetro(uint256) internal virtual returns (uint256) {
        // TODO: implement the Uniswap v4 USDC->METRO swap. It must add sandwich/MEV protection
        // (operator-supplied minMetroOut and/or an on-chain price bound, private RPC submission).
        revert BuybackNotImplemented();
    }
}
