// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IXMetroDeFiAdapter {
    /// @dev Strategy IDs are keccak256(abi.encode(chainId,
    ///      keccak256("XMETRO_DEFI_STRATEGY_V1"), kind, outputToken)).
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

    function xMETRO() external view returns (address);
    function USDC() external view returns (address);
    function METRO() external view returns (address);
    function adapterFamilyId() external pure returns (bytes32);
    function implementationVersion() external pure returns (uint64);
    function logicEpoch() external view returns (uint64);

    function strategyInfo(bytes32 id) external view returns (StrategyInfo memory info);

    function execute(ManualExecution calldata request) external returns (ExecutionResult memory result);
    function executeBatch(BatchExecution calldata request) external returns (ExecutionResult memory result);
}
