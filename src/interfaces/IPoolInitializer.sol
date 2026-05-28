// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UnibuyPoolKey} from "@unibuy/types/UnibuyPoolKey.sol";

/// @title IPoolInitializer
/// @notice Interface for initializing a UniBuy pool pair from periphery contracts.
interface IPoolInitializer {
    /// @notice Initialize a UniBuy pool pair.
    /// @dev If initialization fails (already initialized/invalid input), implementations should not revert
    ///      and should return type(int24).max.
    /// @param key The UniBuy pool key.
    /// @param sqrtPriceX96 The initial forward-pool price in sqrt Q64.96 format.
    /// @return tick The initialized forward-pool tick, or type(int24).max when initialization failed.
    function initializePool(UnibuyPoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24 tick);
}
