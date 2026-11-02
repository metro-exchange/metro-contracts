// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IxMETRO {
    function depositRewards(uint256 amount) external;
    function rewardToken() external view returns (IERC20);
}

interface ICommissionVault {
    function requiredTopUp() external view returns (uint256);
    function usdc() external view returns (address);
    function distributor() external view returns (address);
    function migrationFinalized() external view returns (bool);
    function paused() external view returns (bool);
}

/// @title RewardDistributor
/// @notice Routes a capped portion of each USDC distribution to CommissionVault and the remainder to xMETRO.
contract RewardDistributor is Ownable2Step, ReentrancyGuardTransient {
    error ZeroXMetro();
    error UnauthorizedOperator();
    error InvalidOperator();
    error CommissionSplitEnabled();
    error InvalidCommissionSplitBps();
    error ZeroAmount();
    error InsufficientRewardBalance();
    error ZeroCommissionVault();
    error CommissionVaultNotContract();
    error CommissionTokenMismatch();
    error CommissionDistributorMismatch();
    error CommissionVaultMigrationPending();
    error CommissionVaultPaused();
    error InvalidRecipient();

    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    IxMETRO public immutable xMETRO;
    IERC20 public immutable rewardToken;

    mapping(address => bool) public operators;

    address public commissionVault;
    uint16 public maxCommissionSplitBps;

    /// @notice Retained for indexer compatibility. `amount` is the net reward deposited into xMETRO.
    event RewardsDistributed(address indexed caller, uint256 amount, uint64 timestamp);
    event OperatorUpdated(address indexed operator, bool allowed);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event CommissionVaultUpdated(address indexed oldVault, address indexed newVault);
    event MaxCommissionSplitBpsUpdated(uint16 oldBps, uint16 newBps);
    event DistributionRouted(
        address indexed caller,
        address indexed commissionVault,
        uint256 grossAmount,
        uint256 commissionAmount,
        uint256 netReward,
        uint64 timestamp
    );

    constructor(address xMetro_, address owner_) Ownable(owner_) {
        require(xMetro_ != address(0), ZeroXMetro());
        xMETRO = IxMETRO(xMetro_);
        rewardToken = IxMETRO(xMetro_).rewardToken();
    }

    modifier onlyOperator() {
        require(operators[msg.sender], UnauthorizedOperator());
        _;
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), InvalidOperator());
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    /// @notice Set or migrate the CommissionVault. Clear only after disabling the split.
    function setCommissionVault(address vault) external onlyOwner {
        if (vault == address(0)) {
            require(maxCommissionSplitBps == 0, CommissionSplitEnabled());
        } else {
            _validateCommissionVault(vault);
        }

        address oldVault = commissionVault;
        commissionVault = vault;
        emit CommissionVaultUpdated(oldVault, vault);
    }

    /// @notice Set the per-distribution CommissionVault ceiling. Zero disables top-ups.
    function setMaxCommissionSplitBps(uint16 bps) external onlyOwner {
        require(bps <= BPS_DENOMINATOR, InvalidCommissionSplitBps());
        if (bps != 0) {
            _validateCommissionVault(commissionVault);
        }

        uint16 oldBps = maxCommissionSplitBps;
        maxCommissionSplitBps = bps;
        emit MaxCommissionSplitBpsUpdated(oldBps, bps);
    }

    /// @notice Pull a gross reward amount from an operator and route it.
    function distribute(uint256 amount) external onlyOperator nonReentrant {
        require(amount > 0, ZeroAmount());
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        _routeDistribution(amount);
    }

    /// @notice Route a gross reward amount already held by this contract.
    function distributeFromBalance(uint256 amount) external onlyOperator nonReentrant {
        require(amount > 0, ZeroAmount());
        require(rewardToken.balanceOf(address(this)) >= amount, InsufficientRewardBalance());
        _routeDistribution(amount);
    }

    function _routeDistribution(uint256 grossAmount) internal returns (uint256 commissionAmount, uint256 netReward) {
        uint16 splitBps = maxCommissionSplitBps;
        address vaultUsed = address(0);

        if (splitBps != 0) {
            vaultUsed = commissionVault;
            _validateCommissionVault(vaultUsed);

            uint256 cap = Math.mulDiv(grossAmount, splitBps, BPS_DENOMINATOR);
            uint256 shortfall = ICommissionVault(vaultUsed).requiredTopUp();
            commissionAmount = Math.min(cap, shortfall);

            if (commissionAmount != 0) {
                rewardToken.safeTransfer(vaultUsed, commissionAmount);
            }
        }

        netReward = grossAmount - commissionAmount;
        if (netReward != 0) {
            rewardToken.forceApprove(address(xMETRO), netReward);
            xMETRO.depositRewards(netReward);
            rewardToken.forceApprove(address(xMETRO), 0);
        }

        uint64 timestamp = uint64(block.timestamp);
        emit RewardsDistributed(msg.sender, netReward, timestamp);
        emit DistributionRouted(msg.sender, vaultUsed, grossAmount, commissionAmount, netReward, timestamp);
    }

    function _validateCommissionVault(address vault) internal view {
        require(vault != address(0), ZeroCommissionVault());
        require(vault.code.length != 0, CommissionVaultNotContract());
        require(ICommissionVault(vault).usdc() == address(rewardToken), CommissionTokenMismatch());
        require(ICommissionVault(vault).distributor() == address(this), CommissionDistributorMismatch());
        require(ICommissionVault(vault).migrationFinalized(), CommissionVaultMigrationPending());
        require(!ICommissionVault(vault).paused(), CommissionVaultPaused());
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), InvalidRecipient());
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }
}
