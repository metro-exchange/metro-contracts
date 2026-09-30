// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IXMetroDeFiAdapter} from "../../src/interfaces/IXMetroDeFiAdapter.sol";

/// @notice Type-safe Core test double. Its configuration ABI is exactly 512 bytes, like production.
contract MockXMetroDeFiAdapter is IXMetroDeFiAdapter {
    using SafeERC20 for IERC20;

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

    bytes32 public constant FAMILY = keccak256("XMETRO_DEFI_ADAPTER_FAMILY_V1");
    bytes32 public constant DOMAIN = keccak256("XMETRO_DEFI_STRATEGY_V1");

    address public immutable override xMETRO;
    address public immutable override USDC;
    address public immutable override METRO;
    uint64 public override logicEpoch = 1;
    uint256 public mul;
    uint256 public div;
    bool public shouldRevert;
    bool public skipOutput;
    uint256 public reportedAmountOverride;
    uint256 public callCount;

    constructor(address core, address usdc, address metro, uint256 mul_, uint256 div_) {
        require(core != address(0) && usdc != address(0) && metro != address(0) && div_ != 0);
        xMETRO = core;
        USDC = usdc;
        METRO = metro;
        mul = mul_;
        div = div_;
    }

    function adapterFamilyId() external pure returns (bytes32) {
        return FAMILY;
    }

    function implementationVersion() external pure returns (uint64) {
        return 1;
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
        return (
            xMETRO,
            USDC,
            METRO,
            FAMILY,
            logicEpoch,
            address(0),
            address(0),
            address(0),
            AaveV3Config(address(0), address(0), 0),
            AaveV4Config(address(0), 0),
            MapleConfig(address(0), address(0), bytes32(0))
        );
    }

    function strategyInfo(bytes32 id) external view returns (StrategyInfo memory info) {
        bytes32 expected = keccak256(abi.encode(block.chainid, DOMAIN, StrategyKind.SwapMetro, METRO));
        if (id == expected) return StrategyInfo(StrategyKind.SwapMetro, true, true, logicEpoch, 1, 1, METRO);
    }

    function setRate(uint256 mul_, uint256 div_) external {
        require(div_ != 0);
        mul = mul_;
        div = div_;
    }

    function setBehavior(bool shouldRevert_, bool skipOutput_, uint256 reportedAmountOverride_) external {
        shouldRevert = shouldRevert_;
        skipOutput = skipOutput_;
        reportedAmountOverride = reportedAmountOverride_;
    }

    function execute(ManualExecution calldata request) external returns (ExecutionResult memory result) {
        require(msg.sender == xMETRO && !shouldRevert);
        ++callCount;
        uint256 output = (request.amountIn * mul) / div;
        require(output >= request.minAmountOut);
        if (!skipOutput) IERC20(METRO).safeTransfer(xMETRO, output);
        result = ExecutionResult(METRO, request.amountIn, reportedAmountOverride == 0 ? output : reportedAmountOverride);
    }

    function executeBatch(BatchExecution calldata request) external returns (ExecutionResult memory result) {
        require(msg.sender == xMETRO && !shouldRevert);
        ++callCount;
        uint256 input;
        for (uint256 i; i < request.amountsIn.length; ++i) {
            input += request.amountsIn[i];
        }
        uint256 output = (input * mul) / div;
        require(output >= request.minTotalAmountOut);
        if (!skipOutput) IERC20(METRO).safeTransfer(xMETRO, output);
        result = ExecutionResult(METRO, input, reportedAmountOverride == 0 ? output : reportedAmountOverride);
    }
}
