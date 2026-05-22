// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Locker
/// @notice Library for managing transient lock state
library Locker {
    // bytes32(uint256(keccak256("unibuy.Locker")) - 1)
    bytes32 private constant LOCKER_SLOT = 0xa8c8a72ceebe10e4bd6eb9d9c5614c6a1bab5ad85f4d23eed62a9f52a6a5c4da;

    function get() internal view returns (address locker) {
        assembly ("memory-safe") {
            locker := tload(LOCKER_SLOT)
        }
    }

    function set(address locker) internal {
        assembly ("memory-safe") {
            tstore(LOCKER_SLOT, locker)
        }
    }
}
