// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UnibuyPoolKey} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency} from "@unibuy/types/Currency.sol";
import {PathKey} from "../libraries/PathKey.sol";

/// @title IUnibuyOrderManager
/// @notice User-facing interface for the UniBuy order management contract.
///
/// Terminology (from user perspective for a token pair A / B):
///   • "token0" = currency0 of the forward pool key (the token makers deposit / takers receive).
///   • "token1" = currency1 of the forward pool key (the token takers pay    / makers receive).
///
/// Tick and price parameters are expressed in the SAME pool-key terms passed to each method.
/// Callers choose forward or mirror keys explicitly.
///
/// Order types:
///   • Taker order  — immediate swap on the provided pool key.
///   • Maker order  — passive limit order on the provided pool key, represented as ERC-721 NFT.
interface IUnibuyOrderManager {

    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Metadata stored for each maker order NFT.
    /// @dev    Packs into a single 32-byte storage slot:
    ///         flags uint8 (1, bit0: chained, bit1: auto) + int24 tickLower (3) + int24 tickUpper (3)
    ///         + int24 tickLowerMirror (3) + int24 tickUpperMirror (3) + bytes19 poolId (19).
    struct OrderInfo {
        bytes19 poolId;    // first 19 bytes of keccak256(abi.encode(UnibuyPoolKey))
        int24   tickLower; // in resolved pool terms
        int24   tickUpper; // in resolved pool terms
        int24   tickLowerMirror; // corresponding mirror-pool lower tick
        int24   tickUpperMirror; // corresponding mirror-pool upper tick
        bool    chained;
        bool    autoClose;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event TakerOrderExecuted(
        address indexed user,
        bytes32 indexed poolId,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );

    event MakerOrderPlaced(
        address indexed maker,
        bytes32 indexed poolId,
        uint256 indexed tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint96 compensation
    );

