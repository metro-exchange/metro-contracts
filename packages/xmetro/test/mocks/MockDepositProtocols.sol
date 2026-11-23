// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MockSyrupUSDC} from "./MockSyrupUSDC.sol";

interface IMockOwnedPool {
    function owner() external view returns (address);
}

// Only the Adapter-facing protocol surface is modeled. setBehavior and setIndex are
// owner-controlled QA hooks, not production protocol interfaces. Never deposit valuable assets.

interface IMockV3Finalize {
    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 scaledAmount,
        uint256 scaledBalanceFromBefore
    ) external;
}

interface IMockAaveV4SpokeTypes {
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }
}

contract MockScaledAToken is IERC20 {
    uint256 internal constant RAY = 1e27;

    event Mint(
        address indexed caller, address indexed onBehalfOf, uint256 value, uint256 balanceIncrease, uint256 index
    );
    event BalanceTransfer(address indexed from, address indexed to, uint256 value, uint256 index);

    string public constant name = "Mock Aave USDC";
    string public constant symbol = "maUSDC";
    uint8 public constant decimals = 6;

    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public immutable POOL;
    uint256 public index;
    uint256 internal totalScaled;
    mapping(address user => uint256 amount) internal scaledBalances;
    mapping(address user => uint256 previousIndex) internal previousIndices;
    mapping(address owner => mapping(address spender => uint256 amount)) internal allowances;

    constructor(address underlying, address pool, uint256 index_) {
        UNDERLYING_ASSET_ADDRESS = underlying;
        POOL = pool;
        index = index_;
    }

    function setIndex(uint256 index_) external {
        require(msg.sender == POOL && index_ >= index && index_ <= type(uint128).max, "MockAToken: bad index");
        index = index_;
    }

    function mint(address caller, address onBehalfOf, uint256 scaledAmount, uint256 index_) external returns (bool) {
        require(msg.sender == POOL, "MockAToken: only pool");
        require(index_ == index && scaledAmount != 0, "MockAToken: invalid mint");
        return _mintScaled(caller, onBehalfOf, scaledAmount);
    }

    function donateScaled(address receiver, uint256 scaled) external {
        require(msg.sender == IMockOwnedPool(POOL).owner(), "MockAToken: only pool owner");
        _mintScaled(msg.sender, receiver, scaled);
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return scaledBalances[user];
    }

    function scaledTotalSupply() external view returns (uint256) {
        return totalScaled;
    }

    function getPreviousIndex(address user) external view returns (uint256) {
        return previousIndices[user];
    }

    function totalSupply() external view returns (uint256) {
        return Math.mulDiv(totalScaled, index, RAY);
    }

    function balanceOf(address user) public view returns (uint256) {
        return Math.mulDiv(scaledBalances[user], index, RAY);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MockAToken: allowance");
            allowances[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(to != address(0), "MockAToken: zero recipient");
        uint256 scaled = Math.mulDiv(amount, RAY, index, Math.Rounding.Ceil);
        uint256 fromBefore = scaledBalances[from];
        require(fromBefore >= scaled, "MockAToken: balance");
        uint256 fromInterest = _interest(from);
        uint256 toInterest = _interest(to);
        previousIndices[from] = index;
        previousIndices[to] = index;
        scaledBalances[from] -= scaled;
        scaledBalances[to] += scaled;
        // Mint.value includes accrued interest; BalanceTransfer.value is scaled shares, not USDC.
        if (fromInterest != 0) {
            emit Transfer(address(0), from, fromInterest);
            emit Mint(msg.sender, from, fromInterest, fromInterest, index);
        }
        if (from != to && toInterest != 0) {
            emit Transfer(address(0), to, toInterest);
            emit Mint(msg.sender, to, toInterest, toInterest, index);
        }
        emit Transfer(from, to, amount);
        emit BalanceTransfer(from, to, scaled, index);
        IMockV3Finalize(POOL).finalizeTransfer(UNDERLYING_ASSET_ADDRESS, from, to, scaled, fromBefore);
    }

    function _interest(address user) private view returns (uint256) {
        return
            Math.mulDiv(scaledBalances[user], index, RAY)
                - Math.mulDiv(scaledBalances[user], previousIndices[user], RAY);
    }

    function _mintScaled(address caller, address user, uint256 scaled) private returns (bool) {
        uint256 beforeScaled = scaledBalances[user];
        uint256 beforeBalance = Math.mulDiv(beforeScaled, previousIndices[user], RAY);
        uint256 interest = _interest(user);
        scaledBalances[user] = beforeScaled + scaled;
        totalScaled += scaled;
        previousIndices[user] = index;
        uint256 minted = Math.mulDiv(beforeScaled + scaled, index, RAY) - beforeBalance;
        emit Transfer(address(0), user, minted);
        emit Mint(caller, user, minted, interest, index);
        return beforeScaled == 0;
    }
}

contract MockAaveV3Pool is Ownable {
    using SafeERC20 for IERC20;

    event Supply(
        address indexed reserve, address user, address indexed onBehalfOf, uint256 amount, uint16 indexed referralCode
    );
    event ReserveDataUpdated(
        address indexed reserve,
        uint256 liquidityRate,
        uint256 stableBorrowRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex
    );
    event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);
    event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);

    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    IERC20 public immutable asset;
    MockScaledAToken public immutable aUsdc;
    uint256 public index;
    uint40 public lastUpdateTimestamp;
    mapping(address => bool) public usingAsCollateral;
    uint256 public pullBps = 10_000;
    uint256 public mintBps = 10_000;
    uint256 public supplyCallCount;
    address public lastReceiver;
    uint16 public lastReferralCode;
    bool public shouldRevert;
    bool public getterShouldRevert;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(address asset_, uint256 index_) Ownable(msg.sender) {
        require(index_ >= 1e27 && index_ <= type(uint128).max, "MockV3: bad index");
        asset = IERC20(asset_);
        index = index_;
        aUsdc = new MockScaledAToken(asset_, address(this), index_);
    }

    function setIndex(uint256 index_) external onlyOwner {
        require(index_ >= index && index_ <= type(uint128).max, "MockV3: bad index");
        index = index_;
        aUsdc.setIndex(index_);
    }

    function setBehavior(uint256 pullBps_, uint256 mintBps_, bool shouldRevert_) external onlyOwner {
        pullBps = pullBps_;
        mintBps = mintBps_;
        shouldRevert = shouldRevert_;
    }

    function setGetterRevert(bool value) external onlyOwner {
        getterShouldRevert = value;
    }

    function setReentry(address target, bytes calldata data) external onlyOwner {
        reentryTarget = target;
        reentryData = data;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function getReserveNormalizedIncome(address asset_) external view returns (uint256) {
        require(!getterShouldRevert, "MockV3: getter revert");
        require(asset_ == address(asset), "MockV3: wrong asset");
        return index;
    }

    function getReserveData(address asset_) external view returns (ReserveData memory reserve) {
        require(!getterShouldRevert, "MockV3: getter revert");
        require(asset_ == address(asset), "MockV3: wrong asset");
        reserve.liquidityIndex = uint128(index);
        reserve.variableBorrowIndex = 1e27;
        reserve.lastUpdateTimestamp = lastUpdateTimestamp;
        reserve.aTokenAddress = address(aUsdc);
    }

    function getReserveAToken(address asset_) external view returns (address) {
        require(!getterShouldRevert, "MockV3: getter revert");
        require(asset_ == address(asset), "MockV3: wrong asset");
        return address(aUsdc);
    }

    function supply(address asset_, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        require(!shouldRevert, "MockV3: forced revert");
        require(asset_ == address(asset), "MockV3: wrong asset");
        require(amount != 0 && onBehalfOf != address(0) && onBehalfOf != address(aUsdc), "MockV3: bad supply");
        ++supplyCallCount;
        lastReceiver = onBehalfOf;
        lastReferralCode = referralCode;
        lastUpdateTimestamp = uint40(block.timestamp);
        // QA omits the lending rate curve: interest is zero, the index is configured, and events match state.
        emit ReserveDataUpdated(asset_, 0, 0, 0, index, 1e27);
        asset.safeTransferFrom(msg.sender, address(aUsdc), Math.mulDiv(amount, pullBps, 10_000));
        uint256 scaled = Math.mulDiv(Math.mulDiv(amount, mintBps, 10_000), 1e27, index);
        bool firstSupply = aUsdc.mint(msg.sender, onBehalfOf, scaled, index);
        if (firstSupply) {
            usingAsCollateral[onBehalfOf] = true;
            emit ReserveUsedAsCollateralEnabled(asset_, onBehalfOf);
        }
        emit Supply(asset_, msg.sender, onBehalfOf, amount, referralCode);
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
    }

    function finalizeTransfer(
        address asset_,
        address from,
        address to,
        uint256 scaledAmount,
        uint256 scaledBalanceFromBefore
    ) external {
        require(msg.sender == address(aUsdc) && asset_ == address(asset), "MockV3: only aToken");
        // The referenced implementation does not auto-enable collateral on receipt; it disables it on full exit.
        if (from != to && scaledAmount != 0 && scaledAmount == scaledBalanceFromBefore && usingAsCollateral[from]) {
            usingAsCollateral[from] = false;
            emit ReserveUsedAsCollateralDisabled(asset_, from);
        }
    }
}

