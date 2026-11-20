// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Mirrors the XMetroDeFiAdapter ABI (packages/xmetro, solc 0.8.38); enum order and struct layouts must match.
interface ICommissionPayoutAdapter {
    enum StrategyKind {
        None,
        SwapMetro,
        AutoSwap,
        AaveV3,
        AaveV4,
        Maple
    }

    struct StrategyInfo {
        StrategyKind kind;
        bool enabled;
        bool autoEnabled;
        uint64 logicEpoch;
        uint64 domainRevision;
        uint64 strategyRevision;
        address outputToken;
    }

    struct ManualExecution {
        bytes32 strategyId;
        address account;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        bytes executionData;
    }

    struct BatchExecution {
        bytes32 strategyId;
        address[] accounts;
        uint256[] amountsIn;
        uint256 minTotalAmountOut;
        uint256[] minUserAmountsOut;
        uint256 deadline;
        bytes executionData;
    }

    struct ExecutionResult {
        address outputToken;
        uint256 amountIn;
        uint256 amountOut;
    }

    function strategyInfo(bytes32 id) external view returns (StrategyInfo memory info);
    function execute(ManualExecution calldata request) external returns (ExecutionResult memory result);
    function executeBatch(BatchExecution calldata request) external returns (ExecutionResult memory result);
}

interface IXMetroStaking {
    function stake(uint256 amount) external returns (uint256 mintedShares);
}
