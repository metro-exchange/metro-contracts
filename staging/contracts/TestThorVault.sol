// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test copy of a THORSwap staking vault (vTHOR, uTHOR) for the QA contract set.
/// An ERC-4626 vault over the test THOR. With a reward token it also pays that token
/// pro rata to share holders, the way uTHOR pays USDC; without one it behaves like vTHOR.
contract TestThorVault is ERC4626 {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e30;

    address public immutable owner;
    IERC20 public immutable rewardToken;

    uint256 public rewardPerShare;
    mapping(address => uint256) private _paidPerShare;
    mapping(address => uint256) private _accrued;

    event RewardsAdded(uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);

    constructor(IERC20 thor, IERC20 rewardToken_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(thor)
    {
        owner = msg.sender;
        rewardToken = rewardToken_;
    }

    /// @notice Pulls reward tokens from the owner and splits them across the current share holders.
    function addRewards(uint256 amount) external {
        require(msg.sender == owner, "Not owner");
        require(address(rewardToken) != address(0), "No rewards");
        uint256 supply = totalSupply();
        require(supply > 0, "No shares");
        rewardPerShare += (amount * PRECISION) / supply;
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsAdded(amount);
    }

    function claimable(address user) public view returns (uint256) {
        return _accrued[user] + (balanceOf(user) * (rewardPerShare - _paidPerShare[user])) / PRECISION;
    }

    function claimRewards() external {
        uint256 amount = claimable(msg.sender);
        require(amount > 0, "Nothing to claim");
        _accrued[msg.sender] = 0;
        _paidPerShare[msg.sender] = rewardPerShare;
        rewardToken.safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        _settle(from);
        _settle(to);
        super._update(from, to, value);
    }

    function _settle(address user) private {
        if (user == address(0)) {
            return;
        }
        _accrued[user] = claimable(user);
        _paidPerShare[user] = rewardPerShare;
    }
}