contract MockAaveV4Spoke is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    event Supply(
        uint256 indexed reserveId,
        address indexed caller,
        address indexed user,
        uint256 suppliedShares,
        uint256 suppliedAmount
    );
    event UpdatePositionManager(address indexed positionManager, bool active);
    event SetUserPositionManager(address indexed user, address indexed positionManager, bool approve);

    IERC20 public immutable asset;
    uint256 public immutable reserveId;
    mapping(address manager => bool active) public activeManagers;
    mapping(address user => mapping(address manager => bool approved)) public userManagers;
    mapping(uint256 id => mapping(address user => uint256 shares)) internal suppliedShares;
    uint256 public shareBps = 10_000;
    uint256 public pullBps = 10_000;
    uint256 public assetReturnBps = 10_000;
    uint256 public writtenShareBps = 10_000;
    uint256 public supplyCallCount;
    uint256 public failAtCall;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(address asset_, uint256 reserveId_) Ownable(msg.sender) {
        asset = IERC20(asset_);
        reserveId = reserveId_;
    }

    function updatePositionManager(address manager, bool active) external onlyOwner {
        activeManagers[manager] = active;
        emit UpdatePositionManager(manager, active);
    }

    function setUserPositionManager(address manager, bool approved) external {
        userManagers[msg.sender][manager] = approved;
        emit SetUserPositionManager(msg.sender, manager, approved);
    }

    function setBehavior(
        uint256 shareBps_,
        uint256 pullBps_,
        uint256 assetReturnBps_,
        uint256 writtenShareBps_,
        uint256 failAtCall_
    ) external onlyOwner {
        shareBps = shareBps_;
        pullBps = pullBps_;
        assetReturnBps = assetReturnBps_;
        writtenShareBps = writtenShareBps_;
        failAtCall = failAtCall_;
    }

    function setReentry(address target, bytes calldata data) external onlyOwner {
        reentryTarget = target;
        reentryData = data;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function getReserve(uint256 id) external view returns (IMockAaveV4SpokeTypes.Reserve memory reserve) {
        require(id == reserveId, "MockV4: bad reserve");
        reserve.underlying = address(asset);
        // QA folds Hub custody into the Spoke; Hub accounting and events are not modeled.
        reserve.hub = address(this);
        reserve.decimals = 6;
    }

    function getUserSuppliedShares(uint256 id, address user) external view returns (uint256) {
        return suppliedShares[id][user];
    }

    function isPositionManagerActive(address manager) external view returns (bool) {
        return activeManagers[manager];
    }

    function isPositionManager(address user, address manager) public view returns (bool) {
        return user == manager || (activeManagers[manager] && userManagers[user][manager]);
    }

    function supply(uint256 id, uint256 amount, address onBehalfOf)
        external
        nonReentrant
        returns (uint256 returnedShares, uint256 returnedAssets)
    {
        require(id == reserveId, "MockV4: bad reserve");
        require(isPositionManager(onBehalfOf, msg.sender), "MockV4: user not approved");
        ++supplyCallCount;
        require(failAtCall == 0 || supplyCallCount != failAtCall, "MockV4: forced failure");

        asset.safeTransferFrom(msg.sender, address(this), Math.mulDiv(amount, pullBps, 10_000));
        returnedShares = Math.mulDiv(amount, shareBps, 10_000);
        returnedAssets = Math.mulDiv(amount, assetReturnBps, 10_000);
        suppliedShares[id][onBehalfOf] += Math.mulDiv(returnedShares, writtenShareBps, 10_000);
        emit Supply(id, msg.sender, onBehalfOf, returnedShares, returnedAssets);
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
    }
}

