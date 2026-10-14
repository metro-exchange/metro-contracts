// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IXMetroAdapterCore} from "./interfaces/IXMetroAdapterCore.sol";
import {IXMetroDeFiAdapter} from "./interfaces/IXMetroDeFiAdapter.sol";

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IOneInchAggregationRouterV6 {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
    }

    function swap(address executor, SwapDescription calldata desc, bytes calldata data)
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount);
}

interface IAaveV3Pool {
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

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getReserveData(address asset) external view returns (ReserveData memory);
}

interface IAToken is IERC20 {
    function scaledBalanceOf(address user) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
}

interface IAaveV4Spoke {
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
    function getUserSuppliedShares(uint256 reserveId, address user) external view returns (uint256);
    function isPositionManagerActive(address positionManager) external view returns (bool);
    function isPositionManager(address user, address positionManager) external view returns (bool);
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 suppliedShares, uint256 suppliedAssets);
}

interface ISyrupRouter {
    function asset() external view returns (address);
    function pool() external view returns (address);
    function poolManager() external view returns (address);
    function poolPermissionManager() external view returns (address);
    function nonces(address owner) external view returns (uint256);
    function deposit(uint256 amount, bytes32 depositData) external returns (uint256 shares);
    function authorizeAndDeposit(
        uint256 bitmap,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 amount,
        bytes32 depositData
    ) external returns (uint256 shares);
}

interface IAaveV4Giver {
    function isSpokeRegistered(address spoke) external view returns (bool);
    function supplyOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 suppliedShares, uint256 suppliedAssets);
}

interface IPoolPermissionManager {
    function hasPermission(address poolManager, address lender, bytes32 functionId) external view returns (bool);
    function poolBitmaps(address poolManager, bytes32 functionId) external view returns (uint256);
}

