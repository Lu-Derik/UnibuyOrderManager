// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";

/// @title ImmutableState for UnibuyOrderManager
/// @notice Provides immutable poolManager and onlyPoolManager modifier
abstract contract ImmutableState {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IUnibuyPoolManager public immutable poolManager;

    error NotPoolManager();

    modifier onlyPoolManager() {
        _onlyPoolManager();
        _;
    }

    function _onlyPoolManager() internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    constructor(IUnibuyPoolManager _poolManager) {
        poolManager = _poolManager;
    }
}
