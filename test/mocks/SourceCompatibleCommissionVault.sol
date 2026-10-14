// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Test fixture preserving the supplied CommissionVault's constructor and
/// settlement/top-up/claim/processIncoming behavior used by this integration.
contract SourceCompatibleCommissionVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BATCH_SIZE = 200;

    IERC20 public immutable usdc;
    uint256 public immutable settlementTimelock;
    uint256 public immutable payoutTimelock;
    address public owner;
    address public operator;
    address public guardian;
    address public distributor;
    bool public paused;
    bool public migrationFinalized;
    uint256 public maxCodeDelta;
    uint256 public maxBatchDelta;
    uint256 public totalOwed;
    uint256 public totalClaimed;
    uint256 public pendingActivationTime;

    mapping(bytes32 => address) public payoutAddress;
    mapping(bytes32 => uint256) public cumulativeAmount;
    mapping(bytes32 => uint256) public claimed;
    mapping(bytes32 => uint256) private pendingAmount;
    mapping(bytes32 => address) private pendingBindAddress;
    bytes32[] private pendingCodeHashes;

    event SettlementProposed(uint256 activationTime, uint256 count, uint256 batchIncrease);
    event SettlementActivated(uint256 count, uint256 totalIncrease);
    event EntitlementUpdated(bytes32 indexed codeHash, address indexed payout, uint256 cumulativeAmount);
    event CommissionClaimed(
        bytes32 indexed codeHash, address indexed payout, uint256 amount, uint256 cumulativeClaimed
    );
    event IncomingProcessed(uint256 retained, uint256 surplus);

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    constructor(
        address usdc_,
        address distributor_,
        address operator_,
        address guardian_,
        uint256 maxCodeDelta_,
        uint256 maxBatchDelta_,
        bool isMigrationTarget_,
        uint256 settlementTimelock_,
        uint256 payoutTimelock_
    ) {
        require(
            usdc_ != address(0) && distributor_ != address(0) && operator_ != address(0) && guardian_ != address(0),
            "Zero address"
        );
        require(maxCodeDelta_ != 0 && maxBatchDelta_ != 0, "Zero delta");
        require(settlementTimelock_ >= 1 minutes && payoutTimelock_ >= 1 minutes, "Timelock too short");
        usdc = IERC20(usdc_);
        distributor = distributor_;
        owner = msg.sender;
        operator = operator_;
        guardian = guardian_;
        maxCodeDelta = maxCodeDelta_;
        maxBatchDelta = maxBatchDelta_;
        migrationFinalized = !isMigrationTarget_;
        settlementTimelock = settlementTimelock_;
        payoutTimelock = payoutTimelock_;
    }

    function proposeSettlement(
        string[] calldata codes,
        address[] calldata addresses,
        uint256[] calldata cumulativeAmounts
    ) external onlyOperator whenNotPaused {
        uint256 length = codes.length;
        require(length != 0 && length == addresses.length && length == cumulativeAmounts.length, "Length mismatch");
        require(length <= MAX_BATCH_SIZE && pendingCodeHashes.length == 0, "Pending settlement exists");
        uint256 batchIncrease;
        for (uint256 i; i < length; ++i) {
            require(addresses[i] != address(0), "Zero address");
            bytes32 codeHash = keccak256(bytes(codes[i]));
            require(pendingBindAddress[codeHash] == address(0), "Duplicate code in batch");
            uint256 current = cumulativeAmount[codeHash];
            require(cumulativeAmounts[i] >= current, "Cannot decrease amount");
            uint256 increase = cumulativeAmounts[i] - current;
            require(increase <= maxCodeDelta, "Exceeds max code delta");
            batchIncrease += increase;
            pendingAmount[codeHash] = cumulativeAmounts[i];
            pendingBindAddress[codeHash] = addresses[i];
            pendingCodeHashes.push(codeHash);
        }
        require(batchIncrease <= maxBatchDelta, "Exceeds max batch delta");
        pendingActivationTime = block.timestamp + settlementTimelock;
        emit SettlementProposed(pendingActivationTime, length, batchIncrease);
    }

    function activateSettlement() external whenNotPaused {
        uint256 length = pendingCodeHashes.length;
        require(length != 0, "No pending settlement");
        require(block.timestamp >= pendingActivationTime, "Timelock not expired");
        uint256 totalIncrease;
        for (uint256 i; i < length; ++i) {
            bytes32 codeHash = pendingCodeHashes[i];
            uint256 next = pendingAmount[codeHash];
            totalIncrease += next - cumulativeAmount[codeHash];
            cumulativeAmount[codeHash] = next;
            if (payoutAddress[codeHash] == address(0)) payoutAddress[codeHash] = pendingBindAddress[codeHash];
            delete pendingAmount[codeHash];
            delete pendingBindAddress[codeHash];
            emit EntitlementUpdated(codeHash, payoutAddress[codeHash], next);
        }
        totalOwed += totalIncrease;
        delete pendingCodeHashes;
        pendingActivationTime = 0;
        emit SettlementActivated(length, totalIncrease);
    }

    function requiredReserve() public view returns (uint256) {
        return totalOwed >= totalClaimed ? totalOwed - totalClaimed : 0;
    }

    function requiredTopUp() external view returns (uint256) {
        uint256 reserve = requiredReserve();
        uint256 balance = usdc.balanceOf(address(this));
        return balance >= reserve ? 0 : reserve - balance;
    }

    function claim(string calldata code) external whenNotPaused nonReentrant {
        bytes32 codeHash = keccak256(bytes(code));
        require(msg.sender == payoutAddress[codeHash], "Wrong sender");
        uint256 cumulative = cumulativeAmount[codeHash];
        uint256 alreadyClaimed = claimed[codeHash];
        require(cumulative > alreadyClaimed, "Nothing to claim");
        uint256 amount = cumulative - alreadyClaimed;
        require(amount <= usdc.balanceOf(address(this)), "Vault underfunded");
        claimed[codeHash] = cumulative;
        totalClaimed += amount;
        usdc.safeTransfer(msg.sender, amount);
        emit CommissionClaimed(codeHash, msg.sender, amount, cumulative);
    }

    function processIncoming() external onlyOperator whenNotPaused nonReentrant {
        require(migrationFinalized, "Migration not finalized");
        uint256 balance = usdc.balanceOf(address(this));
        uint256 reserve = requiredReserve();
        if (balance <= reserve) return;
        uint256 surplus = balance - reserve;
        usdc.safeTransfer(distributor, surplus);
        emit IncomingProcessed(reserve, surplus);
    }
}
