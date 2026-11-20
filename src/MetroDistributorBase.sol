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
    function METRO() external view returns (IERC20);
}

interface ICommissionVault {
    function requiredTopUp() external view returns (uint256);
    function usdc() external view returns (address);
    function distributor() external view returns (address);
    function migrationFinalized() external view returns (bool);
    function paused() external view returns (bool);
}

interface IRateLimitedForwarder {
    function tryForward() external returns (uint256 forwarded);
    function token() external view returns (IERC20);
}

abstract contract MetroDistributorBase is Ownable2Step, ReentrancyGuardTransient {
    error ZeroXMetro();
    error ZeroTreasury();
    error UnauthorizedOperator();
    error InvalidOperator();
    error CommissionSplitEnabled();
    error InvalidCommissionSplitBps();
    error ZeroAmount();
    error ZeroCommissionVault();
    error CommissionVaultNotContract();
    error CommissionTokenMismatch();
    error CommissionDistributorMismatch();
    error CommissionVaultMigrationPending();
    error CommissionVaultPaused();
    error ForwarderTokenMismatch();
    error InvalidRecipient();

    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    IxMETRO public immutable xMETRO;
    IERC20 public immutable rewardToken;

    mapping(address => bool) public operators;

    address public commissionVault;
    uint16 public maxCommissionSplitBps;
    IRateLimitedForwarder public forwarder;
    address public treasury;

    event OperatorUpdated(address indexed operator, bool allowed);
    event CommissionVaultUpdated(address indexed oldVault, address indexed newVault);
    event MaxCommissionSplitBpsUpdated(uint16 oldBps, uint16 newBps);
    event ForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event ForwarderPulled(address indexed forwarder, uint256 amount);
    event CommissionToppedUp(address indexed vault, uint256 amount);
    event TreasuryPaid(address indexed treasury, uint256 amount);
    event RewardsDistributed(address indexed caller, uint256 amount, uint64 timestamp);
    event Distributed(
        address indexed caller,
        uint256 grossAmount,
        uint256 commissionAmount,
        uint256 stakerAmount,
        uint256 treasuryAmount,
        uint256 thirdBucketAmount,
        uint64 timestamp
    );

    constructor(address xMetro_, address treasury_, address owner_) Ownable(owner_) {
        require(xMetro_ != address(0), ZeroXMetro());
        xMETRO = IxMETRO(xMetro_);
        rewardToken = IxMETRO(xMetro_).rewardToken();
        _setTreasury(treasury_);
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

    function setCommissionVault(address vault) external onlyOwner {
        if (vault == address(0)) {
            require(maxCommissionSplitBps == 0, CommissionSplitEnabled());
        } else {
            _validateCommissionVault(vault);
        }

        emit CommissionVaultUpdated(commissionVault, vault);
        commissionVault = vault;
    }

    function setMaxCommissionSplitBps(uint16 bps) external onlyOwner {
        require(bps <= BPS_DENOMINATOR, InvalidCommissionSplitBps());
        if (bps != 0) {
            _validateCommissionVault(commissionVault);
        }

        emit MaxCommissionSplitBpsUpdated(maxCommissionSplitBps, bps);
        maxCommissionSplitBps = bps;
    }

    function setForwarder(address newForwarder) external onlyOwner {
        if (newForwarder != address(0)) {
            require(IRateLimitedForwarder(newForwarder).token() == rewardToken, ForwarderTokenMismatch());
        }

        emit ForwarderUpdated(address(forwarder), newForwarder);
        forwarder = IRateLimitedForwarder(newForwarder);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        _setTreasury(newTreasury);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), InvalidRecipient());
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    function distribute(uint256 maxAmount) external onlyOperator nonReentrant {
        IRateLimitedForwarder source = forwarder;
        if (address(source) != address(0)) {
            uint256 pulled = source.tryForward();
            if (pulled != 0) emit ForwarderPulled(address(source), pulled);
        }

        uint256 grossAmount = rewardToken.balanceOf(address(this));
        if (maxAmount != 0) grossAmount = Math.min(grossAmount, maxAmount);
        require(grossAmount != 0, ZeroAmount());

        uint256 commissionAmount = _topUpCommission(grossAmount);
        uint256 remainder = grossAmount - commissionAmount;
        (uint256 treasuryBps, uint256 thirdBucketBps) = _bucketBps();
        uint256 treasuryAmount = Math.mulDiv(remainder, treasuryBps, BPS_DENOMINATOR);
        uint256 thirdBucketAmount = Math.mulDiv(remainder, thirdBucketBps, BPS_DENOMINATOR);
        uint256 stakerAmount = remainder - treasuryAmount - thirdBucketAmount;

        if (treasuryAmount != 0) {
            address recipient = treasury;
            rewardToken.safeTransfer(recipient, treasuryAmount);
            emit TreasuryPaid(recipient, treasuryAmount);
        }

        if (thirdBucketAmount != 0) _routeThirdBucket(thirdBucketAmount);

        uint64 timestamp = uint64(block.timestamp);
        if (stakerAmount != 0) {
            rewardToken.forceApprove(address(xMETRO), stakerAmount);
            xMETRO.depositRewards(stakerAmount);
            rewardToken.forceApprove(address(xMETRO), 0);
            emit RewardsDistributed(msg.sender, stakerAmount, timestamp);
        }

        emit Distributed(
            msg.sender, grossAmount, commissionAmount, stakerAmount, treasuryAmount, thirdBucketAmount, timestamp
        );
    }

    function _bucketBps() internal view virtual returns (uint256 treasuryBps, uint256 thirdBucketBps);

    function _routeThirdBucket(uint256 amount) internal virtual;

    function _topUpCommission(uint256 grossAmount) private returns (uint256 commissionAmount) {
        uint16 splitBps = maxCommissionSplitBps;
        if (splitBps == 0) return 0;

        address vault = commissionVault;
        _validateCommissionVault(vault);
        uint256 cap = Math.mulDiv(grossAmount, splitBps, BPS_DENOMINATOR);
        commissionAmount = Math.min(cap, ICommissionVault(vault).requiredTopUp());
        if (commissionAmount != 0) {
            rewardToken.safeTransfer(vault, commissionAmount);
            emit CommissionToppedUp(vault, commissionAmount);
        }
    }

    function _setTreasury(address newTreasury) private {
        require(newTreasury != address(0), ZeroTreasury());
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function _validateCommissionVault(address vault) private view {
        require(vault != address(0), ZeroCommissionVault());
        require(vault.code.length != 0, CommissionVaultNotContract());
        require(ICommissionVault(vault).usdc() == address(rewardToken), CommissionTokenMismatch());
        require(ICommissionVault(vault).distributor() == address(this), CommissionDistributorMismatch());
        require(ICommissionVault(vault).migrationFinalized(), CommissionVaultMigrationPending());
        require(!ICommissionVault(vault).paused(), CommissionVaultPaused());
    }
}
