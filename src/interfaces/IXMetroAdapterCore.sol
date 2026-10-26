// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal immutable-Core surface used by the upgradeable DeFi adapter.
interface IXMetroAdapterCore {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function deFiAdapter() external view returns (address);
}
