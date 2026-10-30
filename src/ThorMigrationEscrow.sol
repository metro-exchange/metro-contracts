// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IxMETROMigration {
    function creditThorFromMigration(address user, uint256 principal) external;
    function creditYThorFromMigration(address user, uint256 principal) external;
}

/// @title ThorMigrationEscrow
/// @notice Custodies migrated THOR/yTHOR and creates the corresponding locked METRO positions.
contract ThorMigrationEscrow is Ownable2Step, Pausable, ReentrancyGuardTransient {
    error ZeroXMetro();
    error ZeroMigrationToken();
    error InvalidMigrationStartTime();
    error MigrationNotStarted();
    error ZeroAmount();
    error ThorConfigurationMissing();
    error ThorMigrationExpired();
    error ZeroMintAmount();
    error ThorCapExceeded();
    error YThorConfigurationMissing();
    error YThorMigrationExpired();
    error YThorCapExceeded();
    error InvalidMigrationDeadline();
    error DeadlineNotAfterMigrationStart();
    error InvalidMigrationRatio();
    error MigrationRatiosLocked();
    error InvalidMigrationCap();
    error MigrationTokenRescueForbidden();
    error InvalidRecipient();

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
        require(xMETRO_ != address(0), ZeroXMetro());
        require(thor_ != address(0) && yThor_ != address(0), ZeroMigrationToken());
        require(migrationStartTime_ == 0 || migrationStartTime_ >= block.timestamp, InvalidMigrationStartTime());

        xMETRO = IxMETROMigration(xMETRO_);
        thorToken = IERC20(thor_);
        yThorToken = IERC20(yThor_);
        // Base QA only: zero starts the migration window in the deployment block.
        migrationStartTime = migrationStartTime_ == 0 ? block.timestamp : migrationStartTime_;
        emit MigrationStartTimeUpdated(migrationStartTime);
    }

    /// @notice Migrate THOR through the single project-configured conversion path.
    function migrateThor(uint256 amountIn) external nonReentrant whenNotPaused {
        require(block.timestamp >= migrationStartTime, MigrationNotStarted());
        require(amountIn > 0, ZeroAmount());
        require(capThor != 0 && ratioThor != 0, ThorConfigurationMissing());
        require(block.timestamp <= deadlineThor, ThorMigrationExpired());

        uint256 principal = Math.mulDiv(amountIn, ratioThor, 1e18);
        require(principal > 0, ZeroMintAmount());
        require(migratedThor + principal <= capThor, ThorCapExceeded());

        migratedThor += principal;

        thorToken.safeTransferFrom(msg.sender, address(this), amountIn);
        xMETRO.creditThorFromMigration(msg.sender, principal);

        emit MigratedThor(msg.sender, amountIn, principal);
    }

    /// @notice Migrate yTHOR into an active position whose future reward multiplier is managed by xMETRO.
    function migrateYThor(uint256 amountIn) external nonReentrant whenNotPaused {
        require(block.timestamp >= migrationStartTime, MigrationNotStarted());
        require(amountIn > 0, ZeroAmount());
        require(capYThor != 0 && ratioYThor != 0, YThorConfigurationMissing());
        require(block.timestamp <= deadlineYThor, YThorMigrationExpired());

        uint256 principal = Math.mulDiv(amountIn, ratioYThor, 1e18);
        require(principal > 0, ZeroMintAmount());
        require(migratedYThor + principal <= capYThor, YThorCapExceeded());
        migratedYThor += principal;

        yThorToken.safeTransferFrom(msg.sender, address(this), amountIn);
        xMETRO.creditYThorFromMigration(msg.sender, principal);

        emit MigratedYThor(msg.sender, amountIn, principal);
    }

    /// @notice Set migration start time (onlyOwner).
    function setMigrationStartTime(uint256 newStartTime) external onlyOwner {
        require(newStartTime >= block.timestamp, InvalidMigrationStartTime());
        migrationStartTime = newStartTime;
        emit MigrationStartTimeUpdated(newStartTime);
    }

    /// @notice Configure THOR and yTHOR migration deadlines.
    function setDeadlines(uint256 newDeadlineThor, uint256 newDeadlineYThor) external onlyOwner {
        require(newDeadlineThor >= block.timestamp && newDeadlineYThor >= block.timestamp, InvalidMigrationDeadline());
        require(
            newDeadlineThor > migrationStartTime && newDeadlineYThor > migrationStartTime,
            DeadlineNotAfterMigrationStart()
        );

        deadlineThor = newDeadlineThor;
        deadlineYThor = newDeadlineYThor;
        emit DeadlinesUpdated(newDeadlineThor, newDeadlineYThor);
    }

    /// @notice Configure the one-time, 1e18-scaled conversion ratios.
    function setRatios(uint256 newRatioThor, uint256 newRatioYThor) external onlyOwner {
        require(newRatioThor > 0 && newRatioYThor > 0, InvalidMigrationRatio());
        require(ratioThor == 0 && ratioYThor == 0, MigrationRatiosLocked());

        ratioThor = newRatioThor;
        ratioYThor = newRatioYThor;
        emit RatiosUpdated(newRatioThor, newRatioYThor);
    }

    /// @notice Configure principal caps, denominated in minted METRO.
    function setCaps(uint256 newCapThor, uint256 newCapYThor) external onlyOwner {
        require(newCapThor > 0 && newCapYThor > 0, InvalidMigrationCap());

        capThor = newCapThor;
        capYThor = newCapYThor;
        emit CapsUpdated(newCapThor, newCapYThor);
    }

    function renounceOwnership() public override onlyOwner whenNotPaused {
        super.renounceOwnership();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue unrelated tokens. Migration tokens are intentionally non-rescuable.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(thorToken) && token != address(yThorToken), MigrationTokenRescueForbidden());
        require(to != address(0), InvalidRecipient());
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }
}
