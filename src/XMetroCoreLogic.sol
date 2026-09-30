// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Internal-only Core state helpers. Every function is inlined into xMETRO;
///      this source creates no linked/deployed business Library.
library XMetroCoreLogic {
    error NoRewards();
    error InvalidAddress();
    error InvalidAmount();
    error UserNotAuthorized();
    error InvalidConfiguration();

    bytes32 internal constant MIGRATION_STORAGE_LOCATION =
        0x427fcf91de87d612093b6e8edf157454b8509e2ae8d2b0077cdae916e2bcfb00;

    uint256 private constant DEFAULT_MAX_VESTING_SCHEDULES = 50;
    uint64 private constant THOR_EXIT_DELAY = 3600 seconds;
    uint64 private constant THOR_EXIT_FULL_TIME = 10800 seconds;
    uint64 private constant YTHOR_EXIT_DELAY = 14400 seconds;
    uint64 private constant YTHOR_EXIT_RAMP = 43200 seconds;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant THOR_EXIT_START_BPS = 5_000;
    uint256 private constant YTHOR_EXIT_START_BPS = 1_000;
    uint256 private constant YTHOR_EXIT_MAX_BPS = 5_000;
    uint64 private constant CONTRIBUTOR_CLIFF = 21600 seconds;
    uint64 private constant CONTRIBUTOR_DURATION = 21600 seconds;

    struct Position {
        uint128 principal;
        uint64 migratedAt;
        uint64 exitedAt;
        bool exited;
    }

    struct ContributorVesting {
        uint128 totalAmount;
        uint128 claimed;
        uint64 startTime;
        uint64 duration;
    }

    struct ExitResult {
        uint256 principal;
        uint256 payout;
        uint256 forfeited;
        uint256 rateBps;
        uint64 exitedAt;
    }

    /// @custom:storage-location erc7201:xmetro.storage.migration.v1
    struct MigrationStorage {
        mapping(address user => Position position) thorPositions;
        mapping(address user => Position position) yThorPositions;
        mapping(address user => ContributorVesting[] schedules) contributorVestings;
        mapping(address user => uint256 cursor) contributorVestCursor;
        mapping(address contributor => bool allowed) contributorWhitelist;
        uint256 defaultMaxVestingSchedules;
    }

    function migrationStorage() internal pure returns (MigrationStorage storage state) {
        bytes32 slot = MIGRATION_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := slot
        }
    }

    function defaultMaxVestingSchedules() internal view returns (uint256) {
        return _defaultMaxVestingSchedules(migrationStorage());
    }

    function setDefaultMaxVestingSchedules(uint256 newDefault) internal {
        if (newDefault == 0) revert InvalidAmount();
        migrationStorage().defaultMaxVestingSchedules = newDefault;
    }

    function contributorWhitelist(address contributor) internal view returns (bool) {
        return migrationStorage().contributorWhitelist[contributor];
    }

    function setContributor(address contributor, bool allowed) internal {
        if (contributor == address(0)) revert InvalidAddress();
        migrationStorage().contributorWhitelist[contributor] = allowed;
    }

    function createContributorVesting(address contributor, address receiver, uint256 amount)
        internal
        returns (uint64 startTime, uint64 duration)
    {
        MigrationStorage storage state = migrationStorage();
        if (!state.contributorWhitelist[contributor]) revert UserNotAuthorized();
        if (amount == 0 || amount > type(uint128).max) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();

        startTime = uint64(block.timestamp) + CONTRIBUTOR_CLIFF;
        duration = CONTRIBUTOR_DURATION;
        state.contributorVestings[receiver].push(ContributorVesting(uint128(amount), 0, startTime, duration));
    }

    function consumeContributorVesting(address user, uint256 maxVestingSchedules) internal returns (uint256 unlocked) {
        MigrationStorage storage state = migrationStorage();
        ContributorVesting[] storage schedules = state.contributorVestings[user];
        uint256 len = schedules.length;
        uint256 max = maxVestingSchedules;
        if (max == 0) max = _defaultMaxVestingSchedules(state);
        if (max > len) max = len;

        if (len != 0) {
            uint256 index = state.contributorVestCursor[user] % len;
            uint64 timestamp = uint64(block.timestamp);
            for (uint256 i; i < max; ++i) {
                ContributorVesting storage schedule = schedules[index];
                uint256 releasable = _releasable(schedule, timestamp);
                if (releasable != 0) {
                    schedule.claimed = uint128(uint256(schedule.claimed) + releasable);
                    unlocked += releasable;
                }
                index = index + 1 == len ? 0 : index + 1;
            }
            state.contributorVestCursor[user] = index;
        }

        if (unlocked == 0) revert NoRewards();
        if (unlocked > type(uint128).max) revert InvalidAmount();
    }

    function contributorVestCursor(address user) internal view returns (uint256) {
        return migrationStorage().contributorVestCursor[user];
    }

    function contributorVestingCount(address user) internal view returns (uint256) {
        return migrationStorage().contributorVestings[user].length;
    }

    function contributorVesting(address user, uint256 index)
        internal
        view
        returns (uint128 totalAmount, uint128 claimed, uint64 startTime, uint64 duration)
    {
        ContributorVesting storage schedule = migrationStorage().contributorVestings[user][index];
        return (schedule.totalAmount, schedule.claimed, schedule.startTime, schedule.duration);
    }

    function createThorPosition(address user, uint256 principal) internal returns (uint64 migratedAt) {
        return _createPosition(migrationStorage().thorPositions[user], user, principal);
    }

    function createYThorPosition(address user, uint256 principal) internal returns (uint64 migratedAt) {
        return _createPosition(migrationStorage().yThorPositions[user], user, principal);
    }

    function getThorPosition(address user)
        internal
        view
        returns (uint128 principal, uint64 migratedAt, uint64 exitedAt, bool exited)
    {
        return _getPosition(migrationStorage().thorPositions[user]);
    }

    function getYThorPosition(address user)
        internal
        view
        returns (uint128 principal, uint64 migratedAt, uint64 exitedAt, bool exited)
    {
        return _getPosition(migrationStorage().yThorPositions[user]);
    }

    function activeYThorPrincipal(address user) internal view returns (uint256) {
        Position storage position = migrationStorage().yThorPositions[user];
        return position.exited ? 0 : uint256(position.principal);
    }

    function previewThorExit(address user)
        internal
        view
        returns (bool eligible, uint256 rateBps, uint256 payout, uint256 forfeited, uint256 eligibleAt)
    {
        return _previewExit(migrationStorage().thorPositions[user], false);
    }

    function previewYThorExit(address user)
        internal
        view
        returns (bool eligible, uint256 rateBps, uint256 payout, uint256 forfeited, uint256 eligibleAt)
    {
        return _previewExit(migrationStorage().yThorPositions[user], true);
    }

    function consumeThorExit(address user) internal returns (ExitResult memory result) {
        return _consumeExit(migrationStorage().thorPositions[user], false);
    }

    function consumeYThorExit(address user) internal returns (ExitResult memory result) {
        return _consumeExit(migrationStorage().yThorPositions[user], true);
    }

    function previewMigrationWithdrawableNow(address user)
        internal
        view
        returns (
            uint256 thorUnlockable,
            uint256 yThorUnlockable,
            uint256 contributorUnlockable,
            uint256 totalUnlockable
        )
    {
        MigrationStorage storage state = migrationStorage();
        (bool thorEligible,, uint256 thorPayout,,) = _previewExit(state.thorPositions[user], false);
        (bool yThorEligible,, uint256 yThorPayout,,) = _previewExit(state.yThorPositions[user], true);
        if (thorEligible) thorUnlockable = thorPayout;
        if (yThorEligible) yThorUnlockable = yThorPayout;

        ContributorVesting[] storage schedules = state.contributorVestings[user];
        uint64 timestamp = uint64(block.timestamp);
        for (uint256 i; i < schedules.length; ++i) {
            contributorUnlockable += _releasable(schedules[i], timestamp);
        }
        totalUnlockable = thorUnlockable + yThorUnlockable + contributorUnlockable;
    }

    function _defaultMaxVestingSchedules(MigrationStorage storage state) private view returns (uint256) {
        uint256 configured = state.defaultMaxVestingSchedules;
        return configured == 0 ? DEFAULT_MAX_VESTING_SCHEDULES : configured;
    }

    function _releasable(ContributorVesting storage schedule, uint64 timestamp) private view returns (uint256) {
        uint256 vested = _vestingSchedule(schedule.totalAmount, timestamp, schedule.startTime, schedule.duration);
        return vested <= schedule.claimed ? 0 : vested - schedule.claimed;
    }

    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp, uint64 startTime, uint64 duration)
        private
        pure
        returns (uint256)
    {
        if (timestamp < startTime) return 0;
        uint64 endTime = startTime + duration;
        if (timestamp >= endTime) return totalAllocation;
        return (totalAllocation * (timestamp - startTime)) / duration;
    }

    function _createPosition(Position storage position, address user, uint256 principal)
        private
        returns (uint64 migratedAt)
    {
        if (user == address(0)) revert InvalidAddress();
        if (principal == 0 || principal > type(uint128).max) revert InvalidAmount();
        if (position.principal != 0) revert InvalidConfiguration();
        migratedAt = uint64(block.timestamp);
        position.principal = uint128(principal);
        position.migratedAt = migratedAt;
    }

    function _getPosition(Position storage position)
        private
        view
        returns (uint128 principal, uint64 migratedAt, uint64 exitedAt, bool exited)
    {
        return (position.principal, position.migratedAt, position.exitedAt, position.exited);
    }

    function _consumeExit(Position storage position, bool yThor) private returns (ExitResult memory result) {
        if (position.principal == 0) revert NoRewards();
        (bool eligible, uint256 rateBps, uint256 payout, uint256 forfeited,) = _previewExit(position, yThor);
        if (!eligible) revert InvalidConfiguration();
        position.exited = true;
        position.exitedAt = uint64(block.timestamp);
        result = ExitResult(uint256(position.principal), payout, forfeited, rateBps, position.exitedAt);
    }

    function _previewExit(Position storage position, bool yThor)
        private
        view
        returns (bool eligible, uint256 rateBps, uint256 payout, uint256 forfeited, uint256 eligibleAt)
    {
        if (position.principal == 0) return (false, 0, 0, 0, 0);
        eligibleAt = uint256(position.migratedAt) + (yThor ? YTHOR_EXIT_DELAY : THOR_EXIT_DELAY);
        if (position.exited || block.timestamp < eligibleAt) return (false, 0, 0, 0, eligibleAt);
        eligible = true;
        rateBps = yThor ? _yThorExitRateBps(position.migratedAt) : _thorExitRateBps(position.migratedAt);
        payout = (uint256(position.principal) * rateBps) / BPS_DENOMINATOR;
        forfeited = uint256(position.principal) - payout;
    }

    function _thorExitRateBps(uint64 migratedAt) private view returns (uint256) {
        uint256 elapsed = block.timestamp - uint256(migratedAt);
        if (elapsed >= THOR_EXIT_FULL_TIME) return BPS_DENOMINATOR;
        return THOR_EXIT_START_BPS + ((elapsed - THOR_EXIT_DELAY) * (BPS_DENOMINATOR - THOR_EXIT_START_BPS))
            / (THOR_EXIT_FULL_TIME - THOR_EXIT_DELAY);
    }

    function _yThorExitRateBps(uint64 migratedAt) private view returns (uint256) {
        uint256 eligibleAt = uint256(migratedAt) + YTHOR_EXIT_DELAY;
        uint256 elapsedSinceEligible = block.timestamp - eligibleAt;
        if (elapsedSinceEligible >= YTHOR_EXIT_RAMP) return YTHOR_EXIT_MAX_BPS;
        return
            YTHOR_EXIT_START_BPS + (elapsedSinceEligible * (YTHOR_EXIT_MAX_BPS - YTHOR_EXIT_START_BPS))
                / YTHOR_EXIT_RAMP;
    }
}
