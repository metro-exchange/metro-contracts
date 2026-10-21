// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IMockGiverSpoke {
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }
    function getReserve(uint256 reserveId) external view returns (Reserve memory);
    function supply(uint256 reserveId, uint256 amount, address user) external returns (uint256, uint256);
}

/// @notice QA Giver that models token debits, Spoke calls, return values, and the tested events.
contract MockAaveV4Giver is Ownable {
    using SafeERC20 for IERC20;
    mapping(address => bool) public isSpokeRegistered;
    event RegisterSpoke(address indexed spoke, bool registered);
    event SupplyOnBehalfOf(
        address indexed spoke,
        address indexed caller,
        address indexed onBehalfOf,
        uint256 reserveId,
        uint256 suppliedShares,
        uint256 suppliedAmount
    );

    constructor(address spoke) Ownable(msg.sender) {
        isSpokeRegistered[spoke] = true;
        emit RegisterSpoke(spoke, true);
    }

    function registerSpoke(address spoke, bool registered) external onlyOwner {
        isSpokeRegistered[spoke] = registered;
        emit RegisterSpoke(spoke, registered);
    }

    function supplyOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address user)
        external
        returns (uint256 shares, uint256 assets)
    {
        require(isSpokeRegistered[spoke], "MockGiver: unregistered spoke");
        IERC20 asset = IERC20(IMockGiverSpoke(spoke).getReserve(reserveId).underlying);
        asset.safeTransferFrom(msg.sender, address(this), amount);
        asset.forceApprove(spoke, amount);
        (shares, assets) = IMockGiverSpoke(spoke).supply(reserveId, amount, user);
        emit SupplyOnBehalfOf(spoke, msg.sender, user, reserveId, shares, assets);
    }
}
