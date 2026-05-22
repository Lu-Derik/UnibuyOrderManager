// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {DeltaResolver} from "./DeltaResolver.sol";

/// @title BaseActionsRouter for UnibuyOrderManager
/// @notice Provides unlock/_unlockCallback pattern and delta settlement for poolManager interaction
abstract contract BaseActionsRouter is SafeCallback, DeltaResolver {
    constructor(IUnibuyPoolManager _poolManager) SafeCallback(_poolManager) {}

    /// @notice Internal function to trigger poolManager.unlock; returns the callback result.
    function _executeActions(bytes memory unlockData) internal returns (bytes memory) {
        return poolManager.unlock(unlockData);
    }

    /// @notice Called by poolManager via unlockCallback (see SafeCallback)
    function _unlockCallback(bytes calldata data) internal override virtual returns (bytes memory);
}
