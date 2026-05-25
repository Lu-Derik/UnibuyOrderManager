// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UnibuyPoolKey} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency} from "@unibuy/types/Currency.sol";
import {PathKey} from "./PathKey.sol";

/// @title CalldataDecoder
/// @notice Efficient calldata decoders used by UnibuyOrderManager action routing.
library CalldataDecoder {
    error SliceOutOfBounds();

    struct TakeOrderInputSingleParams {
        UnibuyPoolKey poolKey;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct TakeOrderOutputSingleParams {
        UnibuyPoolKey poolKey;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct TakeOrderInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct TakeOrderOutputParams {
        Currency currencyOut;
        PathKey[] path;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    struct PlaceOrderWithTakeParams {
        UnibuyPoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        address recipient;
    }

    /// @notice mask used for offsets and lengths to ensure no overflow
    uint256 internal constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
    uint256 internal constant OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN = 0xffffffe0;

    /// @notice equivalent to SliceOutOfBounds.selector, stored in least-significant bits
    uint256 internal constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

    /// @dev equivalent to: abi.decode(data, (bytes, bytes[])) in calldata (strict ABI encoding)
    function decodeActionsRouterParams(bytes calldata data)
        internal
        pure
        returns (bytes calldata actions, bytes[] calldata params)
    {
        assembly ("memory-safe") {
            let invalidData := xor(calldataload(data.offset), 0x40)

            actions.offset := add(data.offset, 0x60)
            actions.length := and(calldataload(add(data.offset, 0x40)), OFFSET_OR_LENGTH_MASK)

            let paramsLengthOffset := add(and(add(actions.length, 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x60)
            invalidData := or(invalidData, xor(calldataload(add(data.offset, 0x20)), paramsLengthOffset))

            let paramsLengthPointer := add(data.offset, paramsLengthOffset)
            params.length := and(calldataload(paramsLengthPointer), OFFSET_OR_LENGTH_MASK)
            params.offset := add(paramsLengthPointer, 0x20)

            let tailOffset := shl(5, params.length)
            let expectedOffset := tailOffset

            for { let offset := 0 } lt(offset, tailOffset) { offset := add(offset, 32) } {
                let itemLengthOffset := calldataload(add(params.offset, offset))
                invalidData := or(invalidData, xor(itemLengthOffset, expectedOffset))

                let itemLengthPointer := add(params.offset, itemLengthOffset)
                let length :=
                    add(and(add(calldataload(itemLengthPointer), 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x20)
                expectedOffset := add(expectedOffset, length)
            }

            if or(invalidData, lt(add(data.length, data.offset), add(params.offset, expectedOffset))) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }

    /// @dev equivalent to abi.decode(params, (UnibuyPoolKey, uint256, uint256, uint160))
    ///      Used for TAKE_ORDER_INPUT_SINGLE: (poolKey, amountIn, amountOutMinimum, sqrtPriceLimitX96)
    function decodeTakeOrderInputSingleParams(bytes calldata params)
        internal
        pure
        returns (TakeOrderInputSingleParams calldata takeParams)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0xc0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            takeParams := params.offset
        }
    }

    /// @dev equivalent to abi.decode(params, (UnibuyPoolKey, uint256, uint256, uint160))
    ///      Used for TAKE_ORDER_OUTPUT_SINGLE: (poolKey, amountOut, amountInMaximum, sqrtPriceLimitX96)
    function decodeTakeOrderOutputSingleParams(bytes calldata params)
        internal
        pure
        returns (TakeOrderOutputSingleParams calldata takeParams)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0xc0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            takeParams := params.offset
        }
    }

    /// @dev equivalent to abi.decode(params, (TakeOrderInputParams))
    function decodeTakeOrderInputParams(bytes calldata params)
        internal
        pure
        returns (TakeOrderInputParams calldata takeParams)
    {
        // TakeOrderInputParams is a variable length struct so we just have to look up its location.
        assembly ("memory-safe") {
            // minimum length when path is empty:
            // 0xc0 = 6 * 0x20 -> struct offset, 4 struct head slots, and path length 0
            if lt(params.length, 0xc0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            takeParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to abi.decode(params, (TakeOrderOutputParams))
    function decodeTakeOrderOutputParams(bytes calldata params)
        internal
        pure
        returns (TakeOrderOutputParams calldata takeParams)
    {
        // TakeOrderOutputParams is a variable length struct so we just have to look up its location.
        assembly ("memory-safe") {
            // minimum length when path is empty:
            // 0xc0 = 6 * 0x20 -> struct offset, 4 struct head slots, and path length 0
            if lt(params.length, 0xc0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            takeParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev equivalent to abi.decode(params, (UnibuyPoolKey, int24, int24, uint128, address))
    function decodePlaceMakerParams(bytes calldata params)
        internal
        pure
        returns (
            UnibuyPoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            address recipient
        )
    {
        assembly ("memory-safe") {
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tickLower := calldataload(add(params.offset, 0x60))
            tickUpper := calldataload(add(params.offset, 0x80))
            liquidity := calldataload(add(params.offset, 0xa0))
            recipient := calldataload(add(params.offset, 0xc0))
        }
    }

    /// @dev equivalent to abi.decode(params, (UnibuyPoolKey, int24, int24, uint256, address))
    function decodePlaceOrderWithTakeParams(bytes calldata params)
        internal
        pure
        returns (PlaceOrderWithTakeParams calldata placeParams)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            placeParams := params.offset
        }
    }

    /// @dev equivalent to abi.decode(params, (UnibuyPoolKey, uint256))
    function decodeCloseMakerParams(bytes calldata params)
        internal
        pure
        returns (UnibuyPoolKey calldata key, uint256 tokenId)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x80) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            key := params.offset
            tokenId := calldataload(add(params.offset, 0x60))
        }
    }

    /// @dev equivalent to abi.decode(params, (Currency, uint256, bool))
    function decodeSettleParams(bytes calldata params)
        internal
        pure
        returns (Currency currency, uint256 amount, bool payerIsUser)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
            payerIsUser := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev equivalent to abi.decode(params, (Currency))
    function decodeCurrency(bytes calldata params) internal pure returns (Currency currency) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
        }
    }

    /// @dev equivalent to abi.decode(params, (Currency, address))
    function decodeCurrencyAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency, address recipient)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            recipient := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev equivalent to abi.decode(params, (Currency, address, uint256))
    function decodeTakeParams(bytes calldata params)
        internal
        pure
        returns (Currency currency, address recipient, uint256 amount)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            recipient := calldataload(add(params.offset, 0x20))
            amount := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev equivalent to abi.decode(params, (Currency, Currency))
    function decodeCurrencyPair(bytes calldata params)
        internal
        pure
        returns (Currency currency0, Currency currency1)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev equivalent to abi.decode(params, (Currency, Currency, address))
    function decodeTakePairParams(bytes calldata params)
        internal
        pure
        returns (Currency currency0, Currency currency1, address recipient)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
            recipient := calldataload(add(params.offset, 0x40))
        }
    }
}