contract XMetroDeFiAdapter is Initializable, UUPSUpgradeable, IXMetroDeFiAdapter {
    using SafeERC20 for IERC20;

    error AccessStateFailure();
    error ConfigurationFailure();
    error InvalidExecutionRequest();
    error SlippageFailure();
    error AccountingFailure();
    error AaveV4AuthorizationFailure();
    error MapleAuthorizationFailure();

    event ConfigurationChanged(bytes32 indexed key, uint64 revision);
    event MapleAuthorizationConsumed(uint256 indexed routerNonce);
    event UserStrategySettled(
        bytes32 indexed strategyId, address indexed user, uint256 rewardAmount, uint256 amountOut
    );
    event TokensRescued(address indexed token, address indexed recipient, uint256 amount);

    uint8 private constant DEX_V2 = 0;
    uint8 private constant DEX_V3 = 1;
    uint8 private constant DEX_ONEINCH = 2;
    uint256 private constant ONEINCH_FORBIDDEN_FLAGS = 7;

    bytes32 private constant ADAPTER_FAMILY_ID = keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    bytes32 private constant STRATEGY_DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");
    bytes32 private constant P_DEPOSIT = bytes32("P:deposit");
    bytes32 private constant P_TRANSFER = bytes32("P:transfer");
    bytes32 private constant P_TRANSFER_FROM = bytes32("P:transferFrom");
    uint256 private constant RAY = 1e27;
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    // keccak256(abi.encode(uint256(keccak256("xmetro.storage.XMetroDeFiAdapter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ADAPTER_STORAGE_LOCATION =
        0x9bc90f8dcf23c06f51f48cd4ee75e247d4ecbe0523c3d7a0f6ecd330f0cd1f00;

    struct StrategyConfig {
        StrategyKind kind;
        bool enabled;
        bool autoEnabled;
        uint64 revision;
        address outputToken;
    }

    struct AaveV3Config {
        address pool;
        address aToken;
        uint16 referralCode;
    }

    struct AaveV4Config {
        address spoke;
        uint256 reserveId;
    }

    struct MapleConfig {
        address router;
        address syrupToken;
        bytes32 depositData;
    }

    struct AdapterStorage {
        address xMetro;
        IERC20 usdc;
        IERC20 metro;
        uint64 logicEpoch;
        uint64 domainRevision;
        uint256 reentrancyStatus;
        address routerV2;
        address routerV3;
        address oneInchRouter;
        bytes32 swapMetroId;
        bytes32 aaveV3Id;
        bytes32 aaveV4Id;
        bytes32 mapleId;
        AaveV3Config aaveV3;
        AaveV4Config aaveV4;
        MapleConfig maple;
        mapping(bytes32 strategyId => StrategyConfig config) strategies;
        // Append fields without moving the existing AaveV4Config, MapleConfig, or strategies storage.
        address aaveV4Giver;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address xMetro_, address usdc_, address metro_) external initializer {
        if (
            xMetro_.code.length == 0 || usdc_.code.length == 0 || metro_.code.length == 0 || xMetro_ == usdc_
                || xMetro_ == metro_ || usdc_ == metro_
        ) revert ConfigurationFailure();

        AdapterStorage storage state = _adapterStorage();
        state.xMetro = xMetro_;
        state.usdc = IERC20(usdc_);
        state.metro = IERC20(metro_);
        state.logicEpoch = 1;
        state.domainRevision = 1;
        state.reentrancyStatus = NOT_ENTERED;

        bytes32 metroId = _deriveStrategyId(StrategyKind.SwapMetro, metro_);
        state.swapMetroId = metroId;
        state.strategies[metroId] = StrategyConfig(StrategyKind.SwapMetro, false, false, 1, metro_);

        bytes32 v4Id = _deriveStrategyId(StrategyKind.AaveV4, address(0));
        state.aaveV4Id = v4Id;
        state.strategies[v4Id] = StrategyConfig(StrategyKind.AaveV4, false, false, 1, address(0));
    }

    modifier onlyConfigAuthority() {
        _requireAuthority(false, true);
        _;
    }

    modifier onlyRescueAuthority() {
        _requireAuthority(true, false);
        _;
    }

    modifier onlyOperationalCore() {
        AdapterStorage storage state = _adapterStorage();
        address core = state.xMetro;
        if (msg.sender != core) revert AccessStateFailure();
        if (_coreWord(core, IXMetroAdapterCore.paused.selector) != 0) revert AccessStateFailure();
        if (_coreWord(core, IXMetroAdapterCore.deFiAdapter.selector) != uint160(address(this))) {
            revert AccessStateFailure();
        }
        _;
    }

    modifier nonReentrant() {
        AdapterStorage storage state = _adapterStorage();
        if (state.reentrancyStatus != NOT_ENTERED) revert AccessStateFailure();
        state.reentrancyStatus = ENTERED;
        _;
        state.reentrancyStatus = NOT_ENTERED;
    }

    function xMETRO() external view returns (address) {
        return _adapterStorage().xMetro;
    }

    function USDC() external view returns (address) {
        return address(_adapterStorage().usdc);
    }

    function METRO() external view returns (address) {
        return address(_adapterStorage().metro);
    }

    function adapterFamilyId() external pure returns (bytes32) {
        return ADAPTER_FAMILY_ID;
    }

    function implementationVersion() external pure virtual returns (uint64) {
        return 1;
    }

    function logicEpoch() external view returns (uint64) {
        return _adapterStorage().logicEpoch;
    }

    function strategyInfo(bytes32 id) external view returns (StrategyInfo memory info) {
        AdapterStorage storage state = _adapterStorage();
        StrategyConfig storage config = state.strategies[id];
        info = StrategyInfo(
            config.kind,
            config.enabled,
            config.autoEnabled,
            state.logicEpoch,
            state.domainRevision,
            config.revision,
            config.outputToken
        );
    }

    function configuration()
        external
        view
        returns (
            address core,
            address usdc,
            address metro,
            bytes32 family,
            uint64 epoch,
            address routerV2,
            address routerV3,
            address oneInchRouter,
            AaveV3Config memory aaveV3,
            AaveV4Config memory aaveV4,
            MapleConfig memory maple
        )
    {
        AdapterStorage storage state = _adapterStorage();
        return (
            state.xMetro,
            address(state.usdc),
            address(state.metro),
            ADAPTER_FAMILY_ID,
            state.logicEpoch,
            state.routerV2,
            state.routerV3,
            state.oneInchRouter,
            state.aaveV3,
            state.aaveV4,
            state.maple
        );
    }

    function setRouters(address routerV2_, address routerV3_, address oneInchRouter_) external onlyConfigAuthority {
        if (
            routerV2_.code.length == 0 || routerV3_.code.length == 0 || oneInchRouter_.code.length == 0
                || routerV2_ == routerV3_ || routerV2_ == oneInchRouter_ || routerV3_ == oneInchRouter_
        ) revert ConfigurationFailure();
        AdapterStorage storage state = _adapterStorage();
        if (state.routerV2 == routerV2_ && state.routerV3 == routerV3_ && state.oneInchRouter == oneInchRouter_) {
            revert ConfigurationFailure();
        }
        state.routerV2 = routerV2_;
        state.routerV3 = routerV3_;
        state.oneInchRouter = oneInchRouter_;
        ++state.domainRevision;
        emit ConfigurationChanged(bytes32(0), state.domainRevision);
    }

    function setSwapMetroConfig(bool enabled, bool autoEnabled) external onlyConfigAuthority {
        AdapterStorage storage state = _adapterStorage();
        _configureStrategy(state, state.swapMetroId, StrategyKind.None, address(0), enabled, autoEnabled, true);
    }

    function setSwapTokenConfig(address tokenOut, bool enabled, bool autoEnabled)
        external
        onlyConfigAuthority
        returns (bytes32 id)
    {
        AdapterStorage storage state = _adapterStorage();
        id = _deriveStrategyId(StrategyKind.AutoSwap, tokenOut);
        StrategyConfig storage config = state.strategies[id];
        if (!enabled) {
            _configureStrategy(state, id, StrategyKind.None, address(0), false, false, true);
            return id;
        }
        if (tokenOut == address(state.usdc) || tokenOut == address(state.metro) || tokenOut.code.length == 0) {
            revert ConfigurationFailure();
        }
        _configureStrategy(
            state, id, StrategyKind.AutoSwap, tokenOut, true, autoEnabled, config.kind != StrategyKind.None
        );
    }

    function setAaveV3Config(address pool, address aToken, uint16 referralCode, bool enabled, bool autoEnabled)
        external
        onlyConfigAuthority
        returns (bytes32 id)
    {
        AdapterStorage storage state = _adapterStorage();
        if (!enabled) {
            id = state.aaveV3Id;
            _configureStrategy(state, id, StrategyKind.None, address(0), false, false, false);
            return id;
        }
        if (pool.code.length == 0 || aToken.code.length == 0 || pool == aToken) revert ConfigurationFailure();
        if (
            _readAddress(aToken, IAToken.UNDERLYING_ASSET_ADDRESS.selector) != address(state.usdc)
                || _readAddress(aToken, IAToken.POOL.selector) != pool
                || _reserveAToken(pool, address(state.usdc)) != aToken
        ) revert ConfigurationFailure();

        id = _deriveStrategyId(StrategyKind.AaveV3, aToken);
        bytes32 oldId = state.aaveV3Id;
        if (oldId != bytes32(0) && oldId != id) {
            _configureStrategy(state, oldId, StrategyKind.None, address(0), false, false, false);
        }
        bool sameConfig = state.aaveV3.pool == pool && state.aaveV3.aToken == aToken
            && state.aaveV3.referralCode == referralCode && oldId == id;
        state.aaveV3 = AaveV3Config(pool, aToken, referralCode);
        state.aaveV3Id = id;
        _configureStrategy(state, id, StrategyKind.AaveV3, aToken, true, autoEnabled, sameConfig);
    }

    function aaveV4Giver() external view returns (address) {
        return _adapterStorage().aaveV4Giver;
    }

    function setAaveV4Config(address spoke, address giver, uint256 reserveId, bool enabled, bool autoEnabled)
        external
        onlyConfigAuthority
    {
        AdapterStorage storage state = _adapterStorage();
        bytes32 id = state.aaveV4Id;
        if (!enabled) {
            _configureStrategy(state, id, StrategyKind.None, address(0), false, false, false);
            return;
        }
        if (
            spoke.code.length == 0 || giver.code.length == 0 || giver == spoke || giver == address(this)
                || _reserveUnderlying(spoke, reserveId) != address(state.usdc)
                || !IAaveV4Giver(giver).isSpokeRegistered(spoke) || !IAaveV4Spoke(spoke).isPositionManagerActive(giver)
        ) {
            revert ConfigurationFailure();
        }
        bool sameConfig =
            state.aaveV4.spoke == spoke && state.aaveV4.reserveId == reserveId && state.aaveV4Giver == giver;
        state.aaveV4 = AaveV4Config(spoke, reserveId);
        state.aaveV4Giver = giver;
        _configureStrategy(state, id, StrategyKind.AaveV4, address(0), true, autoEnabled, sameConfig);
    }

    function setMapleConfig(address router, bytes32 depositData, bool enabled, bool autoEnabled)
        external
        onlyConfigAuthority
        returns (bytes32 id)
    {
        AdapterStorage storage state = _adapterStorage();
        if (!enabled) {
            id = state.mapleId;
            _configureStrategy(state, id, StrategyKind.None, address(0), false, false, false);
            return id;
        }
        if (router.code.length == 0) revert ConfigurationFailure();
        address syrupToken = _readAddress(router, ISyrupRouter.pool.selector);
        address manager = _readAddress(router, ISyrupRouter.poolManager.selector);
        address permissions = _readAddress(router, ISyrupRouter.poolPermissionManager.selector);
        if (
            syrupToken.code.length == 0 || manager.code.length == 0 || permissions.code.length == 0
                || _readAddress(router, ISyrupRouter.asset.selector) != address(state.usdc)
                || _readAddress(syrupToken, IERC4626.asset.selector) != address(state.usdc)
        ) revert ConfigurationFailure();

        id = _deriveStrategyId(StrategyKind.Maple, syrupToken);
        bytes32 oldId = state.mapleId;
        if (oldId != bytes32(0) && oldId != id) {
            _configureStrategy(state, oldId, StrategyKind.None, address(0), false, false, false);
        }
        bool sameConfig = state.maple.router == router && state.maple.syrupToken == syrupToken
            && state.maple.depositData == depositData && oldId == id;
        state.maple = MapleConfig(router, syrupToken, depositData);
        state.mapleId = id;
        _configureStrategy(state, id, StrategyKind.Maple, syrupToken, true, autoEnabled, sameConfig);
    }

    function execute(ManualExecution calldata request)
        external
        onlyOperationalCore
        nonReentrant
        returns (ExecutionResult memory result)
    {
        if (request.account == address(0)) revert InvalidExecutionRequest();
        if (request.amountIn == 0 || request.minAmountOut == 0) revert InvalidExecutionRequest();

        AdapterStorage storage state = _adapterStorage();
        StrategyConfig storage strategy = _requireStrategy(state, request.strategyId, false);
        uint256 inputBaseline = _inputBaseline(state.usdc, request.amountIn);
        uint256 amountOut;

        if (strategy.kind == StrategyKind.SwapMetro || strategy.kind == StrategyKind.AutoSwap) {
            _requireSwapEnvelope(request.deadline, request.executionData);
            amountOut = _executeSwap(
                state,
                request.amountIn,
                strategy.outputToken,
                request.minAmountOut,
                request.deadline,
                request.executionData
            );
            address recipient = strategy.kind == StrategyKind.SwapMetro ? state.xMetro : request.account;
            _sendExact(IERC20(strategy.outputToken), recipient, amountOut);
        } else {
            if (request.deadline != 0) revert InvalidExecutionRequest();
            if (strategy.kind == StrategyKind.AaveV3) {
                if (request.executionData.length != 0) revert InvalidExecutionRequest();
                amountOut = _executeAaveV3Manual(state, request.account, request.amountIn, request.minAmountOut);
            } else if (strategy.kind == StrategyKind.AaveV4) {
                if (request.executionData.length != 0) revert InvalidExecutionRequest();
                amountOut = _supplyAaveV4(state, request.account, request.amountIn, request.minAmountOut);
            } else if (strategy.kind == StrategyKind.Maple) {
                amountOut = _executeMaple(state, request.amountIn, request.executionData);
                if (amountOut < request.minAmountOut) revert SlippageFailure();
                _sendExact(IERC20(strategy.outputToken), request.account, amountOut);
            } else {
                revert InvalidExecutionRequest();
            }
        }

        _requireInputBaseline(state.usdc, inputBaseline);
        result = ExecutionResult(strategy.outputToken, request.amountIn, amountOut);
    }

    function executeBatch(BatchExecution calldata request)
        external
        onlyOperationalCore
        nonReentrant
        returns (ExecutionResult memory result)
    {
        uint256 totalIn = _validateBatch(request.accounts, request.amountsIn);
        if (request.minTotalAmountOut == 0) revert InvalidExecutionRequest();

        AdapterStorage storage state = _adapterStorage();
        StrategyConfig storage strategy = _requireStrategy(state, request.strategyId, true);
        uint256 inputBaseline = _inputBaseline(state.usdc, totalIn);
        uint256 amountOut;

        if (strategy.kind == StrategyKind.SwapMetro || strategy.kind == StrategyKind.AutoSwap) {
            if (request.minUserAmountsOut.length != 0) revert InvalidExecutionRequest();
            _requireSwapEnvelope(request.deadline, request.executionData);
            amountOut = _executeSwap(
                state, totalIn, strategy.outputToken, request.minTotalAmountOut, request.deadline, request.executionData
            );
            if (strategy.kind == StrategyKind.SwapMetro) {
                _sendExact(state.metro, state.xMetro, amountOut);
            } else {
                _distributeToken(
                    request.strategyId,
                    IERC20(strategy.outputToken),
                    request.accounts,
                    request.amountsIn,
                    totalIn,
                    amountOut
                );
            }
        } else {
            if (request.deadline != 0) revert InvalidExecutionRequest();
            if (strategy.kind == StrategyKind.AaveV3) {
                if (request.executionData.length != 0 || request.minUserAmountsOut.length != 0) {
                    revert InvalidExecutionRequest();
                }
                amountOut = _executeAaveV3Batch(state, request, totalIn);
            } else if (strategy.kind == StrategyKind.AaveV4) {
                if (request.executionData.length != 0 || request.minUserAmountsOut.length != request.accounts.length) {
                    revert InvalidExecutionRequest();
                }
                amountOut = _executeAaveV4Batch(state, request);
                if (amountOut < request.minTotalAmountOut) {
                    revert SlippageFailure();
                }
            } else if (strategy.kind == StrategyKind.Maple) {
                if (request.minUserAmountsOut.length != 0) revert InvalidExecutionRequest();
                amountOut = _executeMaple(state, totalIn, request.executionData);
                if (amountOut < request.minTotalAmountOut) {
                    revert SlippageFailure();
                }
                _distributeToken(
                    request.strategyId,
                    IERC20(strategy.outputToken),
                    request.accounts,
                    request.amountsIn,
                    totalIn,
                    amountOut
                );
            } else {
                revert InvalidExecutionRequest();
            }
        }

        _requireInputBaseline(state.usdc, inputBaseline);
        result = ExecutionResult(strategy.outputToken, totalIn, amountOut);
    }

    function rescueERC20(address token, address recipient, uint256 amount) external onlyRescueAuthority nonReentrant {
        if (token == address(0) || recipient == address(0)) revert ConfigurationFailure();
        _safeTransfer(IERC20(token), recipient, amount);
        emit TokensRescued(token, recipient, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        _requireAuthority(false, true);
        if (newImplementation == ERC1967Utils.getImplementation()) revert ConfigurationFailure();
        if (_implementationFamily(newImplementation) != ADAPTER_FAMILY_ID) revert ConfigurationFailure();

        AdapterStorage storage state = _adapterStorage();
        ++state.logicEpoch;
    }

    function _implementationFamily(address target) internal view returns (bytes32 value) {
        bytes4 selector = IXMetroDeFiAdapter.adapterFamilyId.selector;
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            mstore(0, selector)
            ok := staticcall(gas(), target, 0, 4, 0, 0)
            size := returndatasize()
            if eq(size, 32) {
                returndatacopy(0, 0, 32)
                value := mload(0)
            }
        }
        if (!ok || size != 32) revert ConfigurationFailure();
    }

    function _requireAuthority(bool requirePaused, bool requireActive) internal view {
        AdapterStorage storage state = _adapterStorage();
        address core = state.xMetro;
        if (_coreWord(core, IXMetroAdapterCore.owner.selector) != uint160(msg.sender)) revert AccessStateFailure();
        if (requirePaused && _coreWord(core, IXMetroAdapterCore.paused.selector) != 1) revert AccessStateFailure();
        if (requireActive && _coreWord(core, IXMetroAdapterCore.deFiAdapter.selector) != uint160(address(this))) {
            revert AccessStateFailure();
        }
    }

    function _coreWord(address core, bytes4 selector_) internal view returns (uint256 value) {
        uint256 selector = uint32(selector_);
        bool valid;
        assembly ("memory-safe") {
            mstore(0, shl(224, selector))
            valid := staticcall(gas(), core, 0, 4, 0, 32)
            valid := and(valid, eq(returndatasize(), 32))
            value := mload(0)
        }
        if (!valid) revert AccessStateFailure();
    }

    function _configureStrategy(
        AdapterStorage storage state,
        bytes32 id,
        StrategyKind kind,
        address outputToken,
        bool enabled,
        bool autoEnabled,
        bool rejectSame
    ) internal {
        if (autoEnabled && !enabled) revert ConfigurationFailure();
        StrategyConfig storage strategy = state.strategies[id];
        if (strategy.kind == StrategyKind.None) {
            if (kind == StrategyKind.None) revert ConfigurationFailure();
            state.strategies[id] = StrategyConfig(kind, enabled, autoEnabled, 1, outputToken);
            emit ConfigurationChanged(id, 1);
            return;
        }
        if (kind != StrategyKind.None && (strategy.kind != kind || strategy.outputToken != outputToken)) {
            revert ConfigurationFailure();
        }
        if (rejectSame && strategy.enabled == enabled && strategy.autoEnabled == autoEnabled) {
            revert ConfigurationFailure();
        }
        strategy.enabled = enabled;
        strategy.autoEnabled = enabled && autoEnabled;
        ++strategy.revision;
        emit ConfigurationChanged(id, strategy.revision);
    }

    function _requireStrategy(AdapterStorage storage state, bytes32 id, bool automatic)
        internal
        view
        returns (StrategyConfig storage strategy)
    {
        strategy = state.strategies[id];
        if (strategy.kind == StrategyKind.None) revert InvalidExecutionRequest();
        if (!strategy.enabled) revert InvalidExecutionRequest();
        if (automatic && !strategy.autoEnabled) revert InvalidExecutionRequest();
    }

    function _deriveStrategyId(StrategyKind kind, address outputToken) internal view returns (bytes32 id) {
        return keccak256(abi.encode(block.chainid, STRATEGY_DOMAIN, kind, outputToken));
    }

    function _requireSwapEnvelope(uint256 deadline, bytes calldata executionData) internal view {
        if (deadline <= block.timestamp) revert InvalidExecutionRequest();
        if (executionData.length == 0) revert InvalidExecutionRequest();
    }

    function _inputBaseline(IERC20 token, uint256 amountIn) internal view returns (uint256 baseline) {
        baseline = _decrease(token.balanceOf(address(this)), amountIn);
    }

    function _requireInputBaseline(IERC20 token, uint256 baseline) internal view {
        uint256 balance = token.balanceOf(address(this));
        if (balance != baseline) revert AccountingFailure();
    }

    function _executeSwap(
        AdapterStorage storage state,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata swapData
    ) internal returns (uint256 amountOut) {
        (uint8 dexType, bytes memory routeData) = abi.decode(swapData, (uint8, bytes));
        IERC20 output = IERC20(tokenOut);
        uint256 outputBefore = output.balanceOf(address(this));
        uint256 reported;

        if (dexType == DEX_V2) {
            address[] memory path = abi.decode(routeData, (address[]));
            if (path.length < 2 || path[0] != address(state.usdc) || path[path.length - 1] != tokenOut) {
                revert InvalidExecutionRequest();
            }
            _approveExact(state.usdc, state.routerV2, amountIn);
            uint256[] memory amounts = IUniswapV2Router02(state.routerV2)
                .swapExactTokensForTokens(amountIn, minAmountOut, path, address(this), deadline);
            if (amounts.length != path.length || amounts[0] != amountIn) revert InvalidExecutionRequest();
            reported = amounts[amounts.length - 1];
            _clearAllowance(state.usdc, state.routerV2);
        } else if (dexType == DEX_V3) {
            if (
                routeData.length < 43 || (routeData.length - 20) % 23 != 0
                    || _firstToken(routeData) != address(state.usdc) || _lastToken(routeData) != tokenOut
            ) revert InvalidExecutionRequest();
            _approveExact(state.usdc, state.routerV3, amountIn);
            reported = IV3SwapRouter(state.routerV3)
                .exactInput(
                    IV3SwapRouter.ExactInputParams({
                    path: routeData, recipient: address(this), amountIn: amountIn, amountOutMinimum: minAmountOut
                })
                );
            _clearAllowance(state.usdc, state.routerV3);
        } else if (dexType == DEX_ONEINCH) {
            reported = _execute1Inch(state, amountIn, tokenOut, minAmountOut, routeData);
        } else {
            revert InvalidExecutionRequest();
        }

        amountOut = _increase(output.balanceOf(address(this)), outputBefore);
        if (reported != amountOut) revert AccountingFailure();
        if (amountOut < minAmountOut) revert SlippageFailure();
    }

    function _execute1Inch(
        AdapterStorage storage state,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        bytes memory routeData
    ) internal returns (uint256 reported) {
        if (routeData.length < 4 || bytes4(routeData) != IOneInchAggregationRouterV6.swap.selector) {
            revert InvalidExecutionRequest();
        }
        bytes memory arguments = _withoutSelector(routeData);
        (address executor, IOneInchAggregationRouterV6.SwapDescription memory description, bytes memory executorData) =
            abi.decode(arguments, (address, IOneInchAggregationRouterV6.SwapDescription, bytes));
        if (
            executor.code.length == 0 || description.srcReceiver.code.length == 0 || executorData.length == 0
                || address(description.srcToken) != address(state.usdc) || address(description.dstToken) != tokenOut
                || description.dstReceiver != address(this) || description.amount != amountIn
                || description.minReturnAmount < minAmountOut || description.flags & ONEINCH_FORBIDDEN_FLAGS != 0
        ) revert InvalidExecutionRequest();

        address router = state.oneInchRouter;
        _approveExact(state.usdc, router, amountIn);
        bool ok;
        uint256 returnSize;
        uint256 spent;
        assembly ("memory-safe") {
            ok := call(gas(), router, 0, add(routeData, 32), mload(routeData), 0, 64)
            returnSize := returndatasize()
            reported := mload(0)
            spent := mload(32)
        }
        if (!ok || returnSize != 64 || spent != amountIn) revert InvalidExecutionRequest();
        _clearAllowance(state.usdc, router);
    }

    function _withoutSelector(bytes memory data) private pure returns (bytes memory result) {
        uint256 length = data.length - 4;
        result = new bytes(length);
        assembly ("memory-safe") {
            let source := add(data, 36)
            let destination := add(result, 32)
            let end := add(destination, length)
            for {} lt(destination, end) {
                destination := add(destination, 32)
                source := add(source, 32)
            } {
                mstore(destination, mload(source))
            }
        }
    }

    function _executeAaveV3Manual(AdapterStorage storage state, address user, uint256 amount, uint256 minimumNominal)
        internal
        returns (uint256 nominalOut)
    {
        AaveV3Config memory config = state.aaveV3;
        IAToken aToken = IAToken(config.aToken);
        uint256 scaledBefore = aToken.scaledBalanceOf(user);
        _supplyAaveV3(state.usdc, config, amount, user);
        uint256 scaledOut = _increase(aToken.scaledBalanceOf(user), scaledBefore);
        uint256 index = IAaveV3Pool(config.pool).getReserveNormalizedIncome(address(state.usdc));
        nominalOut = Math.mulDiv(scaledOut, index, RAY);
        if (nominalOut < minimumNominal) revert SlippageFailure();
    }

    function _executeAaveV3Batch(AdapterStorage storage state, BatchExecution calldata request, uint256 totalIn)
        internal
        returns (uint256 nominalOut)
    {
        AaveV3Config memory config = state.aaveV3;
        IAToken aToken = IAToken(config.aToken);
        uint256 scaledBaseline = aToken.scaledBalanceOf(address(this));
        _supplyAaveV3(state.usdc, config, totalIn, address(this));
        uint256 totalScaled = _increase(aToken.scaledBalanceOf(address(this)), scaledBaseline);
        uint256 index = IAaveV3Pool(config.pool).getReserveNormalizedIncome(address(state.usdc));
        nominalOut = Math.mulDiv(totalScaled, index, RAY);
        if (nominalOut < request.minTotalAmountOut) {
            revert SlippageFailure();
        }
        _distributeAaveV3(request.strategyId, config, request.accounts, request.amountsIn, totalIn, totalScaled, index);
        uint256 scaledAfter = aToken.scaledBalanceOf(address(this));
        if (scaledAfter != scaledBaseline) revert AccountingFailure();
    }

    function _supplyAaveV3(IERC20 asset, AaveV3Config memory config, uint256 amount, address receiver) internal {
        _approveExact(asset, config.pool, amount);
        IAaveV3Pool(config.pool).supply(address(asset), amount, receiver, config.referralCode);
        _clearAllowance(asset, config.pool);
    }

    function _distributeAaveV3(
        bytes32 id,
        AaveV3Config memory config,
        address[] calldata users,
        uint256[] calldata amounts,
        uint256 totalIn,
        uint256 totalScaled,
        uint256 index
    ) internal {
        if (index < RAY) revert ConfigurationFailure();
        uint256 largest = _largestIndex(amounts);
        IAToken aToken = IAToken(config.aToken);
        uint256 distributed;
        for (uint256 i; i < users.length; ++i) {
            if (i == largest) continue;
            uint256 scaled = Math.mulDiv(totalScaled, amounts[i], totalIn);
            if (scaled == 0) revert InvalidExecutionRequest();
            distributed += scaled;
            _transferAaveV3Share(id, aToken, index, users[i], amounts[i], scaled);
        }
        _transferAaveV3Share(id, aToken, index, users[largest], amounts[largest], totalScaled - distributed);
    }

    function _transferAaveV3Share(
        bytes32 id,
        IAToken aToken,
        uint256 index,
        address user,
        uint256 rewardAmount,
        uint256 scaled
    ) internal {
        uint256 nominal = Math.mulDiv(scaled, index, RAY);
        if (nominal > type(uint120).max || (nominal * RAY + index - 1) / index != scaled) {
            revert AccountingFailure();
        }
        uint256 userBefore = aToken.scaledBalanceOf(user);
        _safeTransfer(IERC20(address(aToken)), user, nominal);
        if (_increase(aToken.scaledBalanceOf(user), userBefore) != scaled) revert AccountingFailure();
        _emitSettlement(id, user, rewardAmount, nominal);
    }

    function _executeAaveV4Batch(AdapterStorage storage state, BatchExecution calldata request)
        internal
        returns (uint256 totalShares)
    {
        for (uint256 i; i < request.accounts.length; ++i) {
            uint256 minimum = request.minUserAmountsOut[i];
            if (minimum == 0) revert InvalidExecutionRequest();
            uint256 shares = _supplyAaveV4(state, request.accounts[i], request.amountsIn[i], minimum);
            totalShares += shares;
            _emitSettlement(request.strategyId, request.accounts[i], request.amountsIn[i], shares);
        }
    }

    function _supplyAaveV4(AdapterStorage storage state, address user, uint256 amount, uint256 minimum)
        internal
        returns (uint256 suppliedShares)
    {
        AaveV4Config memory config = state.aaveV4;
        IAaveV4Spoke spoke = IAaveV4Spoke(config.spoke);
        address giver = state.aaveV4Giver;
        // Users authorize the official Giver; the project Proxy needs no Aave governance registration.
        if (
            giver.code.length == 0 || !IAaveV4Giver(giver).isSpokeRegistered(config.spoke)
                || !spoke.isPositionManagerActive(giver) || !spoke.isPositionManager(user, giver)
        ) revert AaveV4AuthorizationFailure();
        uint256 sharesBefore = spoke.getUserSuppliedShares(config.reserveId, user);
        uint256 giverBalanceBefore = state.usdc.balanceOf(giver);
        _approveExact(state.usdc, giver, amount);
        uint256 suppliedAssets;
        (suppliedShares, suppliedAssets) =
            IAaveV4Giver(giver).supplyOnBehalfOf(config.spoke, config.reserveId, amount, user);
        _clearAllowance(state.usdc, giver);
        if (suppliedAssets != amount || state.usdc.balanceOf(giver) != giverBalanceBefore) revert AccountingFailure();
        if (suppliedShares < minimum) revert SlippageFailure();
        if (_increase(spoke.getUserSuppliedShares(config.reserveId, user), sharesBefore) != suppliedShares) {
            revert AccountingFailure();
        }
    }

    function _executeMaple(AdapterStorage storage state, uint256 amount, bytes calldata authorizationData)
        internal
        returns (uint256 sharesOut)
    {
        MapleConfig memory config = state.maple;
        ISyrupRouter router = ISyrupRouter(config.router);
        (address manager, IPoolPermissionManager permissions) = _mapleContext(router);
        _requireMapleTransferable(manager, permissions);
        bool authorized = _checkMapleAuthorization(router, manager, permissions, authorizationData);
        IERC20 syrupToken = IERC20(config.syrupToken);
        uint256 sharesBefore = syrupToken.balanceOf(address(this));
        _approveExact(state.usdc, config.router, amount);

        uint256 reported;
        if (authorized) {
            reported = router.deposit(amount, config.depositData);
        } else {
            (uint256 bitmap, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
                abi.decode(authorizationData, (uint256, uint256, uint8, bytes32, bytes32));
            uint256 nonce = router.nonces(address(this));
            reported = router.authorizeAndDeposit(bitmap, deadline, v, r, s, amount, config.depositData);
            (address postManager, IPoolPermissionManager postPermissions) = _mapleContext(router);
            if (router.nonces(address(this)) != nonce + 1 || !_mapleAuthorized(router, postManager, postPermissions)) {
                revert MapleAuthorizationFailure();
            }
            emit MapleAuthorizationConsumed(nonce + 1);
        }

        _clearAllowance(state.usdc, config.router);
        sharesOut = _increase(syrupToken.balanceOf(address(this)), sharesBefore);
        if (sharesOut != reported) revert AccountingFailure();
    }

    function _checkMapleAuthorization(
        ISyrupRouter router,
        address manager,
        IPoolPermissionManager permissions,
        bytes calldata authorizationData
    ) internal view returns (bool authorized) {
        if (authorizationData.length != 0 && authorizationData.length != 160) {
            revert MapleAuthorizationFailure();
        }
        if (!permissions.hasPermission(manager, address(router), P_DEPOSIT)) revert MapleAuthorizationFailure();
        authorized = permissions.hasPermission(manager, address(this), P_DEPOSIT);
        if (authorized) {
            if (authorizationData.length != 0) revert MapleAuthorizationFailure();
            return true;
        }
        if (authorizationData.length == 0) revert MapleAuthorizationFailure();
        (uint256 bitmap, uint256 deadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(authorizationData, (uint256, uint256, uint8, bytes32, bytes32));
        uint256 required = permissions.poolBitmaps(manager, P_DEPOSIT);
        if (
            deadline <= block.timestamp || (v != 27 && v != 28) || r == bytes32(0) || s == bytes32(0)
                || (bitmap & required) != required
        ) revert MapleAuthorizationFailure();
    }

    function _mapleAuthorized(ISyrupRouter router, address manager, IPoolPermissionManager permissions)
        internal
        view
        returns (bool)
    {
        return permissions.hasPermission(manager, address(router), P_DEPOSIT)
            && permissions.hasPermission(manager, address(this), P_DEPOSIT);
    }

    function _requireMapleTransferable(address manager, IPoolPermissionManager permissions) internal view {
        if (permissions.poolBitmaps(manager, P_TRANSFER) != 0 || permissions.poolBitmaps(manager, P_TRANSFER_FROM) != 0)
        {
            revert MapleAuthorizationFailure();
        }
    }

    function _mapleContext(ISyrupRouter router)
        internal
        view
        returns (address manager, IPoolPermissionManager permissions)
    {
        manager = _readAddress(address(router), ISyrupRouter.poolManager.selector);
        address permissionManager = _readAddress(address(router), ISyrupRouter.poolPermissionManager.selector);
        if (manager.code.length == 0 || permissionManager.code.length == 0) revert ConfigurationFailure();
        permissions = IPoolPermissionManager(permissionManager);
    }

    function _validateBatch(address[] calldata users, uint256[] calldata amounts)
        internal
        pure
        returns (uint256 total)
    {
        if (users.length == 0 || users.length != amounts.length) {
            revert InvalidExecutionRequest();
        }
        for (uint256 i; i < users.length; ++i) {
            if (users[i] == address(0)) revert InvalidExecutionRequest();
            if (amounts[i] == 0) revert InvalidExecutionRequest();
            total += amounts[i];
        }
    }

    function _distributeToken(
        bytes32 id,
        IERC20 token,
        address[] calldata users,
        uint256[] calldata amounts,
        uint256 totalIn,
        uint256 totalOut
    ) internal {
        uint256 largest = _largestIndex(amounts);
        uint256 distributed;
        for (uint256 i; i < users.length; ++i) {
            if (i == largest) continue;
            uint256 output = Math.mulDiv(totalOut, amounts[i], totalIn);
            if (output == 0) revert InvalidExecutionRequest();
            distributed += output;
            _sendExact(token, users[i], output);
            _emitSettlement(id, users[i], amounts[i], output);
        }
        uint256 largestOutput = totalOut - distributed;
        _sendExact(token, users[largest], largestOutput);
        _emitSettlement(id, users[largest], amounts[largest], largestOutput);
    }

    function _emitSettlement(bytes32 id, address user, uint256 rewardAmount, uint256 amountOut) internal {
        emit UserStrategySettled(id, user, rewardAmount, amountOut);
    }

    function _largestIndex(uint256[] calldata amounts) internal pure returns (uint256 largest) {
        uint256 largestAmount;
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] > largestAmount) {
                largestAmount = amounts[i];
                largest = i;
            }
        }
    }

    function _sendExact(IERC20 token, address recipient, uint256 amount) internal {
        uint256 beforeBalance = token.balanceOf(recipient);
        _safeTransfer(token, recipient, amount);
        if (_increase(token.balanceOf(recipient), beforeBalance) != amount) revert AccountingFailure();
    }

    function _safeTransfer(IERC20 token, address recipient, uint256 amount) internal {
        if (!_tryTokenCall(token, IERC20.transfer.selector, recipient, amount)) revert AccountingFailure();
    }

    function _forceApprove(IERC20 token, address spender, uint256 amount) internal {
        if (!_tryTokenCall(token, IERC20.approve.selector, spender, amount)) {
            if (
                !_tryTokenCall(token, IERC20.approve.selector, spender, 0)
                    || !_tryTokenCall(token, IERC20.approve.selector, spender, amount)
            ) revert AccountingFailure();
        }
    }

    function _tryTokenCall(IERC20 token, bytes4 selector, address account, uint256 amount)
        internal
        returns (bool success)
    {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(0, selector)
            mstore(4, and(account, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(36, amount)
            success := call(gas(), token, 0, 0, 68, 0, 32)
            switch returndatasize()
            case 0 { success := and(success, gt(extcodesize(token), 0)) }
            case 32 { success := and(success, eq(mload(0), 1)) }
            default { success := 0 }
            mstore(0x40, free)
            mstore(0x60, 0)
        }
    }

    function _approveExact(IERC20 token, address spender, uint256 amount) internal {
        _forceApprove(token, spender, amount);
        if (token.allowance(address(this), spender) != amount) {
            revert AccountingFailure();
        }
    }

    function _clearAllowance(IERC20 token, address spender) internal {
        _forceApprove(token, spender, 0);
        uint256 remaining = token.allowance(address(this), spender);
        if (remaining != 0) revert AccountingFailure();
    }

    function _increase(uint256 afterValue, uint256 beforeValue) internal pure returns (uint256 delta) {
        if (afterValue < beforeValue) revert AccountingFailure();
        unchecked {
            return afterValue - beforeValue;
        }
    }

    function _decrease(uint256 beforeValue, uint256 afterValue) internal pure returns (uint256 delta) {
        if (afterValue > beforeValue) revert AccountingFailure();
        unchecked {
            return beforeValue - afterValue;
        }
    }

    function _firstToken(bytes memory path) internal pure returns (address token) {
        assembly ("memory-safe") {
            token := shr(96, mload(add(path, 32)))
        }
    }

    function _lastToken(bytes memory path) internal pure returns (address token) {
        uint256 length = path.length;
        assembly ("memory-safe") {
            token := shr(96, mload(add(add(path, 32), sub(length, 20))))
        }
    }

    function _readAddress(address target, bytes4 selector) internal view returns (address value) {
        bytes4 callSelector = selector;
        bool ok;
        uint256 size;
        uint256 raw;
        assembly ("memory-safe") {
            mstore(0, callSelector)
            ok := staticcall(gas(), target, 0, 4, 0, 0)
            size := returndatasize()
            if eq(size, 32) {
                returndatacopy(0, 0, 32)
                raw := mload(0)
            }
        }
        if (!ok || size != 32 || raw > type(uint160).max) revert ConfigurationFailure();
        value = address(uint160(raw));
    }

    function _reserveAToken(address pool, address asset) internal view returns (address value) {
        bytes4 selector = IAaveV3Pool.getReserveData.selector;
        bool ok;
        uint256 size;
        uint256 raw;
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(4, and(asset, 0xffffffffffffffffffffffffffffffffffffffff))
            ok := staticcall(gas(), pool, 0, 36, 0, 0)
            size := returndatasize()
            if iszero(lt(size, 480)) {
                returndatacopy(0, 256, 32)
                raw := mload(0)
            }
        }
        if (!ok || size < 480 || raw > type(uint160).max) revert ConfigurationFailure();
        value = address(uint160(raw));
    }

    function _reserveUnderlying(address spoke, uint256 reserveId) internal view returns (address value) {
        bytes4 selector = IAaveV4Spoke.getReserve.selector;
        bool ok;
        uint256 size;
        uint256 raw;
        assembly ("memory-safe") {
            mstore(0, selector)
            mstore(4, reserveId)
            ok := staticcall(gas(), spoke, 0, 36, 0, 0)
            size := returndatasize()
            if eq(size, 224) {
                returndatacopy(0, 0, 32)
                raw := mload(0)
            }
        }
        if (!ok || size != 224 || raw > type(uint160).max) revert ConfigurationFailure();
        value = address(uint160(raw));
    }

    function _adapterStorage() internal pure returns (AdapterStorage storage state) {
        bytes32 location = ADAPTER_STORAGE_LOCATION;
        assembly ("memory-safe") {
            state.slot := location
        }
    }
}
