// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMsgSender
/// @notice Interface for contracts that expose the original caller
interface IMsgSender {
    /// @notice Returns the address considered the original caller of the action batch
    function msgSender() external view returns (address);
}
