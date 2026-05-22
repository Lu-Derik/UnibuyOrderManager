// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IMulticall_v4
interface IMulticall_v4 {
    /// @notice Calls multiple functions in the same transaction
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
