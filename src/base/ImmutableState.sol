// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";

/// @title ImmutableState for UnibuyOrderManager
/// @notice Provides immutable poolManager and onlyPoolManager modifier
abstract contract ImmutableState {
    IUnibuyPoolManager public immutable poolManager;

    error NotPoolManager();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IUnibuyPoolManager _poolManager) {
        poolManager = _poolManager;
    }
}
