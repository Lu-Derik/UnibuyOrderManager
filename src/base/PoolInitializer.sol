// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ImmutableState} from "./ImmutableState.sol";
import {StateLibrary} from "@unibuy/libraries/StateLibrary.sol";
import {UnibuyPoolKey, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {IPoolInitializer} from "../interfaces/IPoolInitializer.sol";

/// @title PoolInitializer
/// @notice Initializes a UniBuy pool pair.
/// @dev Enables pool initialization + actions in a single transaction when used with multicall.
abstract contract PoolInitializer is ImmutableState, IPoolInitializer {
    using UnibuyPoolIdLibrary for UnibuyPoolKey;
    using StateLibrary for IUnibuyPoolManager;

    /// @inheritdoc IPoolInitializer
    function initializePool(UnibuyPoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24) {
        try poolManager.initialize(key, sqrtPriceX96) {
            (, int24 tick,,,,,) = poolManager.getSlot0(key.toId());
            return tick;
        } catch {
            return type(int24).max;
        }
    }
}
