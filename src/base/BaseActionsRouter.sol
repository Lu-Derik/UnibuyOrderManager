// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";

/// @title BaseActionsRouter for UnibuyOrderManager
/// @notice Provides unlock/_unlockCallback pattern and delta settlement for poolManager interaction
abstract contract BaseActionsRouter is IMsgSender, SafeCallback {
    using CalldataDecoder for bytes;

    /// @notice emitted when different numbers of parameters and actions are provided
    error InputLengthMismatch();

    /// @notice emitted when an inheriting contract does not support an action
    error UnsupportedAction(uint256 action);

    constructor(IUnibuyPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @notice Internal function to trigger poolManager.unlock.
    function _executeActions(bytes memory unlockData) internal {
        poolManager.unlock(unlockData);
    }

    /// @notice Called by poolManager via unlockCallback (see SafeCallback)
    /// @param data abi.encode(bytes actions, bytes[] params)
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        _executeActionsWithoutUnlock(actions, params);
        return "";
    }

    function _executeActionsWithoutUnlock(bytes calldata actions, bytes[] calldata params) internal {
        uint256 numActions = actions.length;
        if (numActions != params.length) revert InputLengthMismatch();

        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);
            _handleAction(action, params[actionIndex]);
        }
    }

    /// @notice Parse and execute an action and its parameters
    function _handleAction(uint256 action, bytes calldata params) internal virtual;

    /// @notice Returns address considered executor of the actions
    function msgSender() public view virtual returns (address);

    /// @notice Calculates the recipient address for an action
    function _mapRecipient(address recipient) internal view returns (address) {
        if (recipient == ActionConstants.MSG_SENDER) {
            return msgSender();
        } else if (recipient == ActionConstants.ADDRESS_THIS) {
            return address(this);
        } else {
            return recipient;
        }
    }

    /// @notice Calculates the payer for an action
    function _mapPayer(bool payerIsUser) internal view returns (address) {
        return payerIsUser ? msgSender() : address(this);
    }
}
