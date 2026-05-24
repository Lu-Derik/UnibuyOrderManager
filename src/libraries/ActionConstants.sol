// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Action Constants
/// @notice Common constants used by action routers
library ActionConstants {
    /// @notice used to signal that recipient should be msgSender()
    address internal constant MSG_SENDER = address(1);

    /// @notice used to signal that recipient should be address(this)
    address internal constant ADDRESS_THIS = address(2);
}
