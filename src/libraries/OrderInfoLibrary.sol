// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyOrderManager} from "../interfaces/IUnibuyOrderManager.sol";

/**
 * @dev Packed order info for maker NFTs.
 * Layout (from least significant bits):
 * - 8 bits   active flag
 * - 24 bits  tickLower
 * - 24 bits  tickUpper
 * - 200 bits poolId (bytes25)
 */
type PackedOrderInfo is uint256;

using OrderInfoLibrary for PackedOrderInfo global;

library OrderInfoLibrary {
    PackedOrderInfo internal constant EMPTY_ORDER_INFO = PackedOrderInfo.wrap(0);

    uint256 internal constant MASK_UPPER_200_BITS =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000;
    uint256 internal constant MASK_8_BITS = 0xFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;
    uint256 internal constant SET_INACTIVE =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00;
    uint256 internal constant SET_ACTIVE = 0x01;

    uint8 internal constant TICK_LOWER_OFFSET = 8;
    uint8 internal constant TICK_UPPER_OFFSET = 32;

    function poolId(PackedOrderInfo info) internal pure returns (bytes25 _poolId) {
        assembly ("memory-safe") {
            _poolId := and(MASK_UPPER_200_BITS, info)
        }
    }

    function tickLower(PackedOrderInfo info) internal pure returns (int24 _tickLower) {
        assembly ("memory-safe") {
            _tickLower := signextend(2, shr(TICK_LOWER_OFFSET, info))
        }
    }

    function tickUpper(PackedOrderInfo info) internal pure returns (int24 _tickUpper) {
        assembly ("memory-safe") {
            _tickUpper := signextend(2, shr(TICK_UPPER_OFFSET, info))
        }
    }

    function active(PackedOrderInfo info) internal pure returns (bool _active) {
        assembly ("memory-safe") {
            _active := and(MASK_8_BITS, info)
        }
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setActive(PackedOrderInfo info) internal pure returns (PackedOrderInfo _info) {
        assembly ("memory-safe") {
            _info := or(info, SET_ACTIVE)
        }
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setInactive(PackedOrderInfo info) internal pure returns (PackedOrderInfo _info) {
        assembly ("memory-safe") {
            _info := and(info, SET_INACTIVE)
        }
    }

    function initialize(bytes25 _poolId, int24 _tickLower, int24 _tickUpper)
        internal
        pure
        returns (PackedOrderInfo info)
    {
        assembly {
            info := or(
                or(and(MASK_UPPER_200_BITS, _poolId), shl(TICK_UPPER_OFFSET, and(MASK_24_BITS, _tickUpper))),
                or(shl(TICK_LOWER_OFFSET, and(MASK_24_BITS, _tickLower)), SET_ACTIVE)
            )
        }
    }

    function toOrderInfo(PackedOrderInfo info)
        internal
        pure
        returns (IUnibuyOrderManager.OrderInfo memory)
    {
        return IUnibuyOrderManager.OrderInfo({
            poolId: poolId(info),
            tickLower: tickLower(info),
            tickUpper: tickUpper(info),
            active: active(info)
        });
    }
}