    event MakerOrderClosed(
        address indexed owner,
        uint256 indexed tokenId,
        uint256 token0Amount,
        uint256 token1Amount
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error DeadlinePassed();
    error NotOwnerNorApproved(address caller, address owner);
    error OrderNotActive(uint256 tokenId);
    error BuyPriceBelowCurrent(uint160 limitSqrtPrice, uint160 currentSqrtPrice);
    error SellPriceAboveCurrent(uint160 limitSqrtPrice, uint160 currentSqrtPrice);
    error ZeroAmount();
    error InvalidPath();
    error InvalidActionType(uint8 action);
    error TooLittleReceived(uint256 minAmountOut, uint256 actualAmountOut);
    error TooMuchRequested(uint256 maxAmountIn, uint256 actualAmountIn);

    // ─────────────────────────────────────────────────────────────────────────
    // Taker order
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Execute a single-pool exact-input taker order.
    ///
    /// @param key                Resolved pool key to trade against.
    /// @param recipient          Address that receives the output token (currency0).
    /// @param amountIn           Exact amount of currency1 to spend.
    /// @param amountOutMinimum   Minimum amount of currency0 to receive (slippage guard).
    /// @param sqrtPriceLimitX96  Price ceiling in sqrt Q64.96 terms; must be >= current price.
    /// @param deadline           Block timestamp after which the call reverts.
    function takeOrderInputSingle(
        UnibuyPoolKey calldata key,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external payable;

    /// @notice Execute an exact-input taker order with a first pool and optional follow-up hops.
    ///
    /// @param currencyIn         Input currency for the first hop.
    /// @param path               Forward-ordered hop outputs. Each entry defines the next output currency and tick spacing.
    /// @param recipient          Address that receives the final output token.
    /// @param amountIn           Exact amount of input token to spend.
    /// @param amountOutMinimum   Minimum final output amount to receive.
    /// @param deadline           Block timestamp after which the call reverts.
    function takeOrderInput(
        Currency currencyIn,
        PathKey[] calldata path,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external payable;

    /// @notice Execute a single-pool exact-output taker order.
    ///
    /// @param key                Resolved pool key to trade against.
    /// @param recipient          Address that receives the output token (currency0).
    /// @param amountOut          Exact amount of currency0 to receive.
    /// @param amountInMaximum    Maximum amount of currency1 to spend (slippage guard).
    /// @param sqrtPriceLimitX96  Price ceiling in sqrt Q64.96 terms; must be >= current price.
    /// @param deadline           Block timestamp after which the call reverts.
    function takeOrderOutputSingle(
        UnibuyPoolKey calldata key,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external payable;

    /// @notice Execute an exact-output taker order with a first pool and optional follow-up hops.
    ///
    /// @param currencyOut        Output currency for the final hop.
    /// @param path               Reverse-ordered hop outputs. Each entry defines the next output currency and tick spacing.
    /// @param recipient          Address that receives the final output token.
    /// @param amountOut          Exact final output amount to receive.
    /// @param amountInMaximum    Maximum input amount to spend.
    /// @param deadline           Block timestamp after which the call reverts.
    function takeOrderOutput(
        Currency currencyOut,
        PathKey[] calldata path,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint256 deadline
    ) external payable;

    // ─────────────────────────────────────────────────────────────────────────
    // Maker order
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Place a maker (limit) order on the provided pool key. Mints an ERC-721 NFT.
    ///
    /// @param key        Resolved pool key to place into (forward or mirror).
    /// @param orderInfo  Packed order metadata in OrderInfoLibrary layout (poolId ignored on input).
    ///                   Encodes tickLower/tickUpper/tickLowerMirror/tickUpperMirror/chained/auto.
    /// @param liquidity  Virtual liquidity to provide.
    /// @param deadline   Expiry timestamp.
    ///
    function placeOrderNoTake(
        UnibuyPoolKey calldata key,
        uint256 orderInfo,
        uint128 liquidity,
        uint256 deadline
    ) external payable;

    /// @notice Place maker order using a token0 budget; optionally consumes part of it via mirror take first.
    ///
    /// @param key        Resolved pool key to place into.
    /// @param orderInfo  Packed order metadata in OrderInfoLibrary layout (poolId ignored on input).
    ///                   Encodes tickLower/tickUpper/tickLowerMirror/tickUpperMirror/chained/auto.
    /// @param amount0    Total token0 budget provided by user.
    /// @param deadline   Expiry timestamp.
    function placeOrderWithTake(
        UnibuyPoolKey calldata key,
        uint256 orderInfo,
        uint256 amount0,
        uint256 deadline
    ) external payable;

    /// @notice Close (cancel) a maker order and withdraw all proceeds.
    ///         Burns the NFT.  Caller must be current NFT owner.
    ///
    function closeOrder(
        uint256 tokenId,
        uint256 deadline
    ) external;

    // ─────────────────────────────────────────────────────────────────────────
    // Batch execute
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Execute an arbitrary sequence of order and settlement actions atomically.
    ///
    /// @dev  `actions` is a packed bytes array — one byte per action (see `Actions` library).
    ///       `params[i]` is the ABI-encoded parameters for `actions[i]`.
    ///       All deltas must be zero when this function returns (enforced by pool manager).
    ///
    /// Example — two tandem taker orders:
    ///   bytes memory actions = abi.encodePacked(
    ///       Actions.TAKER_ORDER,   // swap 1
    ///       Actions.TAKER_ORDER,   // swap 2
    ///       Actions.SETTLE_ALL,    // settle combined input debt
    ///       Actions.TAKE_ALL       // receive combined output
    ///   );
    ///
    /// @param actions  Packed action bytes (one byte per action).
    /// @param params   ABI-encoded parameters, one element per action.
    /// @param deadline Block timestamp after which the call reverts.
    function execute(
        bytes calldata actions,
        bytes[] calldata params,
        uint256 deadline
    ) external payable;

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    function getMakerOrder(uint256 tokenId)
        external view returns (OrderInfo memory);

    function lastTokenId() external view returns (uint256);
}
