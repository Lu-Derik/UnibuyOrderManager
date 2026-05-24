// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UnibuyPoolKey} from "@unibuy/types/UnibuyPoolKey.sol";

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
///   • Mixed order  — atomic taker then optional maker with both pool keys provided explicitly.
interface IUnibuyOrderManager {

    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Metadata stored for each maker order NFT.
    /// @dev    Packs into a single 32-byte storage slot:
    ///         bytes25 poolId (25) + int24 tickLower (3) + int24 tickUpper (3) + bool active (1).
    struct OrderInfo {
        bytes25 poolId;    // first 25 bytes of keccak256(abi.encode(UnibuyPoolKey))
        int24   tickLower; // in resolved pool terms
        int24   tickUpper; // in resolved pool terms
        bool    active;
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
    error NotTokenOwner(address caller, address owner);
    error OrderNotActive(uint256 tokenId);
    error BuyPriceBelowCurrent(uint160 limitSqrtPrice, uint160 currentSqrtPrice);
    error SellPriceAboveCurrent(uint160 limitSqrtPrice, uint160 currentSqrtPrice);
    error ZeroAmount();
    error InvalidActionType(uint8 action);
    error InputLengthMismatch();
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
    ///
    /// @return amountOut  Actual currency0 delivered to recipient.
    function takeOrderInputSingle(
        UnibuyPoolKey calldata key,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    /// @notice Execute a multi-hop exact-input taker order (path of pools).
    ///
    /// @param path               Ordered array of pool keys; currency0 of path[i] == currency1 of path[i+1].
    /// @param recipient          Address that receives the output token (currency0 of last pool).
    /// @param amountIn           Exact amount of currency1 of path[0] to spend.
    /// @param amountOutMinimum   Minimum amount of currency0 of path[last] to receive.
    /// @param deadline           Block timestamp after which the call reverts.
    ///
    /// @return amountOut  Actual output token delivered to recipient.
    function takeOrderInput(
        UnibuyPoolKey[] calldata path,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external payable returns (uint256 amountOut);

    /// @notice Execute a single-pool exact-output taker order.
    ///
    /// @param key                Resolved pool key to trade against.
    /// @param recipient          Address that receives the output token (currency0).
    /// @param amountOut          Exact amount of currency0 to receive.
    /// @param amountInMaximum    Maximum amount of currency1 to spend (slippage guard).
    /// @param sqrtPriceLimitX96  Price ceiling in sqrt Q64.96 terms; must be >= current price.
    /// @param deadline           Block timestamp after which the call reverts.
    ///
    /// @return amountIn  Actual currency1 spent by msg.sender.
    function takeOrderOutputSingle(
        UnibuyPoolKey calldata key,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external payable returns (uint256 amountIn);

    /// @notice Execute a multi-hop exact-output taker order (path traversed in reverse).
    ///
    /// @param path               Ordered array of pool keys; currency0 of path[i] == currency1 of path[i+1].
    /// @param recipient          Address that receives the output token (currency0 of last pool).
    /// @param amountOut          Exact amount of currency0 of path[last] to receive.
    /// @param amountInMaximum    Maximum amount of currency1 of path[0] to spend.
    /// @param deadline           Block timestamp after which the call reverts.
    ///
    /// @return amountIn  Actual input token spent.
    function takeOrderOutput(
        UnibuyPoolKey[] calldata path,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint256 deadline
    ) external payable returns (uint256 amountIn);

    // ─────────────────────────────────────────────────────────────────────────
    // Maker order
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Place a maker (limit) order on the provided pool key. Mints an ERC-721 NFT.
    ///
    /// @param key        Resolved pool key to place into (forward or mirror).
    /// @param tickLower  Lower tick in the SAME pool key's terms.
    /// @param tickUpper  Upper tick in the SAME pool key's terms.
    /// @param liquidity  Virtual liquidity to provide.
    /// @param deadline   Expiry timestamp.
    ///
    /// @return tokenId      ERC-721 token ID (burned on close).
    /// @return compensation Internal exchange fee pre-deducted from future proceeds.
    function placeOrder(
        UnibuyPoolKey calldata key,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        uint256 deadline
    ) external payable returns (uint256 tokenId, uint96 compensation);

    /// @notice Close (cancel) a maker order and withdraw all proceeds.
    ///         Burns the NFT.  Caller must be current NFT owner.
    ///
    /// @return token0Amount  token0 returned (unfilled deposit or purchased amount).
    /// @return token1Amount  token1 returned (earned or unfilled deposit).
    function closeMakerOrder(
        uint256             tokenId,
        UnibuyPoolKey calldata key,
        uint256             deadline
    ) external returns (uint256 token0Amount, uint256 token1Amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Mixed order
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Atomic taker + optional maker in one transaction.
    ///
    /// @param takerKey            Resolved pool key used for the taker step.
    /// @param takerAmountIn       Input token for the taker step (0 → skip taker).
    /// @param takerPriceLimitX96  Price limit for the taker step in takerKey sqrt terms.
    ///                            Must be >= current. Pass 1 for no limit.
    /// @param makerKey            Resolved pool key used for the maker step.
    /// @param makerTickLower      Lower tick for the maker step in makerKey terms.
    /// @param makerTickUpper      Upper tick for the maker step in makerKey terms.
    /// @param makerLiquidity      Liquidity for the maker step (0 → skip maker).
    /// @param recipient           Receives the output token from the taker step.
    /// @param deadline            Expiry timestamp.
    ///
    /// @return takerAmountSpent   Actual input consumed by the taker step.
    /// @return takerAmountOut     Output delivered to `recipient` from the taker step.
    /// @return makerTokenId       NFT token ID for the maker portion (0 if skipped).
    function mixedOrder(
        UnibuyPoolKey calldata takerKey,
        uint256 takerAmountIn,
        uint160 takerPriceLimitX96,
        UnibuyPoolKey calldata makerKey,
        int24   makerTickLower,
        int24   makerTickUpper,
        uint128 makerLiquidity,
        address recipient,
        uint256 deadline
    ) external returns (
        uint256 takerAmountSpent,
        uint256 takerAmountOut,
        uint256 makerTokenId
    );

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
    /// @return results ABI-encoded return values, one element per action.
    ///                 Order actions return useful data; settlement actions return "".
    function execute(
        bytes calldata actions,
        bytes[] calldata params,
        uint256 deadline
    ) external payable returns (bytes[] memory results);

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    function getMakerOrder(uint256 tokenId)
        external view returns (OrderInfo memory);

    function nextTokenId() external view returns (uint256);
}
