// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


/**
 * @dev Packed order info for maker NFTs.
 * Layout (from least significant bits):
 * - 8 bits   flags byte (bit0: chained, bit1: auto)
 * - 24 bits  tickLower
 * - 24 bits  tickUpper
 * - 24 bits  tickLowerMirror
 * - 24 bits  tickUpperMirror
 * - 152 bits poolId (bytes19)
 */
type PackedOrderInfo is uint256;

using OrderInfoLibrary for PackedOrderInfo global;

library OrderInfoLibrary {
    PackedOrderInfo internal constant EMPTY_ORDER_INFO = PackedOrderInfo.wrap(0);

    uint256 internal constant MASK_UPPER_152_BITS =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000;
    uint256 internal constant MASK_LOWER_104_BITS = type(uint256).max ^ MASK_UPPER_152_BITS;
    uint256 internal constant MASK_8_BITS = 0xFF;
    uint24 internal constant MASK_24_BITS = 0xFFFFFF;
    uint256 internal constant FLAG_CHAINED = 0x01;
    uint256 internal constant FLAG_AUTO = 0x02;
    uint256 internal constant CLEAR_CHAINED =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE;
    uint256 internal constant CLEAR_AUTO =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFD;

    uint8 internal constant TICK_LOWER_OFFSET = 8;
    uint8 internal constant TICK_UPPER_OFFSET = 32;
    uint8 internal constant TICK_LOWER_MIRROR_OFFSET = 56;
    uint8 internal constant TICK_UPPER_MIRROR_OFFSET = 80;

    uint256 internal constant CLEAR_TICK_LOWER =
        ~(uint256(MASK_24_BITS) << TICK_LOWER_OFFSET);
    uint256 internal constant CLEAR_TICK_UPPER =
        ~(uint256(MASK_24_BITS) << TICK_UPPER_OFFSET);
    uint256 internal constant CLEAR_TICK_LOWER_MIRROR =
        ~(uint256(MASK_24_BITS) << TICK_LOWER_MIRROR_OFFSET);
    uint256 internal constant CLEAR_TICK_UPPER_MIRROR =
        ~(uint256(MASK_24_BITS) << TICK_UPPER_MIRROR_OFFSET);

    function poolId(PackedOrderInfo info) internal pure returns (bytes19 _poolId) {
        assembly ("memory-safe") {
            _poolId := and(MASK_UPPER_152_BITS, info)
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

    function tickLowerMirror(PackedOrderInfo info) internal pure returns (int24 _tickLowerMirror) {
        assembly ("memory-safe") {
            _tickLowerMirror := signextend(2, shr(TICK_LOWER_MIRROR_OFFSET, info))
        }
    }

    function tickUpperMirror(PackedOrderInfo info) internal pure returns (int24 _tickUpperMirror) {
        assembly ("memory-safe") {
            _tickUpperMirror := signextend(2, shr(TICK_UPPER_MIRROR_OFFSET, info))
        }
    }

    function chained(PackedOrderInfo info) internal pure returns (bool _chained) {
        assembly ("memory-safe") {
            _chained := and(FLAG_CHAINED, and(MASK_8_BITS, info))
        }
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setChained(PackedOrderInfo info) internal pure returns (PackedOrderInfo _info) {
        assembly ("memory-safe") {
            _info := or(info, FLAG_CHAINED)
        }
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setUnchained(PackedOrderInfo info) internal pure returns (PackedOrderInfo _info) {
        assembly ("memory-safe") {
            _info := and(info, CLEAR_CHAINED)
        }
    }

    function autoClose(PackedOrderInfo info) internal pure returns (bool _auto) {
        assembly ("memory-safe") {
            _auto := and(FLAG_AUTO, and(MASK_8_BITS, info))
        }
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setAuto(PackedOrderInfo info) internal pure returns (PackedOrderInfo _info) {
        assembly ("memory-safe") {
            _info := or(info, FLAG_AUTO)
        }
    }

    /// @dev Does not write to storage; returns updated packed value.
    function clearAuto(PackedOrderInfo info) internal pure returns (PackedOrderInfo _info) {
        assembly ("memory-safe") {
            _info := and(info, CLEAR_AUTO)
        }
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setPoolId(PackedOrderInfo info, bytes19 _poolId) internal pure returns (PackedOrderInfo _info) {
        uint256 raw = PackedOrderInfo.unwrap(info);
        uint256 poolPart = uint256(bytes32(_poolId)) & MASK_UPPER_152_BITS;
        _info = PackedOrderInfo.wrap((raw & MASK_LOWER_104_BITS) | poolPart);
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setTickLower(PackedOrderInfo info, int24 _tickLower) internal pure returns (PackedOrderInfo _info) {
        uint256 raw = PackedOrderInfo.unwrap(info);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tickPart = (uint256(uint24(_tickLower)) & MASK_24_BITS) << TICK_LOWER_OFFSET;
        _info = PackedOrderInfo.wrap((raw & CLEAR_TICK_LOWER) | tickPart);
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setTickUpper(PackedOrderInfo info, int24 _tickUpper) internal pure returns (PackedOrderInfo _info) {
        uint256 raw = PackedOrderInfo.unwrap(info);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tickPart = (uint256(uint24(_tickUpper)) & MASK_24_BITS) << TICK_UPPER_OFFSET;
        _info = PackedOrderInfo.wrap((raw & CLEAR_TICK_UPPER) | tickPart);
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setTickLowerMirror(PackedOrderInfo info, int24 _tickLowerMirror)
        internal
        pure
        returns (PackedOrderInfo _info)
    {
        uint256 raw = PackedOrderInfo.unwrap(info);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tickPart = (uint256(uint24(_tickLowerMirror)) & MASK_24_BITS) << TICK_LOWER_MIRROR_OFFSET;
        _info = PackedOrderInfo.wrap((raw & CLEAR_TICK_LOWER_MIRROR) | tickPart);
    }

    /// @dev Does not write to storage; returns updated packed value.
    function setTickUpperMirror(PackedOrderInfo info, int24 _tickUpperMirror)
        internal
        pure
        returns (PackedOrderInfo _info)
    {
        uint256 raw = PackedOrderInfo.unwrap(info);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tickPart = (uint256(uint24(_tickUpperMirror)) & MASK_24_BITS) << TICK_UPPER_MIRROR_OFFSET;
        _info = PackedOrderInfo.wrap((raw & CLEAR_TICK_UPPER_MIRROR) | tickPart);
    }

    function initialize(
        bytes19 _poolId,
        int24 _tickLower,
        int24 _tickUpper,
        int24 _tickLowerMirror,
        int24 _tickUpperMirror
    )
        internal
        pure
        returns (PackedOrderInfo info)
    {
        assembly {
            info := or(
                or(
                    or(
                        and(MASK_UPPER_152_BITS, _poolId),
                        shl(TICK_UPPER_MIRROR_OFFSET, and(MASK_24_BITS, _tickUpperMirror))
                    ),
                    shl(TICK_LOWER_MIRROR_OFFSET, and(MASK_24_BITS, _tickLowerMirror))
                ),
                or(
                    or(shl(TICK_UPPER_OFFSET, and(MASK_24_BITS, _tickUpper)), shl(TICK_LOWER_OFFSET, and(MASK_24_BITS, _tickLower))),
                    FLAG_CHAINED
                )
            )
        }
    }

}
