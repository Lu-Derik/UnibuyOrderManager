// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {IUnlockCallback} from "@unibuy/interfaces/IUnlockCallback.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title SafeCallback for UnibuyOrderManager
/// @notice Restricts unlockCallback to only the poolManager
abstract contract SafeCallback is ImmutableState, IUnlockCallback {
    constructor(IUnibuyPoolManager _poolManager) ImmutableState(_poolManager) {}

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager override returns (bytes memory) {
        return _unlockCallback(data);
    }

    /// @dev To be implemented by child contract
    function _unlockCallback(bytes calldata data) internal virtual returns (bytes memory);
}
