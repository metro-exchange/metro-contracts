// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IxMETROMigration {
    function creditThorFromMigration(address user, uint256 principal) external;
    function creditYThorFromMigration(address user, uint256 principal) external;
}

/// @title ThorMigrationEscrow
/// @notice Custodies migrated THOR/yTHOR and creates the corresponding locked METRO positions.
contract ThorMigrationEscrow is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IxMETROMigration public immutable xMETRO;
    IERC20 public immutable thorToken;
    IERC20 public immutable yThorToken;

    uint256 public migrationStartTime;

    uint256 public capThor;
    uint256 public migratedThor;
    uint256 public deadlineThor;
    uint256 public ratioThor;

    uint256 public capYThor;
    uint256 public migratedYThor;
    uint256 public deadlineYThor;
    uint256 public ratioYThor;

    event MigratedThor(address indexed user, uint256 amountIn, uint256 principal);
    event MigratedYThor(address indexed user, uint256 amountIn, uint256 principal);

    event DeadlinesUpdated(uint256 deadlineThor, uint256 deadlineYThor);
    event RatiosUpdated(uint256 ratioThor, uint256 ratioYThor);
    event CapsUpdated(uint256 capThor, uint256 capYThor);
    event MigrationStartTimeUpdated(uint256 migrationStartTime);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    constructor(address owner_, address xMETRO_, address thor_, address yThor_, uint256 migrationStartTime_)
        Ownable(owner_)
    {
        require(xMETRO_ != address(0), "ThorEscrow: zero xMETRO");
        require(thor_ != address(0) && yThor_ != address(0), "ThorEscrow: zero token");
        require(migrationStartTime_ == 0 || migrationStartTime_ >= block.timestamp, "ThorEscrow: bad start time");

        xMETRO = IxMETROMigration(xMETRO_);
        thorToken = IERC20(thor_);
        yThorToken = IERC20(yThor_);
        // Base QA only: zero starts the migration window in the deployment block.
        migrationStartTime = migrationStartTime_ == 0 ? block.timestamp : migrationStartTime_;
    }

    /// @notice Migrate THOR through the single project-configured conversion path.
    function migrateThor(uint256 amountIn) external nonReentrant whenNotPaused {
        require(block.timestamp >= migrationStartTime, "ThorEscrow: not started");
        require(amountIn > 0, "ThorEscrow: zero amount");
        require(capThor != 0 && ratioThor != 0, "ThorEscrow: thor config not set");
        require(block.timestamp <= deadlineThor, "ThorEscrow: thor expired");

        uint256 principal = Math.mulDiv(amountIn, ratioThor, 1e18);
        require(principal > 0, "ThorEscrow: zero mint");
        require(migratedThor + principal <= capThor, "ThorEscrow: thor cap");

        migratedThor += principal;

        thorToken.safeTransferFrom(msg.sender, address(this), amountIn);
        xMETRO.creditThorFromMigration(msg.sender, principal);

        emit MigratedThor(msg.sender, amountIn, principal);
    }

    /// @notice Migrate yTHOR into an active position whose future reward multiplier is managed by xMETRO.
    function migrateYThor(uint256 amountIn) external nonReentrant whenNotPaused {
        require(block.timestamp >= migrationStartTime, "ThorEscrow: not started");
        require(amountIn > 0, "ThorEscrow: zero amount");
        require(capYThor != 0 && ratioYThor != 0, "ThorEscrow: ythor config not set");
        require(block.timestamp <= deadlineYThor, "ThorEscrow: ythor expired");

        uint256 principal = Math.mulDiv(amountIn, ratioYThor, 1e18);
        require(principal > 0, "ThorEscrow: zero mint");
        require(migratedYThor + principal <= capYThor, "ThorEscrow: ythor cap");
        migratedYThor += principal;

        yThorToken.safeTransferFrom(msg.sender, address(this), amountIn);
        xMETRO.creditYThorFromMigration(msg.sender, principal);

        emit MigratedYThor(msg.sender, amountIn, principal);
    }

    /// @notice Set migration start time (onlyOwner).
    function setMigrationStartTime(uint256 newStartTime) external onlyOwner {
        require(newStartTime >= block.timestamp, "ThorEscrow: bad start time");
        migrationStartTime = newStartTime;
        emit MigrationStartTimeUpdated(newStartTime);
    }

    /// @notice Configure THOR and yTHOR migration deadlines.
    function setDeadlines(uint256 newDeadlineThor, uint256 newDeadlineYThor) external onlyOwner {
        require(newDeadlineThor >= block.timestamp && newDeadlineYThor >= block.timestamp, "ThorEscrow: bad deadline");
        require(
            newDeadlineThor > migrationStartTime && newDeadlineYThor > migrationStartTime,
            "ThorEscrow: deadline before start"
        );

        deadlineThor = newDeadlineThor;
        deadlineYThor = newDeadlineYThor;
        emit DeadlinesUpdated(newDeadlineThor, newDeadlineYThor);
    }

    /// @notice Configure the one-time, 1e18-scaled conversion ratios.
    function setRatios(uint256 newRatioThor, uint256 newRatioYThor) external onlyOwner {
        require(newRatioThor > 0 && newRatioYThor > 0, "ThorEscrow: bad ratio");
        require(ratioThor == 0 && ratioYThor == 0, "ThorEscrow: ratios locked");

        ratioThor = newRatioThor;
        ratioYThor = newRatioYThor;
        emit RatiosUpdated(newRatioThor, newRatioYThor);
    }

    /// @notice Configure principal caps, denominated in minted METRO.
    function setCaps(uint256 newCapThor, uint256 newCapYThor) external onlyOwner {
        require(newCapThor > 0 && newCapYThor > 0, "ThorEscrow: bad cap");

        capThor = newCapThor;
        capYThor = newCapYThor;
        emit CapsUpdated(newCapThor, newCapYThor);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue unrelated tokens. Migration tokens are intentionally non-rescuable.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(
            token != address(thorToken) && token != address(yThorToken), "ThorEscrow: cannot rescue migration tokens"
        );
        require(to != address(0), "ThorEscrow: bad to");
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }
}
