// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Locker} from "../libraries/Locker.sol";

/// @notice A transient reentrancy lock, that stores the caller's address as the lock
contract ReentrancyLock {
    error ContractLocked();

    modifier isNotLocked() {
        _acquireLock();
        _;
        _releaseLock();
    }

    function _acquireLock() internal {
        if (Locker.get() != address(0)) revert ContractLocked();
        Locker.set(msg.sender);
    }

    function _releaseLock() internal {
        Locker.set(address(0));
    }

    function _getLocker() internal view returns (address) {
        return Locker.get();
    }
}
