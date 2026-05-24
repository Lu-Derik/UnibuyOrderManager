// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Actions
/// @notice Action constants for UnibuyOrderManager batch execution.
///
/// Usage:
///   Build an `actions` bytes array (one byte per action) and a `params` bytes[]
///   array (one ABI-encoded element per action), then call `execute(actions, params, deadline)`.
///
/// Example — exact-input single-pool taker order then settle:
///   bytes memory actions = abi.encodePacked(
///       Actions.TAKE_ORDER_INPUT_SINGLE,
///       Actions.SETTLE_ALL,
///       Actions.TAKE_ALL
///   );
library Actions {
    // ── Order actions ─────────────────────────────────────────────────────────

    /// @notice Execute a single-pool exact-input taker swap.
    /// @dev params: abi.encode(UnibuyPoolKey poolKey, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)
    ///   Returns: abi.encode(uint256 actualAmountIn, uint256 actualAmountOut, uint256 fee)
    uint8 internal constant TAKE_ORDER_INPUT_SINGLE  = 0x01;

    /// @notice Execute a multi-hop exact-input taker swap (path of pools).
    /// @dev params: abi.encode(UnibuyPoolKey[] path, uint256 amountIn, uint256 amountOutMinimum)
    ///   Returns: abi.encode(uint256 amountOut)
    uint8 internal constant TAKE_ORDER_INPUT         = 0x02;

    /// @notice Execute a single-pool exact-output taker swap.
    /// @dev params: abi.encode(UnibuyPoolKey poolKey, uint256 amountOut, uint256 amountInMaximum, uint160 sqrtPriceLimitX96)
    ///   Returns: abi.encode(uint256 amountIn)
    uint8 internal constant TAKE_ORDER_OUTPUT_SINGLE = 0x03;

    /// @notice Execute a multi-hop exact-output taker swap (path of pools, reversed traversal).
    /// @dev params: abi.encode(UnibuyPoolKey[] path, uint256 amountOut, uint256 amountInMaximum)
    ///   Returns: abi.encode(uint256 amountIn)
    uint8 internal constant TAKE_ORDER_OUTPUT        = 0x04;

    /// @notice Place a maker (limit) order and mint an NFT.
    /// @dev params: abi.encode(UnibuyPoolKey poolKey, int24 tickLower, int24 tickUpper, uint128 liquidity, address recipient)
    ///   Returns: abi.encode(uint256 tokenId, uint96 compensation)
    uint8 internal constant PLACE_MAKER = 0x05;

    /// @notice Cancel / close an existing maker order and receive proceeds.
    /// @dev params: abi.encode(UnibuyPoolKey key, uint256 tokenId)
    ///   Returns: abi.encode(uint256 token0Amount, uint256 token1Amount)
    uint8 internal constant CLOSE_MAKER = 0x06;

    // ── Settlement actions ────────────────────────────────────────────────────

    /// @notice Settle an explicit amount of a single currency.
    /// @dev params: abi.encode(Currency currency, uint256 amount, bool payerIsUser)
    ///   payerIsUser = true  → payer is the original tx sender (_getLocker()).
    ///   payerIsUser = false → payer is address(this) (contract holds tokens).
    ///   Returns: ""
    uint8 internal constant SETTLE     = 0x10;

    /// @notice Settle the full outstanding debt for a single currency.
    /// @dev params: abi.encode(Currency currency)
    ///   Payer is always the original tx sender (_getLocker()).
    ///   Returns: ""
    uint8 internal constant SETTLE_ALL = 0x11;

    /// @notice Transfer an explicit amount of a single currency out to a recipient.
    /// @dev params: abi.encode(Currency currency, address recipient, uint256 amount)
    ///   Returns: ""
    uint8 internal constant TAKE       = 0x12;

    /// @notice Transfer the full outstanding credit for a single currency to a recipient.
    /// @dev params: abi.encode(Currency currency, address recipient)
    ///   Returns: ""
    uint8 internal constant TAKE_ALL   = 0x13;

    /// @notice Settle the full debt for both currencies in a pair.
    /// @dev params: abi.encode(Currency currency0, Currency currency1)
    ///   Payer is always the original tx sender (_getLocker()).
    ///   Returns: ""
    uint8 internal constant SETTLE_PAIR = 0x14;

    /// @notice Transfer the full credit for both currencies in a pair to a recipient.
    /// @dev params: abi.encode(Currency currency0, Currency currency1, address recipient)
    ///   Returns: ""
    uint8 internal constant TAKE_PAIR  = 0x15;
}