contract MockPoolPermissionManager is Ownable {
    event LenderBitmapsSet(address[] lenders, uint256[] bitmaps);
    event PoolBitmapsSet(address indexed poolManager, bytes32[] functionIds, uint256[] bitmaps);
    event PermissionAdminSet(address indexed account, bool isAdmin);

    mapping(address poolManager => mapping(bytes32 functionId => uint256 bitmap)) public poolBitmaps;
    mapping(address lender => uint256 bitmap) public lenderBitmaps;
    mapping(address account => bool isAdmin) public permissionAdmins;

    constructor() Ownable(msg.sender) {}

    function setPermissionAdmin(address account, bool isAdmin) external onlyOwner {
        // QA configuration hook; the business path checks the Router permission admin in setLenderBitmaps.
        permissionAdmins[account] = isAdmin;
        emit PermissionAdminSet(account, isAdmin);
    }

    function setLenderBitmaps(address[] memory lenders, uint256[] memory bitmaps) public {
        require(permissionAdmins[msg.sender], "MockPPM: not admin");
        _setLenderBitmaps(lenders, bitmaps);
    }

    function setPoolBitmaps(address poolManager, bytes32[] memory functionIds, uint256[] memory bitmaps)
        public
        onlyOwner
    {
        require(functionIds.length != 0 && functionIds.length == bitmaps.length, "MockPPM: bad lengths");
        for (uint256 i; i < functionIds.length; ++i) {
            poolBitmaps[poolManager][functionIds[i]] = bitmaps[i];
        }
        emit PoolBitmapsSet(poolManager, functionIds, bitmaps);
    }

    function setPoolBitmap(address poolManager, bytes32 functionId, uint256 bitmap) external {
        bytes32[] memory ids = new bytes32[](1);
        uint256[] memory bitmaps = new uint256[](1);
        ids[0] = functionId;
        bitmaps[0] = bitmap;
        setPoolBitmaps(poolManager, ids, bitmaps);
    }

    function setLenderBitmap(address lender, uint256 bitmap) external onlyOwner {
        address[] memory lenders = new address[](1);
        uint256[] memory bitmaps = new uint256[](1);
        lenders[0] = lender;
        bitmaps[0] = bitmap;
        _setLenderBitmaps(lenders, bitmaps);
    }

    function hasPermission(address poolManager, address lender, bytes32 functionId) external view returns (bool) {
        // QA configures only FUNCTION_LEVEL bitmaps; other permission modes are not modeled.
        uint256 required = poolBitmaps[poolManager][functionId];
        return (lenderBitmaps[lender] & required) == required;
    }

    function _setLenderBitmaps(address[] memory lenders, uint256[] memory bitmaps) private {
        require(lenders.length != 0 && lenders.length == bitmaps.length, "MockPPM: bad lengths");
        for (uint256 i; i < lenders.length; ++i) {
            lenderBitmaps[lenders[i]] = bitmaps[i];
        }
        emit LenderBitmapsSet(lenders, bitmaps);
    }
}

