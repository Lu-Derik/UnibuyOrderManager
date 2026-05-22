// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IUnorderedNonce
interface IUnorderedNonce {
    error NonceAlreadyUsed();

    /// @notice Revokes a nonce, reverting if nonce is already used
    function revokeNonce(uint256 nonce) external payable;
}
