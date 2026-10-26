// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IXMetroDeFiAdapter} from "./interfaces/IXMetroDeFiAdapter.sol";
import {XMetroCoreLogic} from "./XMetroCoreLogic.sol";

interface IMetroTokenMintable is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IBoundRewardDistributor {
    function rewardToken() external view returns (address);
}

contract xMETRO is ERC20, Pausable, ReentrancyGuard, Ownable {
    error Unauthorized();
    error NoRewards();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidArrayLength();
    error InvalidConfiguration();
    error UnauthorizedOperator();
    error NothingToWithdraw();
    error ProtectedToken();

    using SafeERC20 for IERC20;

    uint256 private constant ACC_PRECISION = 1e24;
    uint256 private constant MAX_YTHOR_REWARD_WEIGHT_BPS = type(uint128).max;
    bytes32 private constant ADAPTER_FAMILY_ID = keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    bytes32 private constant STRATEGY_DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");
    bytes4 private constant XMETRO_BINDING_SELECTOR = bytes4(keccak256("xMETRO()"));

    uint64 public constant UNSTAKE_DELAY = 72 hours;

    uint64 public constant YTHOR_EXIT_RAMP = 4 * 365 days;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 public constant THOR_EXIT_START_BPS = 5_000;
    uint256 public constant YTHOR_EXIT_START_BPS = 2_000;
    uint256 public constant YTHOR_EXIT_MAX_BPS = 10_000;

    uint64 public constant CONTRIBUTOR_CLIFF = 180 days;

    uint64 public constant CONTRIBUTOR_DURATION = (5 * 365 days) / 2;

    uint256 public totalLockedShares;

    uint256 public accRewardPerShare;
    uint256 private _accYThorRewardPerPrincipal;

    /// @notice Source category for a cooldown request entry.
    enum UnstakeSource {
        Free,
        Thor,
        YThor,
        Contributor
    }

    enum ExitMode {
        Liquid,
        Stake
    }

    /// @notice Contributor vesting schedule entry (cliff handled by `startTime`).
    struct VestingSchedule {
        uint128 totalAmount;
        uint128 claimed;
        uint64 startTime;
        uint64 duration;
    }

    /// @notice Unstake/withdraw request: claim METRO after `unlockTime`.
    struct UnstakeRequest {
        uint128 amount;
        uint64 unlockTime;
    }

    struct PendingBatch {
        address[] users;
        uint256[] amounts;
        uint256[] sourceIndexes;
        uint256 total;
    }

    struct AutoStrategyPreference {
        bytes32 strategyId;
        uint64 adapterEpoch;
        uint64 logicEpoch;
        uint64 domainRevision;
        uint64 strategyRevision;
    }

    IMetroTokenMintable public immutable METRO;

    IERC20 public immutable rewardToken;

    address public immutable forfeitureRecipient;

    /// @notice Fixed address whose THOR and yTHOR migration positions earn no rewards.
    address public immutable migrationRewardExcludedAddress;

    bytes32 private immutable SWAP_METRO_STRATEGY_ID;

    address public rewardDistributor;

    address public deFiAdapter;

    uint64 public deFiAdapterEpoch;

    address public migrationEscrow;

    /// @notice Operators allowed to call `autocompoundBatch`.
    mapping(address => bool) public autoCompoundOperators;

    /// @notice Whether the user has enabled autocompounding.
    mapping(address => bool) public autocompoundEnabled;

    mapping(address => AutoStrategyPreference) private _autoStrategyPreferences;

    /// @notice user => locked shares (not transferable; used for rewards baseline).
    mapping(address => uint256) public lockedShares;

    uint256 public yThorRewardWeightBps;
    uint256 private _totalActiveYThorPrincipal;

    /// @dev Signed debt in accumulator precision; payment preserves unpayable fractions.
    mapping(address => int256) private _rewardDebtScaled;

    /// @dev user => cooldown request queues (split by source).
    mapping(address => UnstakeRequest[]) private _unstakeRequestsFree;
    mapping(address => UnstakeRequest[]) private _unstakeRequestsThor;
    mapping(address => UnstakeRequest[]) private _unstakeRequestsYThor;
    mapping(address => UnstakeRequest[]) private _unstakeRequestsContributor;

    /// @notice user => cursor for batched cooldown request processing (split by source).
    mapping(address => uint256) public unstakeCursorFree;
    mapping(address => uint256) public unstakeCursorThor;
    mapping(address => uint256) public unstakeCursorYThor;
    mapping(address => uint256) public unstakeCursorContributor;

    /// @dev Active THOR principal of the fixed excluded address; backing remains fully recorded.
    uint256 private _rewardExcludedThorPrincipal;

    event RewardDistributorUpdated(address indexed oldRewardDistributor, address indexed newRewardDistributor);
    event DeFiAdapterUpdated(address indexed oldAdapter, address indexed newAdapter, uint64 adapterEpoch);
    event AutoStrategyPreferenceUpdated(
        address indexed user, bytes32 indexed oldStrategyId, bytes32 indexed newStrategyId
    );
    event ClaimAndExecuted(address indexed user, bytes32 indexed strategyId, uint256 rewardIn, uint256 amountOut);
    event AutoStrategyBatchExecuted(
        address indexed operator,
        bytes32 indexed strategyId,
        uint256 processedUsers,
        uint256 totalRewardIn,
        uint256 amountOut
    );
    event EmergencyRewardDistributed(address indexed user, uint256 amount);
    event EmergencyBatchExecuted(address indexed operator, uint256 processedUsers, uint256 totalDistributed);
    event DefaultMaxVestingSchedulesUpdated(uint256 maxVestingSchedules);

    event MigrationEscrowUpdated(address indexed oldMigrationEscrow, address indexed newMigrationEscrow);

    event ThorPositionCreated(address indexed user, uint256 indexed positionId, uint256 principal, uint64 migratedAt);
    event YThorPositionCreated(address indexed user, uint256 indexed positionId, uint256 principal, uint64 migratedAt);
    event YThorRewardWeightBpsUpdated(uint256 oldWeightBps, uint256 newWeightBps);
    event ThorExited(
        address indexed user,
        uint256 indexed positionId,
        uint256 principal,
        uint256 payout,
        uint256 forfeited,
        uint256 rateBps,
        ExitMode mode,
        uint64 exitedAt,
        address indexed forfeitureRecipient
    );
    event YThorExited(
        address indexed user,
        uint256 indexed positionId,
        uint256 principal,
        uint256 payout,
        uint256 forfeited,
        uint256 rateBps,
        ExitMode mode,
        uint64 exitedAt,
        address indexed forfeitureRecipient
    );
    event RewardsDeposited(address indexed payer, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount, uint256 mintedShares);

    event UnstakeRequested(address indexed user, UnstakeSource indexed source, uint256 amount, uint64 unlockTime);
    event Withdrawn(address indexed user, UnstakeSource indexed source, uint256 amount);

    event AutoCompounded(address indexed user, uint256 usdcIn, uint256 metroOut);

    event AutoCompoundOperatorUpdated(address indexed operator, bool allowed);

    event AutocompoundEnabledUpdated(address indexed user, bool enabled);

    event AutocompoundBatchExecuted(address indexed operator, uint256 totalUsdcIn, uint256 totalMetroOut);

    event ContributorWhitelistUpdated(address indexed contributor, bool allowed);

    event ContributorStaked(
        address indexed contributor, address indexed receiver, uint256 amount, uint64 startTime, uint64 duration
    );

    event UnlockedClaimedAsShares(address indexed user, UnstakeSource indexed source, uint256 amount);

    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address owner_,
        address metro_,
        address rewardToken_,
        address forfeitureRecipient_,
        uint256 initialYThorRewardWeightBps_
    ) Ownable(owner_) ERC20("xMETRO", "xMETRO") {
        if (metro_ == address(0) || rewardToken_ == address(0) || forfeitureRecipient_ == address(0)) {
            revert InvalidAddress();
        }
        if (initialYThorRewardWeightBps_ > MAX_YTHOR_REWARD_WEIGHT_BPS) revert InvalidConfiguration();
        METRO = IMetroTokenMintable(metro_);
        rewardToken = IERC20(rewardToken_);
        forfeitureRecipient = forfeitureRecipient_;
        migrationRewardExcludedAddress = forfeitureRecipient_;
        yThorRewardWeightBps = initialYThorRewardWeightBps_;
        SWAP_METRO_STRATEGY_ID =
            keccak256(abi.encode(block.chainid, STRATEGY_DOMAIN, IXMetroDeFiAdapter.StrategyKind.SwapMetro, metro_));
    }

    modifier onlyMigrationEscrow() {
        if (msg.sender != migrationEscrow) revert Unauthorized();
        _;
    }

    /// @notice Stake METRO and receive 1:1 free shares (xMETRO ERC20).
    function stake(uint256 amount) external nonReentrant whenNotPaused returns (uint256 mintedShares) {
        if (amount == 0) revert InvalidAmount();
        IERC20(address(METRO)).safeTransferFrom(msg.sender, address(this), amount);
        _mintFreeShares(msg.sender, amount);
        mintedShares = amount;
        emit Staked(msg.sender, amount, mintedShares);
    }

    /// @notice Stake METRO and enable autocompounding in a single transaction.
    function stakeAndEnableAutocompound(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 mintedShares)
    {
        if (amount == 0) revert InvalidAmount();
        IERC20(address(METRO)).safeTransferFrom(msg.sender, address(this), amount);
        _mintFreeShares(msg.sender, amount);
        mintedShares = amount;
        emit Staked(msg.sender, amount, mintedShares);
        _enableAutocompound(msg.sender);
    }

    /// @notice Request unstake for free shares; burns shares immediately and starts a cooldown.
    function requestUnstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0 || amount > type(uint128).max || balanceOf(msg.sender) < amount) revert InvalidAmount();

        _burnFreeShares(msg.sender, amount);

        uint64 unlockTime = uint64(block.timestamp) + UNSTAKE_DELAY;
        _unstakeRequestsFree[msg.sender].push(UnstakeRequest(uint128(amount), unlockTime));

        emit UnstakeRequested(msg.sender, UnstakeSource.Free, amount, unlockTime);
    }

    function _withdrawFromQueue(UnstakeRequest[] storage requests, uint256 cursor, uint256 maxRequests)
        private
        view
        returns (uint256 newCursor, uint256 totalToSend)
    {
        uint256 len = requests.length;
        if (cursor >= len) return (cursor, 0);

        uint256 processedCount = 0;
        while (cursor < len) {
            UnstakeRequest memory r = requests[cursor];
            if (r.unlockTime > block.timestamp) break;

            totalToSend += uint256(r.amount);
            cursor++;
            processedCount++;

            if (maxRequests != 0 && processedCount >= maxRequests) break;
        }

        return (cursor, totalToSend);
    }

    /// @notice Withdraw matured cooldown requests from the Free queue and receive METRO.
    /// @param maxRequests Max number of matured requests to process (0 = as many as possible).
    function withdrawFree(uint256 maxRequests) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        return _withdraw(msg.sender, UnstakeSource.Free, maxRequests);
    }

    /// @notice Withdraw matured cooldown requests from the Thor queue and receive METRO.
    /// @param maxRequests Max number of matured requests to process (0 = as many as possible).
    function withdrawThor(uint256 maxRequests) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        return _withdraw(msg.sender, UnstakeSource.Thor, maxRequests);
    }

    /// @notice Withdraw matured cooldown requests from the YThor queue and receive METRO.
    /// @param maxRequests Max number of matured requests to process (0 = as many as possible).
    function withdrawYThor(uint256 maxRequests) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        return _withdraw(msg.sender, UnstakeSource.YThor, maxRequests);
    }

    /// @notice Withdraw matured cooldown requests from the Contributor queue and receive METRO.
    /// @param maxRequests Max number of matured requests to process (0 = as many as possible).
    function withdrawContributor(uint256 maxRequests) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        return _withdraw(msg.sender, UnstakeSource.Contributor, maxRequests);
    }

    function _withdraw(address user, UnstakeSource source, uint256 maxRequests) private returns (uint256 amountOut) {
        UnstakeRequest[] storage requests;
        uint256 cursor;
        if (source == UnstakeSource.Free) {
            requests = _unstakeRequestsFree[user];
            cursor = unstakeCursorFree[user];
        } else if (source == UnstakeSource.Thor) {
            requests = _unstakeRequestsThor[user];
            cursor = unstakeCursorThor[user];
        } else if (source == UnstakeSource.YThor) {
            requests = _unstakeRequestsYThor[user];
            cursor = unstakeCursorYThor[user];
        } else {
            requests = _unstakeRequestsContributor[user];
            cursor = unstakeCursorContributor[user];
        }
        if (cursor >= requests.length) return 0;

        (uint256 newCursor, uint256 totalToSend) = _withdrawFromQueue(requests, cursor, maxRequests);
        if (totalToSend == 0) revert NothingToWithdraw();
        if (source == UnstakeSource.Free) unstakeCursorFree[user] = newCursor;
        else if (source == UnstakeSource.Thor) unstakeCursorThor[user] = newCursor;
        else if (source == UnstakeSource.YThor) unstakeCursorYThor[user] = newCursor;
        else unstakeCursorContributor[user] = newCursor;

        IERC20(address(METRO)).safeTransfer(user, totalToSend);
        emit Withdrawn(user, source, totalToSend);
        return totalToSend;
    }

    /// @notice Deposit rewardToken using the current base-share and yTHOR reward weights.
    function depositRewards(uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != rewardDistributor) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        (uint256 activeYThor, uint256 yThorWeight, uint256 weight) = _rewardWeights();
        if (weight == 0) revert InvalidConfiguration();

        uint256 delta = (amount * ACC_PRECISION) / weight;
        if (delta == 0) revert InvalidAmount();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        accRewardPerShare += delta;
        if (yThorWeight != 0) {
            _accYThorRewardPerPrincipal += Math.mulDiv(delta, yThorWeight, activeYThor);
        }

        emit RewardsDeposited(msg.sender, amount);
    }

    /// @notice Claim pending rewards in rewardToken.
    function claimRewards() external nonReentrant whenNotPaused returns (uint256 pending) {
        (pending,) = _pendingAndAccumulated(msg.sender);
        _recordRewardPayment(msg.sender, pending);

        if (pending > 0) {
            rewardToken.safeTransfer(msg.sender, pending);
        }

        emit RewardClaimed(msg.sender, pending);
        return pending;
    }

    function claimAndExecute(bytes32 id, uint256 minAmountOut, uint256 deadline, bytes calldata executionData)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 rewardAmount, uint256 amountOut)
    {
        IXMetroDeFiAdapter.StrategyInfo memory info = _requireStrategy(id, false);
        if (info.kind == IXMetroDeFiAdapter.StrategyKind.SwapMetro) revert InvalidConfiguration();
        rewardAmount = _consumePendingReward(msg.sender);
        IXMetroDeFiAdapter.ExecutionResult memory result =
            _executeManual(info, id, msg.sender, rewardAmount, minAmountOut, deadline, executionData);
        amountOut = result.amountOut;
        emit ClaimAndExecuted(msg.sender, id, rewardAmount, amountOut);
    }

    function enableAutoStrategy(bytes32 id) external whenNotPaused {
        IXMetroDeFiAdapter.StrategyInfo memory info = _requireStrategy(id, true);
        if (info.kind == IXMetroDeFiAdapter.StrategyKind.SwapMetro) revert InvalidConfiguration();
        _setAutoPreference(msg.sender, id, info, false);
    }

    function disableAutoStrategy() external {
        if (autocompoundEnabled[msg.sender]) return;
        bytes32 oldStrategyId = _autoStrategyPreferences[msg.sender].strategyId;
        if (oldStrategyId == bytes32(0)) return;
        delete _autoStrategyPreferences[msg.sender];
        emit AutoStrategyPreferenceUpdated(msg.sender, oldStrategyId, bytes32(0));
    }

    function getAutoStrategyPreference(address user) external view returns (AutoStrategyPreference memory) {
        return _autoStrategyPreferences[user];
    }

    function executeAutoStrategyBatch(
        bytes32 id,
        address[] calldata candidates,
        uint256 minTotalAmountOut,
        uint256[] calldata minUserAmountsOut,
        uint256 deadline,
        bytes calldata executionData
    ) external nonReentrant whenNotPaused returns (uint256 totalRewardAmount, uint256 amountOut) {
        if (!autoCompoundOperators[msg.sender]) revert UnauthorizedOperator();
        IXMetroDeFiAdapter.StrategyInfo memory info = _requireStrategy(id, true);
        if (info.kind == IXMetroDeFiAdapter.StrategyKind.SwapMetro) revert InvalidConfiguration();
        PendingBatch memory batch = _collectActionPending(candidates, id, false, info);
        uint256[] memory minima = _compactMinima(info.kind, candidates.length, minUserAmountsOut, batch);
        IXMetroDeFiAdapter.ExecutionResult memory result =
            _executeBatch(info, id, batch, minTotalAmountOut, minima, deadline, executionData);
        amountOut = result.amountOut;
        emit AutoStrategyBatchExecuted(msg.sender, id, batch.users.length, batch.total, amountOut);
        return (batch.total, amountOut);
    }

    /// @notice Autocompound: swap user's pending rewards (rewardToken) into METRO and mint received amount as free shares.
    /// @param minMetroOut Slippage protection: minimum METRO to receive.
    /// @param swapData Typed routing data consumed by the active DeFi Adapter.
    function autocompound(uint256 minMetroOut, uint256 deadline, bytes calldata swapData)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return _autocompound(msg.sender, minMetroOut, deadline, swapData);
    }

    function enableAutocompound() external whenNotPaused {
        _enableAutocompound(msg.sender);
    }

    function disableAutocompound() external {
        if (!autocompoundEnabled[msg.sender]) return;
        autocompoundEnabled[msg.sender] = false;
        emit AutocompoundEnabledUpdated(msg.sender, false);
        bytes32 oldStrategyId = _autoStrategyPreferences[msg.sender].strategyId;
        delete _autoStrategyPreferences[msg.sender];
        emit AutoStrategyPreferenceUpdated(msg.sender, oldStrategyId, bytes32(0));
    }

    /**
     * @notice Batch autocompound: aggregate a set of users' pending USDC, swap it into METRO, then mint xMETRO pro-rata by pending.
     * @dev The user list is maintained off-chain by the bot and passed in via calldata; the contract also checks `autocompoundEnabled[user] == true`.
     */
    function autocompoundBatch(address[] calldata users, uint256 minMetroOut, uint256 deadline, bytes calldata swapData)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        if (!autoCompoundOperators[msg.sender]) revert UnauthorizedOperator();
        bytes32 id = SWAP_METRO_STRATEGY_ID;
        IXMetroDeFiAdapter.StrategyInfo memory info = _requireStrategy(id, true);
        PendingBatch memory batch = _collectActionPending(users, id, true, info);
        IXMetroDeFiAdapter.ExecutionResult memory result =
            _executeBatch(info, id, batch, minMetroOut, new uint256[](0), deadline, swapData);
        uint256 received = result.amountOut;
        _distributeCompound(batch, received);
        emit AutocompoundBatchExecuted(msg.sender, batch.total, received);
        return received;
    }

    /// @dev When free shares move, move the corresponding reward debt to avoid leaking past rewards.
    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        _moveFreeSharesDebt(_msgSender(), to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
        _moveFreeSharesDebt(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    /// @notice Pays only rewards already accrued in this xMETRO reward ledger and held as rewardToken.
    /// @dev This is not a permanent shutdown or METRO-principal migration path. The existing owner
    ///      rewardToken rescue trust boundary remains unchanged, and any failed user transfer reverts
    ///      the complete batch together with every rewardDebt update.
    function emergencyDistribute(address[] calldata users)
        external
        onlyOwner
        nonReentrant
        whenPaused
        returns (uint256 totalDistributed)
    {
        if (users.length == 0) revert InvalidArrayLength();
        uint256 processedUsers;
        for (uint256 i; i < users.length; ++i) {
            address user = users[i];
            if (user == address(0)) continue;
            (uint256 pending,) = _pendingAndAccumulated(user);
            if (pending == 0) continue;
            _recordRewardPayment(user, pending);
            rewardToken.safeTransfer(user, pending);
            totalDistributed += pending;
            ++processedUsers;
            emit EmergencyRewardDistributed(user, pending);
        }
        if (processedUsers == 0) revert NoRewards();
        emit EmergencyBatchExecuted(msg.sender, processedUsers, totalDistributed);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Update the reward multiplier used by every active yTHOR position for future reward deposits.
    function setYThorRewardWeightBps(uint256 newWeightBps) external onlyOwner {
        if (newWeightBps > MAX_YTHOR_REWARD_WEIGHT_BPS) revert InvalidConfiguration();
        uint256 oldWeightBps = yThorRewardWeightBps;
        yThorRewardWeightBps = newWeightBps;
        emit YThorRewardWeightBpsUpdated(oldWeightBps, newWeightBps);
    }

    /// @notice Bind or replace the stable Adapter Proxy.
    function setDeFiAdapter(address adapter_) external onlyOwner {
        address oldAdapter = deFiAdapter;
        if (
            adapter_ == address(this) || adapter_ == address(rewardToken) || adapter_ == address(METRO)
                || adapter_ == oldAdapter
        ) revert InvalidAddress();
        if (!_validAdapterBindings(adapter_)) revert InvalidConfiguration();
        deFiAdapter = adapter_;
        ++deFiAdapterEpoch;
        emit DeFiAdapterUpdated(oldAdapter, adapter_, deFiAdapterEpoch);
    }

    /// @notice Set the migration escrow allowed to call the THOR/yTHOR credit entrypoints.
    function setMigrationEscrow(address escrow) external onlyOwner {
        if (_readStaticWord(escrow, XMETRO_BINDING_SELECTOR) != bytes32(uint256(uint160(address(this))))) {
            revert InvalidAddress();
        }
        address oldMigrationEscrow = migrationEscrow;
        migrationEscrow = escrow;
        emit MigrationEscrowUpdated(oldMigrationEscrow, escrow);
    }

    /// @notice Set RewardDistributor (the only caller allowed to `depositRewards`).
    function setRewardDistributor(address distributor) external onlyOwner {
        if (
            _readStaticWord(distributor, XMETRO_BINDING_SELECTOR) != bytes32(uint256(uint160(address(this))))
                || _readStaticWord(distributor, IBoundRewardDistributor.rewardToken.selector)
                    != bytes32(uint256(uint160(address(rewardToken))))
        ) revert InvalidAddress();
        address oldRewardDistributor = rewardDistributor;
        rewardDistributor = distributor;
        emit RewardDistributorUpdated(oldRewardDistributor, distributor);
    }

    /// @notice Set/unset an operator allowed to call `autocompoundBatch`.
    function setAutoCompoundOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert InvalidAddress();
        autoCompoundOperators[operator] = allowed;
        emit AutoCompoundOperatorUpdated(operator, allowed);
    }

    function defaultMaxVestingSchedules() external view returns (uint256) {
        return XMetroCoreLogic.defaultMaxVestingSchedules();
    }

    /// @notice Set default max vesting schedules processed per checkpoint call.
    function setDefaultMaxVestingSchedules(uint256 newDefault) external onlyOwner {
        XMetroCoreLogic.setDefaultMaxVestingSchedules(newDefault);
        emit DefaultMaxVestingSchedulesUpdated(newDefault);
    }

    function contributorWhitelist(address contributor) external view returns (bool) {
        return XMetroCoreLogic.contributorWhitelist(contributor);
    }

    /// @notice Allow or revoke a contributor address (whitelist).
    /// @dev Only whitelisted contributors can call `stakeContributor`.
    function setContributor(address contributor, bool allowed) external onlyOwner {
        XMetroCoreLogic.setContributor(contributor, allowed);
        emit ContributorWhitelistUpdated(contributor, allowed);
    }

    /// @notice Stake METRO as a contributor and create a locked vesting position (6m cliff + 2.5y linear release).
    /// @param receiver Address credited with the contributor vesting position.
    /// @dev Only callable by `contributorWhitelist[msg.sender] == true`. Funds are pulled from `msg.sender`.
    function stakeContributor(uint256 amount, address receiver) external nonReentrant whenNotPaused {
        (uint64 startTime, uint64 duration) = XMetroCoreLogic.createContributorVesting(msg.sender, receiver, amount);

        IERC20(address(METRO)).safeTransferFrom(msg.sender, address(this), amount);

        _increaseLockedShares(receiver, amount, false);
        emit ContributorStaked(msg.sender, receiver, amount, startTime, duration);
    }

    function thorPositionCount(address user) external view returns (uint256) {
        return XMetroCoreLogic.thorPositionCount(user);
    }

    function yThorPositionCount(address user) external view returns (uint256) {
        return XMetroCoreLogic.yThorPositionCount(user);
    }

    function thorPositions(address user, uint256 positionId)
        external
        view
        returns (uint128 principal, uint64 migratedAt, uint64 exitedAt, bool exited)
    {
        return XMetroCoreLogic.getThorPosition(user, positionId);
    }

    function yThorPositions(address user, uint256 positionId)
        external
        view
        returns (uint128 principal, uint64 migratedAt, uint64 exitedAt, bool exited)
    {
        return XMetroCoreLogic.getYThorPosition(user, positionId);
    }

    /// @notice Preview a selected THOR position's one-time exit at the current timestamp.
    function previewThorExit(address user, uint256 positionId)
        external
        view
        returns (bool eligible, uint256 rateBps, uint256 payout, uint256 forfeited, uint256 eligibleAt)
    {
        return XMetroCoreLogic.previewThorExit(user, positionId);
    }

    /// @notice Close the selected THOR position and queue liquid METRO for the 72-hour cooldown.
    function requestThorExit(uint256 positionId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 payout, uint256 forfeited)
    {
        return _exitThor(msg.sender, positionId, ExitMode.Liquid);
    }

    /// @notice Close the selected THOR position and convert its payout directly into free xMETRO.
    function exitAndStakeThor(uint256 positionId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 payout, uint256 forfeited)
    {
        return _exitThor(msg.sender, positionId, ExitMode.Stake);
    }

    /// @notice Preview a selected yTHOR position's one-time exit at the current timestamp.
    function previewYThorExit(address user, uint256 positionId)
        external
        view
        returns (bool eligible, uint256 rateBps, uint256 payout, uint256 forfeited, uint256 eligibleAt)
    {
        return XMetroCoreLogic.previewYThorExit(user, positionId);
    }

    /// @notice Close the selected yTHOR position using either a liquid cooldown or direct xMETRO stake payout.
    function exitYThor(uint256 positionId, ExitMode mode)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 payout, uint256 forfeited)
    {
        return _exitYThor(msg.sender, positionId, mode);
    }

    /// @notice Request withdrawal for currently-vested contributor principal.
    /// @param maxSchedules Max number of vesting schedules to scan/consume (0 uses `defaultMaxVestingSchedules`).
    function requestWithdrawUnlockedContributor(uint256 maxSchedules)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountQueued)
    {
        uint256 unlocked = XMetroCoreLogic.consumeContributorVesting(msg.sender, maxSchedules);
        _decreaseLockedShares(msg.sender, unlocked, false);
        uint64 unlockTime = uint64(block.timestamp) + UNSTAKE_DELAY;
        _unstakeRequestsContributor[msg.sender].push(UnstakeRequest(uint128(unlocked), unlockTime));
        emit UnstakeRequested(msg.sender, UnstakeSource.Contributor, unlocked, unlockTime);
        return unlocked;
    }

    /// @notice Convert currently-vested contributor principal into transferable xMETRO (free shares).
    /// @dev This does NOT withdraw METRO; it only moves the user's shares from `lockedShares` into ERC20 `balanceOf`.
    /// @param maxSchedules Max number of vesting schedules to scan/consume (0 uses `defaultMaxVestingSchedules`).
    function claimAndStakeUnlockedContributor(uint256 maxSchedules)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 sharesMinted)
    {
        uint256 unlocked = XMetroCoreLogic.consumeContributorVesting(msg.sender, maxSchedules);
        _decreaseLockedShares(msg.sender, unlocked, false);
        _mintFreeShares(msg.sender, unlocked);
        emit UnlockedClaimedAsShares(msg.sender, UnstakeSource.Contributor, unlocked);
        return unlocked;
    }

    /// @notice Migration flow: mint METRO and create a new independently timed THOR position.
    function creditThorFromMigration(address user, uint256 principal)
        external
        nonReentrant
        whenNotPaused
        onlyMigrationEscrow
    {
        (uint256 positionId, uint64 migratedAt) = XMetroCoreLogic.createThorPosition(user, principal);
        _increaseLockedShares(user, principal, true);

        METRO.mint(address(this), principal);
        emit ThorPositionCreated(user, positionId, principal, migratedAt);
    }

    /// @notice Migration flow: mint METRO and create a new independently timed yTHOR reward position.
    function creditYThorFromMigration(address user, uint256 principal)
        external
        nonReentrant
        whenNotPaused
        onlyMigrationEscrow
    {
        (uint256 positionId, uint64 migratedAt) = XMetroCoreLogic.createYThorPosition(user, principal);
        _increaseYThorShares(user, principal);

        METRO.mint(address(this), principal);
        emit YThorPositionCreated(user, positionId, principal, migratedAt);
    }

    /// @notice Rescue tokens (METRO excluded).
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(METRO)) revert ProtectedToken();
        if (to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    function _exitThor(address user, uint256 positionId, ExitMode mode)
        internal
        returns (uint256 payout, uint256 forfeited)
    {
        XMetroCoreLogic.ExitResult memory result = XMetroCoreLogic.consumeThorExit(user, positionId);
        _decreaseLockedShares(user, result.principal, true);

        _deliverExitPayout(user, result.payout, UnstakeSource.Thor, mode);
        if (result.forfeited > 0) {
            IERC20(address(METRO)).safeTransfer(forfeitureRecipient, result.forfeited);
        }
        emit ThorExited(
            user,
            positionId,
            result.principal,
            result.payout,
            result.forfeited,
            result.rateBps,
            mode,
            result.exitedAt,
            forfeitureRecipient
        );
        return (result.payout, result.forfeited);
    }

    function _exitYThor(address user, uint256 positionId, ExitMode mode)
        internal
        returns (uint256 payout, uint256 forfeited)
    {
        XMetroCoreLogic.ExitResult memory result = XMetroCoreLogic.consumeYThorExit(user, positionId);
        _decreaseYThorShares(user, result.principal);

        _deliverExitPayout(user, result.payout, UnstakeSource.YThor, mode);
        if (result.forfeited > 0) {
            IERC20(address(METRO)).safeTransfer(forfeitureRecipient, result.forfeited);
        }
        emit YThorExited(
            user,
            positionId,
            result.principal,
            result.payout,
            result.forfeited,
            result.rateBps,
            mode,
            result.exitedAt,
            forfeitureRecipient
        );
        return (result.payout, result.forfeited);
    }

    function _deliverExitPayout(address user, uint256 amount, UnstakeSource source, ExitMode mode) internal {
        if (amount == 0) return;

        if (mode == ExitMode.Stake) {
            _mintFreeShares(user, amount);
            emit UnlockedClaimedAsShares(user, source, amount);
            return;
        }

        uint64 unlockTime = uint64(block.timestamp) + UNSTAKE_DELAY;
        if (source == UnstakeSource.Thor) {
            _unstakeRequestsThor[user].push(UnstakeRequest(uint128(amount), unlockTime));
        } else {
            _unstakeRequestsYThor[user].push(UnstakeRequest(uint128(amount), unlockTime));
        }
        emit UnstakeRequested(user, source, amount, unlockTime);
    }

    /// @dev Compute base-share and yTHOR rewards without rewriting either historical accumulator.
    function _pendingAndAccumulated(address user) internal view returns (uint256 pending, int256 accumulated) {
        (uint256 baseShares, uint256 yThorPrincipal) = _rewardSharesOf(user);
        accumulated =
            _debtDelta(baseShares, accRewardPerShare) + _debtDelta(yThorPrincipal, _accYThorRewardPerPrincipal);
        int256 debt = _rewardDebtScaled[user];
        if (accumulated <= debt) return (0, accumulated);
        pending = uint256(accumulated - debt) / ACC_PRECISION;
    }

    function _consumePendingReward(address user) internal returns (uint256 pending) {
        (pending,) = _pendingAndAccumulated(user);
        if (pending == 0) revert NoRewards();
        _recordRewardPayment(user, pending);
    }

    function _collectActionPending(
        address[] calldata candidates,
        bytes32 id,
        bool compound,
        IXMetroDeFiAdapter.StrategyInfo memory info
    ) internal returns (PendingBatch memory batch) {
        uint256 length = candidates.length;
        if (length == 0) revert InvalidArrayLength();
        address[] memory users = new address[](length);
        uint256[] memory amounts = new uint256[](length);
        uint256[] memory sourceIndexes = new uint256[](length);
        uint256 count;
        uint256 total;

        for (uint256 i; i < length; ++i) {
            address user = candidates[i];
            if (user == address(0)) continue;
            AutoStrategyPreference storage preference = _autoStrategyPreferences[user];
            if (compound && !autocompoundEnabled[user]) continue;
            if (preference.strategyId != id || !_preferenceCurrent(preference, info)) continue;

            (uint256 pending,) = _pendingAndAccumulated(user);
            if (pending == 0) continue;
            _recordRewardPayment(user, pending);
            users[count] = user;
            amounts[count] = pending;
            sourceIndexes[count] = i;
            total += pending;
            ++count;
        }

        if (count == 0) revert NoRewards();
        assembly ("memory-safe") {
            mstore(users, count)
            mstore(amounts, count)
            mstore(sourceIndexes, count)
        }
        batch = PendingBatch(users, amounts, sourceIndexes, total);
    }

    function _enableAutocompound(address user) internal {
        bytes32 id = SWAP_METRO_STRATEGY_ID;
        IXMetroDeFiAdapter.StrategyInfo memory info = _requireStrategy(id, true);
        _setAutoPreference(user, id, info, true);
    }

    function _setAutoPreference(address user, bytes32 id, IXMetroDeFiAdapter.StrategyInfo memory info, bool compound)
        internal
    {
        bytes32 oldStrategyId = _autoStrategyPreferences[user].strategyId;
        _autoStrategyPreferences[user] =
            AutoStrategyPreference(id, deFiAdapterEpoch, info.logicEpoch, info.domainRevision, info.strategyRevision);
        autocompoundEnabled[user] = compound;
        emit AutocompoundEnabledUpdated(user, compound);
        emit AutoStrategyPreferenceUpdated(user, oldStrategyId, id);
    }

    function _preferenceCurrent(AutoStrategyPreference storage preference, IXMetroDeFiAdapter.StrategyInfo memory info)
        internal
        view
        returns (bool)
    {
        return preference.adapterEpoch == deFiAdapterEpoch && preference.logicEpoch == info.logicEpoch
            && preference.domainRevision == info.domainRevision && preference.strategyRevision == info.strategyRevision;
    }

    function _requireStrategy(bytes32 id, bool automatic)
        internal
        view
        returns (IXMetroDeFiAdapter.StrategyInfo memory info)
    {
        uint256 selector = uint32(IXMetroDeFiAdapter.strategyInfo.selector);
        address adapterAddress = deFiAdapter;
        bool valid;
        assembly ("memory-safe") {
            info := mload(0x40)
            mstore(info, shl(224, selector))
            mstore(add(info, 4), id)
            valid := staticcall(gas(), adapterAddress, info, 36, info, 224)
            valid := and(valid, eq(returndatasize(), 224))
            if valid {
                valid := and(valid, lt(mload(info), 6))
                valid := and(valid, lt(mload(add(info, 32)), 2))
                valid := and(valid, lt(mload(add(info, 64)), 2))
            }
            mstore(0x40, add(info, 224))
        }
        if (!valid) revert InvalidConfiguration();
        if (info.kind == IXMetroDeFiAdapter.StrategyKind.None || !info.enabled || (automatic && !info.autoEnabled)) {
            revert InvalidConfiguration();
        }
    }

    function _readStaticWord(address target, bytes4 selector_) private view returns (bytes32 value) {
        uint256 selector = uint32(selector_);
        bool valid;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, shl(224, selector))
            valid := staticcall(gas(), target, pointer, 4, pointer, 32)
            valid := and(valid, eq(returndatasize(), 32))
            value := mload(pointer)
        }
        if (!valid) revert InvalidAddress();
    }

    function _validAdapterBindings(address target) private view returns (bool valid) {
        uint256 selector = uint32(bytes4(keccak256("configuration()")));
        address expectedCore = address(this);
        address expectedUsdc = address(rewardToken);
        address expectedMetro = address(METRO);
        bytes32 expectedFamily = ADAPTER_FAMILY_ID;
        assembly ("memory-safe") {
            let pointer := mload(0x40)
            mstore(pointer, shl(224, selector))
            valid := staticcall(gas(), target, pointer, 4, pointer, 512)
            valid := and(valid, eq(returndatasize(), 512))
            valid := and(valid, eq(mload(pointer), and(expectedCore, 0xffffffffffffffffffffffffffffffffffffffff)))
            valid := and(
                valid,
                eq(mload(add(pointer, 32)), and(expectedUsdc, 0xffffffffffffffffffffffffffffffffffffffff))
            )
            valid := and(
                valid,
                eq(mload(add(pointer, 64)), and(expectedMetro, 0xffffffffffffffffffffffffffffffffffffffff))
            )
            valid := and(valid, eq(mload(add(pointer, 96)), expectedFamily))
            let epoch := mload(add(pointer, 128))
            valid := and(valid, and(iszero(iszero(epoch)), iszero(shr(64, epoch))))
            mstore(0x40, add(pointer, 512))
        }
    }

    function _compactMinima(
        IXMetroDeFiAdapter.StrategyKind kind,
        uint256 candidateCount,
        uint256[] calldata supplied,
        PendingBatch memory batch
    ) internal pure returns (uint256[] memory minima) {
        if (kind != IXMetroDeFiAdapter.StrategyKind.AaveV4) {
            if (supplied.length != 0) revert InvalidArrayLength();
            return new uint256[](0);
        }
        if (supplied.length != candidateCount) revert InvalidArrayLength();
        minima = new uint256[](batch.users.length);
        for (uint256 i; i < minima.length; ++i) {
            uint256 minimum = supplied[batch.sourceIndexes[i]];
            if (minimum == 0) revert InvalidAmount();
            minima[i] = minimum;
        }
    }

    function _executeManual(
        IXMetroDeFiAdapter.StrategyInfo memory info,
        bytes32 id,
        address account,
        uint256 amount,
        uint256 minimum,
        uint256 deadline,
        bytes calldata executionData
    ) internal returns (IXMetroDeFiAdapter.ExecutionResult memory result) {
        if (amount == 0 || minimum == 0) revert InvalidAmount();
        address adapterAddress = deFiAdapter;
        rewardToken.safeTransfer(adapterAddress, amount);
        uint256 selector = uint32(IXMetroDeFiAdapter.execute.selector);
        uint256 dataLength = executionData.length;
        bool valid;
        assembly ("memory-safe") {
            result := mload(0x40)
            mstore(result, shl(224, selector))
            mstore(add(result, 4), 32)
            let tuple := add(result, 36)
            mstore(tuple, id)
            mstore(add(tuple, 32), and(account, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(tuple, 64), amount)
            mstore(add(tuple, 96), minimum)
            mstore(add(tuple, 128), deadline)
            mstore(add(tuple, 160), 192)
            mstore(add(tuple, 192), dataLength)
            let dataPointer := add(tuple, 224)
            mstore(add(dataPointer, dataLength), 0)
            calldatacopy(dataPointer, executionData.offset, dataLength)
            let inputLength := add(260, and(add(dataLength, 31), not(31)))
            let success := call(gas(), adapterAddress, 0, result, inputLength, result, 96)
            if iszero(success) {
                let size := returndatasize()
                returndatacopy(result, 0, size)
                revert(result, size)
            }
            valid := and(eq(returndatasize(), 96), iszero(shr(160, mload(result))))
            mstore(0x40, add(result, 96))
        }
        if (!valid) revert InvalidConfiguration();
        if (result.amountIn != amount || result.outputToken != info.outputToken || result.amountOut < minimum) {
            revert InvalidConfiguration();
        }
    }

    function _executeBatch(
        IXMetroDeFiAdapter.StrategyInfo memory info,
        bytes32 id,
        PendingBatch memory batch,
        uint256 minimum,
        uint256[] memory minima,
        uint256 deadline,
        bytes calldata executionData
    ) internal returns (IXMetroDeFiAdapter.ExecutionResult memory result) {
        if (minimum == 0) revert InvalidAmount();
        address adapterAddress = deFiAdapter;
        uint256 metroBefore =
            info.kind == IXMetroDeFiAdapter.StrategyKind.SwapMetro ? METRO.balanceOf(address(this)) : 0;
        rewardToken.safeTransfer(adapterAddress, batch.total);
        uint256 selector = uint32(IXMetroDeFiAdapter.executeBatch.selector);
        uint256 accountCount = batch.users.length;
        uint256 minimaCount = minima.length;
        uint256 dataLength = executionData.length;
        bool valid;
        assembly ("memory-safe") {
            result := mload(0x40)
            mstore(result, shl(224, selector))
            mstore(add(result, 4), 32)
            let tuple := add(result, 36)
            let accountsOffset := 224
            let arrayBytes := mul(add(accountCount, 1), 32)
            let amountsOffset := add(accountsOffset, arrayBytes)
            let minimaOffset := add(amountsOffset, arrayBytes)
            let minimaBytes := mul(add(minimaCount, 1), 32)
            let dataOffset := add(minimaOffset, minimaBytes)

            mstore(tuple, id)
            mstore(add(tuple, 32), accountsOffset)
            mstore(add(tuple, 64), amountsOffset)
            mstore(add(tuple, 96), minimum)
            mstore(add(tuple, 128), minimaOffset)
            mstore(add(tuple, 160), deadline)
            mstore(add(tuple, 192), dataOffset)
            mcopy(add(tuple, accountsOffset), mload(batch), arrayBytes)
            mcopy(add(tuple, amountsOffset), mload(add(batch, 32)), arrayBytes)
            mcopy(add(tuple, minimaOffset), minima, minimaBytes)

            mstore(add(tuple, dataOffset), dataLength)
            let dataPointer := add(add(tuple, dataOffset), 32)
            mstore(add(dataPointer, dataLength), 0)
            calldatacopy(dataPointer, executionData.offset, dataLength)
            let inputLength := add(add(68, dataOffset), and(add(dataLength, 31), not(31)))
            let success := call(gas(), adapterAddress, 0, result, inputLength, result, 96)
            if iszero(success) {
                let size := returndatasize()
                returndatacopy(result, 0, size)
                revert(result, size)
            }
            valid := and(eq(returndatasize(), 96), iszero(shr(160, mload(result))))
            mstore(0x40, add(result, 96))
        }
        if (!valid) revert InvalidConfiguration();
        if (result.amountIn != batch.total || result.outputToken != info.outputToken || result.amountOut < minimum) {
            revert InvalidConfiguration();
        }
        if (
            info.kind == IXMetroDeFiAdapter.StrategyKind.SwapMetro
                && METRO.balanceOf(address(this)) - metroBefore != result.amountOut
        ) revert InvalidConfiguration();
    }

    function _distributeCompound(PendingBatch memory batch, uint256 received) internal {
        uint256 largest;
        for (uint256 i = 1; i < batch.amounts.length; ++i) {
            if (batch.amounts[i] > batch.amounts[largest]) largest = i;
        }
        uint256 distributed;
        for (uint256 i; i < batch.amounts.length; ++i) {
            if (i == largest) continue;
            uint256 share = Math.mulDiv(received, batch.amounts[i], batch.total);
            if (share == 0) revert InvalidAmount();
            distributed += share;
            _mintFreeShares(batch.users[i], share);
            emit AutoCompounded(batch.users[i], batch.amounts[i], share);
        }
        uint256 finalShare = received - distributed;
        _mintFreeShares(batch.users[largest], finalShare);
        emit AutoCompounded(batch.users[largest], batch.amounts[largest], finalShare);
    }

    function _autocompound(address user, uint256 minMetroOut, uint256 deadline, bytes calldata swapData)
        internal
        returns (uint256)
    {
        bytes32 id = SWAP_METRO_STRATEGY_ID;
        IXMetroDeFiAdapter.StrategyInfo memory info = _requireStrategy(id, false);
        uint256 pending = _consumePendingReward(user);
        uint256 received = _executeManual(info, id, user, pending, minMetroOut, deadline, swapData).amountOut;

        _mintFreeShares(user, received);

        emit AutoCompounded(user, pending, received);
        return received;
    }

    /// @notice Debt in reward-token base units, truncated toward zero for display.
    /// @dev Use claimable() for payments; this display omits internal fractional debt.
    function rewardDebt(address user) external view returns (int256) {
        return _rewardDebtScaled[user] / int256(ACC_PRECISION);
    }

    /// @dev Record only whole base units paid or consumed, retaining the remainder.
    function _recordRewardPayment(address user, uint256 amount) internal {
        _rewardDebtScaled[user] += _debtDelta(amount, ACC_PRECISION);
    }

    /// @dev Keep the full product and reject values outside signed accounting range.
    function _debtDelta(uint256 amount, uint256 accumulator) internal pure returns (int256) {
        uint256 scaled = amount * accumulator;
        if (scaled > uint256(type(int256).max)) revert InvalidAmount();
        return int256(scaled);
    }

    /// @dev Increase locked shares and update reward debt so new shares do not get past rewards.
    function _increaseLockedShares(address user, uint256 amount, bool thorMigration) internal {
        lockedShares[user] += amount;
        totalLockedShares += amount;
        if (thorMigration && user == migrationRewardExcludedAddress) {
            _rewardExcludedThorPrincipal += amount;
        } else {
            _rewardDebtScaled[user] += _debtDelta(amount, accRewardPerShare);
        }
    }

    /// @dev Decrease locked shares and update reward debt.
    function _decreaseLockedShares(address user, uint256 amount, bool thorMigration) internal {
        lockedShares[user] -= amount;
        totalLockedShares -= amount;
        if (thorMigration && user == migrationRewardExcludedAddress) {
            _rewardExcludedThorPrincipal -= amount;
        } else {
            _rewardDebtScaled[user] -= _debtDelta(amount, accRewardPerShare);
        }
    }

    /// @dev Add locked yTHOR shares to their independent reward accumulator.
    function _increaseYThorShares(address user, uint256 amount) internal {
        lockedShares[user] += amount;
        totalLockedShares += amount;
        _totalActiveYThorPrincipal += amount;
        if (user != migrationRewardExcludedAddress) {
            _rewardDebtScaled[user] += _debtDelta(amount, _accYThorRewardPerPrincipal);
        }
    }

    /// @dev Remove yTHOR principal while preserving rewards accrued before exit.
    function _decreaseYThorShares(address user, uint256 amount) internal {
        lockedShares[user] -= amount;
        totalLockedShares -= amount;
        _totalActiveYThorPrincipal -= amount;
        if (user != migrationRewardExcludedAddress) {
            _rewardDebtScaled[user] -= _debtDelta(amount, _accYThorRewardPerPrincipal);
        }
    }

    /// @dev Mint free shares and update reward debt.
    function _mintFreeShares(address to, uint256 amount) internal {
        _rewardDebtScaled[to] += _debtDelta(amount, accRewardPerShare);
        _mint(to, amount);
    }

    /// @dev Burn free shares and update reward debt.
    function _burnFreeShares(address from, uint256 amount) internal {
        _rewardDebtScaled[from] -= _debtDelta(amount, accRewardPerShare);
        _burn(from, amount);
    }

    /// @dev Move reward debt when free shares move.
    function _moveFreeSharesDebt(address from, address to, uint256 amount) internal {
        if (amount == 0 || from == to) return;
        int256 delta = _debtDelta(amount, accRewardPerShare);
        if (from != address(0)) _rewardDebtScaled[from] -= delta;
        if (to != address(0)) _rewardDebtScaled[to] += delta;
    }

    /// @notice Total shares = freeShares(totalSupply) + lockedShares(totalLockedShares).
    function totalShares() public view returns (uint256) {
        return totalSupply() + totalLockedShares;
    }

    /// @notice User total shares = freeShares(balanceOf) + lockedShares.
    function totalSharesOf(address user) public view returns (uint256) {
        return balanceOf(user) + lockedShares[user];
    }

    function _activeYThorPrincipal(address user) private view returns (uint256) {
        return XMetroCoreLogic.activeYThorPrincipal(user);
    }

    /// @dev Exclude migration principal before weighting and aggregate rounding.
    function _rewardWeights() private view returns (uint256 eligibleYThor, uint256 yThorWeight, uint256 weight) {
        eligibleYThor = _totalActiveYThorPrincipal - _activeYThorPrincipal(migrationRewardExcludedAddress);
        yThorWeight = (eligibleYThor * yThorRewardWeightBps) / BPS_DENOMINATOR;
        weight = totalShares() - _totalActiveYThorPrincipal - _rewardExcludedThorPrincipal + yThorWeight;
    }

    /// @dev Separate actual principal from reward eligibility; Contributor and free shares still earn.
    function _rewardSharesOf(address user) private view returns (uint256 baseShares, uint256 yThorPrincipal) {
        yThorPrincipal = _activeYThorPrincipal(user);
        baseShares = totalSharesOf(user) - yThorPrincipal;
        if (user == migrationRewardExcludedAddress) {
            baseShares -= _rewardExcludedThorPrincipal;
            yThorPrincipal = 0;
        }
    }

    /// @notice Reward denominator at the currently configured yTHOR multiplier.
    function totalRewardWeight() public view returns (uint256) {
        (,, uint256 weight) = _rewardWeights();
        return weight;
    }

    /// @notice Current instantaneous reward weight; historical rewards use the two accumulators above.
    function rewardWeightOf(address user) public view returns (uint256) {
        (uint256 baseShares, uint256 principal) = _rewardSharesOf(user);
        return baseShares + (principal * yThorRewardWeightBps) / BPS_DENOMINATOR;
    }

    /// @notice Pending claimable rewards for `user` (view).
    function claimable(address user) external view returns (uint256) {
        (uint256 pending,) = _pendingAndAccumulated(user);
        return pending;
    }

    /// @notice Batch pending claimable rewards (view).
    /// @dev Intended for off-chain callers (e.g., bots) to quote `minMetroOut` for batch autocompound.
    /// @return totalPending Sum of all users' pending rewards.
    /// @return pendings Per-user pending rewards aligned with `users`.
    function claimableMany(address[] calldata users)
        external
        view
        returns (uint256 totalPending, uint256[] memory pendings)
    {
        uint256 len = users.length;
        pendings = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            (uint256 pending,) = _pendingAndAccumulated(users[i]);
            pendings[i] = pending;
            totalPending += pending;
        }
    }

    /// @notice Compatibility aggregate for amounts that can be exited or vested at the current timestamp.
    /// @dev THOR and yTHOR sum eligible position payouts; contributor remains a vesting quote.
    function previewWithdrawableNow(address user)
        external
        view
        returns (
            uint256 thorUnlockable,
            uint256 yThorUnlockable,
            uint256 contributorUnlockable,
            uint256 totalUnlockable
        )
    {
        return XMetroCoreLogic.previewMigrationWithdrawableNow(user);
    }

    /// @notice Unstake request count / entry by index (Free).
    function unstakeRequestCountFree(address user) external view returns (uint256) {
        return _unstakeRequestsFree[user].length;
    }

    function unstakeRequestFree(address user, uint256 index) external view returns (UnstakeRequest memory) {
        return _unstakeRequestsFree[user][index];
    }

    /// @notice Unstake request count / entry by index (Thor).
    function unstakeRequestCountThor(address user) external view returns (uint256) {
        return _unstakeRequestsThor[user].length;
    }

    function unstakeRequestThor(address user, uint256 index) external view returns (UnstakeRequest memory) {
        return _unstakeRequestsThor[user][index];
    }

    /// @notice Unstake request count / entry by index (YThor).
    function unstakeRequestCountYThor(address user) external view returns (uint256) {
        return _unstakeRequestsYThor[user].length;
    }

    function unstakeRequestYThor(address user, uint256 index) external view returns (UnstakeRequest memory) {
        return _unstakeRequestsYThor[user][index];
    }

    /// @notice Unstake request count / entry by index (Contributor).
    function unstakeRequestCountContributor(address user) external view returns (uint256) {
        return _unstakeRequestsContributor[user].length;
    }

    function unstakeRequestContributor(address user, uint256 index) external view returns (UnstakeRequest memory) {
        return _unstakeRequestsContributor[user][index];
    }

    /// @notice contributor vesting schedule count.
    function contributorVestingCount(address user) external view returns (uint256) {
        return XMetroCoreLogic.contributorVestingCount(user);
    }

    function contributorVestCursor(address user) external view returns (uint256) {
        return XMetroCoreLogic.contributorVestCursor(user);
    }

    /// @notice contributor vesting schedule by index.
    function contributorVesting(address user, uint256 index) external view returns (VestingSchedule memory) {
        (uint128 totalAmount, uint128 claimed, uint64 startTime, uint64 duration) =
            XMetroCoreLogic.contributorVesting(user, index);
        return VestingSchedule(totalAmount, claimed, startTime, duration);
    }
}