contract MockSyrupRouter is Ownable {
    using SafeERC20 for IERC20;

    event DepositData(address indexed owner, uint256 amount, bytes32 depositData);

    bytes32 internal constant P_DEPOSIT = bytes32("P:deposit");

    IERC20 public immutable assetToken;
    MockSyrupUSDC public immutable syrupToken;
    MockPoolPermissionManager public immutable permissionManager;
    address public permissionAdmin;
    bytes32 public lastDepositData;
    mapping(address owner => uint256 nonce) public nonces;
    uint256 public pullBps = 10_000;
    uint256 public shareBps = 10_000;
    uint256 public depositCallCount;
    uint256 public authorizeCallCount;
    bool public shouldRevert;
    bool public useReportedOverride;
    uint256 public reportedOverride;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(address asset_, address syrupToken_, address permissionManager_, address permissionAdmin_)
        Ownable(msg.sender)
    {
        assetToken = IERC20(asset_);
        syrupToken = MockSyrupUSDC(syrupToken_);
        require(syrupToken.asset() == asset_, "MockMaple: wrong asset");
        permissionManager = MockPoolPermissionManager(permissionManager_);
        permissionAdmin = permissionAdmin_;
        // The protocol owners configure Syrup and permissions after deployment.
        // The official Router retains Pool approval; Adapter-to-Router approval remains per-call and reset.
        assetToken.forceApprove(syrupToken_, type(uint256).max);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function pool() external view returns (address) {
        return address(syrupToken);
    }

    function poolManager() external view returns (address) {
        return address(this);
    }

    function poolPermissionManager() external view returns (address) {
        return address(permissionManager);
    }

    function setBehavior(
        uint256 pullBps_,
        uint256 shareBps_,
        bool shouldRevert_,
        bool useReportedOverride_,
        uint256 reportedOverride_
    ) external onlyOwner {
        pullBps = pullBps_;
        shareBps = shareBps_;
        syrupToken.setShareBps(shareBps_);
        shouldRevert = shouldRevert_;
        useReportedOverride = useReportedOverride_;
        reportedOverride = reportedOverride_;
    }

    function setReentry(address target, bytes calldata data) external onlyOwner {
        reentryTarget = target;
        reentryData = data;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function deposit(uint256 amount, bytes32 depositData) external returns (uint256 shares) {
        ++depositCallCount;
        require(permissionManager.hasPermission(address(this), msg.sender, P_DEPOSIT), "MockMaple: unauthorized");
        return _deposit(amount, depositData);
    }

    function authorizeAndDeposit(
        uint256 bitmap,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 amount,
        bytes32 depositData
    ) external returns (uint256 shares) {
        ++authorizeCallCount;
        require(deadline >= block.timestamp, "MockMaple: expired");
        uint256 nonce = nonces[msg.sender];
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", block.chainid, address(this), msg.sender, nonce, bitmap, deadline));
        require(permissionManager.permissionAdmins(ECDSA.recover(digest, v, r, s)), "MockMaple: bad signature");
        nonces[msg.sender] = nonce + 1;
        address[] memory lenders = new address[](1);
        uint256[] memory bitmaps = new uint256[](1);
        lenders[0] = msg.sender;
        bitmaps[0] = bitmap;
        permissionManager.setLenderBitmaps(lenders, bitmaps);
        return _deposit(amount, depositData);
    }

    function _deposit(uint256 amount, bytes32 depositData) private returns (uint256 shares) {
        require(!shouldRevert, "MockMaple: forced revert");
        require(permissionManager.hasPermission(address(this), msg.sender, P_DEPOSIT), "MockMaple: unauthorized");
        lastDepositData = depositData;
        assetToken.safeTransferFrom(msg.sender, address(this), Math.mulDiv(amount, pullBps, 10_000));
        shares = syrupToken.deposit(amount, address(this));
        IERC20(address(syrupToken)).safeTransfer(msg.sender, shares);
        emit DepositData(msg.sender, amount, depositData);
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
        return useReportedOverride ? reportedOverride : shares;
    }
}
