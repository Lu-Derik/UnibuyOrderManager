// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Action Constants
/// @notice Common constants used by action routers
library ActionConstants {
    /// @notice Used to signal that an action should consume the full open delta amount.
    /// @dev For exact-input actions, this means full credit of the input currency.
    ///      For exact-output actions, this means full debt of the output currency.
    uint128 internal constant OPEN_DELTA = 0;

    /// @notice used to signal that recipient should be msgSender()
    address internal constant MSG_SENDER = address(1);

    /// @notice used to signal that recipient should be address(this)
    address internal constant ADDRESS_THIS = address(2);
}
