// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {UnibuyPoolKey, UnibuyPoolId, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency, CurrencyLibrary} from "@unibuy/types/Currency.sol";
import {FullMath}           from "@unibuy/libraries/FullMath.sol";
import {FixedPoint96}       from "@unibuy/libraries/FixedPoint96.sol";
import {StateLibrary}       from "@unibuy/libraries/StateLibrary.sol";
import {SafeCast}           from "@unibuy/libraries/SafeCast.sol";
import {TickMath}           from "@unibuy/libraries/TickMath.sol";

import {ERC721Permit_v4}     from "./base/ERC721Permit_v4.sol";
import {Multicall_v4}        from "./base/Multicall_v4.sol";
import {ReentrancyLock}      from "./base/ReentrancyLock.sol";
import {Permit2Forwarder}    from "./base/Permit2Forwarder.sol";
import {NativeWrapper}       from "./base/NativeWrapper.sol";
import {BaseActionsRouter}   from "./base/BaseActionsRouter.sol";
import {IUnibuyOrderManager} from "./interfaces/IUnibuyOrderManager.sol";
import {Actions}             from "./libraries/Actions.sol";
import {PackedOrderInfo, OrderInfoLibrary} from "./libraries/OrderInfoLibrary.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {IAllowanceTransfer}  from "permit2/interfaces/IAllowanceTransfer.sol";
import {IWETH9}             from "./interfaces/external/IWETH9.sol";

/// @title UnibuyOrderManager
/// @notice User-facing order management contract for the UniBuy DEX protocol.
///
///         Order methods accept resolved pool keys directly.
///
///         Maker orders are represented as ERC-721 NFTs.
contract UnibuyOrderManager is
    ERC721Permit_v4,
    Multicall_v4,
    ReentrancyLock,
    BaseActionsRouter,
    Permit2Forwarder,
    NativeWrapper,
    IUnibuyOrderManager
{
    using UnibuyPoolIdLibrary for UnibuyPoolKey;
    using CurrencyLibrary    for Currency;
    using StateLibrary       for IUnibuyPoolManager;
    using SafeCast           for uint256;
    using SafeCast           for int256;
    using OrderInfoLibrary   for PackedOrderInfo;
    using CalldataDecoder    for bytes;

    // ─────────────────────────────────────────────────────────────────────────
    // NFT / Order registry
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    uint256 public nextTokenId = 1;

    /// @dev Packed order metadata for each maker NFT. One 32-byte slot per order.
    mapping(uint256 tokenId => PackedOrderInfo) private _orders;

    /// @notice Full UnibuyPoolKey for each pool, keyed by its truncated bytes25 pool ID.
    ///         Populated on first placeOrder for a given pool (mirrors PositionManager.poolKeys).
    mapping(bytes25 poolId => UnibuyPoolKey) public poolKeys;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _poolManager, IAllowanceTransfer _permit2, IWETH9 _weth9)
        ERC721Permit_v4("Unibuy Orders NFT", "UNB-ORD")
        BaseActionsRouter(IUnibuyPoolManager(_poolManager))
        Permit2Forwarder(_permit2)
        NativeWrapper(_weth9)
    {}

    // ─────────────────────────────────────────────────────────────────────────
    // Deadline modifier
    // ─────────────────────────────────────────────────────────────────────────

    modifier checkDeadline(uint256 deadline) {
        _checkDeadline(deadline);
        _;
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlinePassed();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Taker order
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function takeOrderInputSingle(
        UnibuyPoolKey calldata key,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        (uint160 cur,,,,,, ) = poolManager.getSlot0(key.toId());
        if (sqrtPriceLimitX96 < cur) revert BuyPriceBelowCurrent(sqrtPriceLimitX96, cur);

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_INPUT_SINGLE,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, amountIn, amountOutMinimum, sqrtPriceLimitX96);
        params[1] = abi.encode(key.currency1);             // user pays
        params[2] = abi.encode(key.currency0, recipient);  // user receives

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));
        amountOut = abi.decode(results[0], (uint256));
    }

    /// @inheritdoc IUnibuyOrderManager
    function takeOrderInput(
        UnibuyPoolKey[] calldata path,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        if (path.length == 0) revert ZeroAmount();

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_INPUT,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(path, amountIn, amountOutMinimum);
        params[1] = abi.encode(path[0].currency1);                              // user pays
        params[2] = abi.encode(path[path.length - 1].currency0, recipient);     // user receives

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));
        amountOut = abi.decode(results[0], (uint256));
    }

    /// @inheritdoc IUnibuyOrderManager
    function takeOrderOutputSingle(
        UnibuyPoolKey calldata key,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        (uint160 cur,,,,,, ) = poolManager.getSlot0(key.toId());
        if (sqrtPriceLimitX96 < cur) revert BuyPriceBelowCurrent(sqrtPriceLimitX96, cur);

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_OUTPUT_SINGLE,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, amountOut, amountInMaximum, sqrtPriceLimitX96);
        params[1] = abi.encode(key.currency1);             // user pays
        params[2] = abi.encode(key.currency0, recipient);  // user receives

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));
        amountIn = abi.decode(results[0], (uint256));
    }

    /// @inheritdoc IUnibuyOrderManager
    function takeOrderOutput(
        UnibuyPoolKey[] calldata path,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        if (path.length == 0) revert ZeroAmount();

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_OUTPUT,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(path, amountOut, amountInMaximum);
        params[1] = abi.encode(path[0].currency1);                              // user pays
        params[2] = abi.encode(path[path.length - 1].currency0, recipient);     // user receives

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));
        amountIn = abi.decode(results[0], (uint256));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Maker order
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function placeOrder(
        UnibuyPoolKey calldata key,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 tokenId, uint96 compensation)
    {
        bytes memory actions = abi.encodePacked(Actions.PLACE_MAKER, Actions.SETTLE_ALL);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, msg.sender);
        params[1] = abi.encode(key.currency0);

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));
        (tokenId, compensation) = abi.decode(results[0], (uint256, uint96));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Close Maker Order
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function closeMakerOrder(
        uint256             tokenId,
        UnibuyPoolKey calldata key,
        uint256             deadline
    )
        external
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 token0Amount, uint256 token1Amount)
    {
        // Look up the stored pool key to determine settlement currencies for TAKE_PAIR.
        bytes25 poolId = _orders[tokenId].poolId();
        UnibuyPoolKey memory resolvedPool = poolKeys[poolId];

        bytes memory actions = abi.encodePacked(Actions.CLOSE_MAKER, Actions.TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tokenId);
        params[1] = abi.encode(resolvedPool.currency0, resolvedPool.currency1, msg.sender);

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));
        (token0Amount, token1Amount) = abi.decode(results[0], (uint256, uint256));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Mixed order
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
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
    )
        external
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 takerAmountSpent, uint256 takerAmountOut, uint256 makerTokenId)
    {
        uint160 takerPoolPriceLimit;
        if (takerAmountIn > 0) {
            (uint160 cur,,,,,, ) = poolManager.getSlot0(takerKey.toId());
            if (takerPriceLimitX96 <= 1) {
                takerPoolPriceLimit = TickMath.MAX_SQRT_PRICE;
            } else {
                if (takerPriceLimitX96 < cur) revert BuyPriceBelowCurrent(takerPriceLimitX96, cur);
                takerPoolPriceLimit = takerPriceLimitX96;
            }
        }

        // Build batch actions dynamically based on which steps are active.
        bytes memory actions;
        bytes[] memory params;

        if (takerAmountIn > 0 && makerLiquidity > 0) {
            actions = abi.encodePacked(
                Actions.TAKE_ORDER_INPUT_SINGLE,
                Actions.PLACE_MAKER,
                Actions.SETTLE_ALL,
                Actions.TAKE_ALL
            );
            params = new bytes[](4);
            params[0] = abi.encode(takerKey, takerAmountIn, uint256(0), takerPoolPriceLimit);
            params[1] = abi.encode(makerKey, makerTickLower, makerTickUpper, makerLiquidity, msg.sender);
            params[2] = abi.encode(takerKey.currency1);           // user pays
            params[3] = abi.encode(takerKey.currency0, recipient); // user receives
        } else if (takerAmountIn > 0) {
            actions = abi.encodePacked(
                Actions.TAKE_ORDER_INPUT_SINGLE,
                Actions.SETTLE_ALL,
                Actions.TAKE_ALL
            );
            params = new bytes[](3);
            params[0] = abi.encode(takerKey, takerAmountIn, uint256(0), takerPoolPriceLimit);
            params[1] = abi.encode(takerKey.currency1);           // user pays
            params[2] = abi.encode(takerKey.currency0, recipient); // user receives
        } else {
            // makerLiquidity > 0 only
            actions = abi.encodePacked(Actions.PLACE_MAKER, Actions.SETTLE_ALL);
            params = new bytes[](2);
            params[0] = abi.encode(makerKey, makerTickLower, makerTickUpper, makerLiquidity, msg.sender);
            params[1] = abi.encode(takerKey.currency1);
        }

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));

        if (takerAmountIn > 0) {
            takerAmountOut = abi.decode(results[0], (uint256));
            takerAmountSpent = takerAmountIn; // exact-input: full amount is spent
        }

        if (makerLiquidity > 0) {
            uint256 makerIdx = takerAmountIn > 0 ? 1 : 0;
            (makerTokenId, ) = abi.decode(results[makerIdx], (uint256, uint96));
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Batch execute (primary entry point for advanced / multi-step usage)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function execute(
        bytes calldata actions,
        bytes[] calldata params,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (bytes[] memory results)
    {
        bytes memory raw = _executeActions(abi.encode(actions, params));
        results = abi.decode(raw, (bytes[]));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Unlock callback (SafeCallback pattern)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc BaseActionsRouter
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        uint256 n = actions.length;
        if (n != params.length) revert InputLengthMismatch();
        bytes[] memory results = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            results[i] = _handleAction(uint8(actions[i]), params[i]);
        }
        return abi.encode(results);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Action dispatcher
    // ─────────────────────────────────────────────────────────────────────────

    function _handleAction(uint8 action, bytes calldata params) internal returns (bytes memory) {
        if (action == Actions.TAKE_ORDER_INPUT_SINGLE)  return _handleTakeOrderInputSingle(params);
        if (action == Actions.TAKE_ORDER_INPUT)         return _handleTakeOrderInput(params);
        if (action == Actions.TAKE_ORDER_OUTPUT_SINGLE) return _handleTakeOrderOutputSingle(params);
        if (action == Actions.TAKE_ORDER_OUTPUT)        return _handleTakeOrderOutput(params);
        if (action == Actions.PLACE_MAKER)              return _handleMaker(params);
        if (action == Actions.CLOSE_MAKER)              return _handleClose(params);
        if (action == Actions.SETTLE)                   return _handleSettle(params);
        if (action == Actions.SETTLE_ALL)               return _handleSettleAll(params);
        if (action == Actions.TAKE)                     return _handleTake(params);
        if (action == Actions.TAKE_ALL)                 return _handleTakeAll(params);
        if (action == Actions.SETTLE_PAIR)              return _handleSettlePair(params);
        if (action == Actions.TAKE_PAIR)                return _handleTakePair(params);
        revert InvalidActionType(action);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Order action handlers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Executes a single-pool exact-input taker swap.
    /// @param params abi.encode(UnibuyPoolKey poolKey, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)
    /// @return abi.encode(uint256 amountOut)
    function _handleTakeOrderInputSingle(bytes calldata params) internal returns (bytes memory) {
        (UnibuyPoolKey calldata poolKey, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96) =
            params.decodeTakeOrderInputSingleParams();

        if (amountIn == 0) revert ZeroAmount();

        (int128 delta0, int128 delta1) =
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.takeOrder(poolKey, -int256(amountIn), sqrtPriceLimitX96);

        // delta0 > 0  -> pool owes currency0 to this contract (user output)
        // delta1 < 0  -> this contract owes currency1 to pool (user input)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outAmount = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 inAmount = delta1 < 0 ? uint256(uint128(-delta1)) : 0;

        if (outAmount < amountOutMinimum) revert TooLittleReceived(amountOutMinimum, outAmount);

        emit TakerOrderExecuted(_getLocker(), UnibuyPoolId.unwrap(poolKey.toId()), inAmount, outAmount, 0);
        return abi.encode(outAmount);
    }

    /// @dev Executes a multi-hop exact-input taker swap.
    /// @param params abi.encode(UnibuyPoolKey[] path, uint256 amountIn, uint256 amountOutMinimum)
    /// @return abi.encode(uint256 amountOut)
    function _handleTakeOrderInput(bytes calldata params) internal returns (bytes memory) {
        (UnibuyPoolKey[] memory path, uint256 amountIn, uint256 amountOutMinimum) =
            abi.decode(params, (UnibuyPoolKey[], uint256, uint256));

        if (amountIn == 0) revert ZeroAmount();
        if (path.length == 0) revert ZeroAmount();

        uint256 currentAmount = amountIn;
        for (uint256 i = 0; i < path.length; i++) {
            (int128 delta0, int128 delta1) =
                // forge-lint: disable-next-line(unsafe-typecast)
                poolManager.takeOrder(path[i], -int256(currentAmount), TickMath.MAX_SQRT_PRICE);
            // forge-lint: disable-next-line(unsafe-typecast)
            currentAmount = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        }

        if (currentAmount < amountOutMinimum) revert TooLittleReceived(amountOutMinimum, currentAmount);

        emit TakerOrderExecuted(_getLocker(), UnibuyPoolId.unwrap(path[0].toId()), amountIn, currentAmount, 0);
        return abi.encode(currentAmount);
    }

    /// @dev Executes a single-pool exact-output taker swap.
    /// @param params abi.encode(UnibuyPoolKey poolKey, uint256 amountOut, uint256 amountInMaximum, uint160 sqrtPriceLimitX96)
    /// @return abi.encode(uint256 amountIn)
    function _handleTakeOrderOutputSingle(bytes calldata params) internal returns (bytes memory) {
        (UnibuyPoolKey calldata poolKey, uint256 amountOut, uint256 amountInMaximum, uint160 sqrtPriceLimitX96) =
            params.decodeTakeOrderOutputSingleParams();

        if (amountOut == 0) revert ZeroAmount();

        (int128 delta0, int128 delta1) =
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.takeOrder(poolKey, int256(amountOut), sqrtPriceLimitX96);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outAmount = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 inAmount  = delta1 < 0 ? uint256(uint128(-delta1)) : 0;

        if (inAmount > amountInMaximum) revert TooMuchRequested(amountInMaximum, inAmount);

        emit TakerOrderExecuted(_getLocker(), UnibuyPoolId.unwrap(poolKey.toId()), inAmount, outAmount, 0);
        return abi.encode(inAmount);
    }

    /// @dev Executes a multi-hop exact-output taker swap (reversed path traversal).
    /// @param params abi.encode(UnibuyPoolKey[] path, uint256 amountOut, uint256 amountInMaximum)
    /// @return abi.encode(uint256 amountIn)
    function _handleTakeOrderOutput(bytes calldata params) internal returns (bytes memory) {
        (UnibuyPoolKey[] memory path, uint256 amountOut, uint256 amountInMaximum) =
            abi.decode(params, (UnibuyPoolKey[], uint256, uint256));

        if (amountOut == 0) revert ZeroAmount();
        if (path.length == 0) revert ZeroAmount();

        // Traverse in reverse to compute required input for exact output
        uint256 currentAmount = amountOut;
        for (uint256 i = path.length; i > 0; ) {
            unchecked { --i; }
            (int128 delta0, int128 delta1) =
                // forge-lint: disable-next-line(unsafe-typecast)
                poolManager.takeOrder(path[i], int256(currentAmount), TickMath.MAX_SQRT_PRICE);
            // forge-lint: disable-next-line(unsafe-typecast)
            currentAmount = delta1 < 0 ? uint256(uint128(-delta1)) : 0;
        }

        if (currentAmount > amountInMaximum) revert TooMuchRequested(amountInMaximum, currentAmount);

        emit TakerOrderExecuted(_getLocker(), UnibuyPoolId.unwrap(path[0].toId()), currentAmount, amountOut, 0);
        return abi.encode(currentAmount);
    }

    /// @dev Places a maker limit order. The resolved pool key and pool-term ticks are
    ///      pre-computed by the calling wrapper. Populates poolKeys on first use.
    ///      Delta is left for SETTLE_ALL.
    /// @param params abi.encode(UnibuyPoolKey poolKey, int24 tickLower, int24 tickUpper,
    ///                          uint128 liquidity, address recipient)
    ///              poolKey: already the resolved pool (wrapper handles forward/mirror selection)
    ///              ticks: already in resolved-pool terms (wrapper provides resolved values)
    /// @return abi.encode(uint256 tokenId, uint96 compensation)
    function _handleMaker(bytes calldata params) internal returns (bytes memory) {
        (
            UnibuyPoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            address recipient
        ) = params.decodePlaceMakerParams();

        uint256 tokenId = nextTokenId++;
        (, uint96 compensation) =
            poolManager.placeOrder(poolKey, tickLower, tickUpper, liquidity, bytes32(tokenId));

        // Mint the NFT to the recipient and record the order
        _mint(recipient, tokenId);

        bytes25 poolId = bytes25(UnibuyPoolId.unwrap(poolKey.toId()));
        // Store the full pool key on first sight (like PositionManager.poolKeys)
        if (poolKeys[poolId].tickSpacing == 0) {
            poolKeys[poolId] = poolKey;
        }

        _orders[tokenId] = OrderInfoLibrary.initialize(poolId, tickLower, tickUpper);

        emit MakerOrderPlaced(
            _getLocker(),
            UnibuyPoolId.unwrap(poolKey.toId()),
            tokenId,
            tickLower,
            tickUpper,
            compensation
        );

        // Deposit delta accumulates; SETTLE_ALL handles payment.
        return abi.encode(tokenId, compensation);
    }

    /// @dev Closes a maker order. Contains all business logic (auth check, storage lookup/update,
    ///      pool call, NFT burn, event). Credits are left for TAKE_PAIR.
    ///      Direction (buy vs sell) is derived by comparing ord.poolId to key.toId().
    /// @param params abi.encode(UnibuyPoolKey key, uint256 tokenId)
    ///              key is the FORWARD pool key; used to derive order direction.
    /// @return abi.encode(uint256 token0Amount, uint256 token1Amount)
    function _handleClose(bytes calldata params) internal returns (bytes memory) {
        (UnibuyPoolKey calldata key, uint256 tid) = params.decodeCloseMakerParams();

        address caller = _getLocker();
        address tokenOwner = ownerOf(tid);
        if (!_isApprovedOrOwner(caller, tid)) revert NotTokenOwner(caller, tokenOwner);

        PackedOrderInfo orderInfo = _orders[tid];
        if (!orderInfo.active()) revert OrderNotActive(tid);

        // Derive direction: stored poolId != forward pool Id → mirror-pool order.
        bool isMirrorOrder = (orderInfo.poolId() != bytes25(UnibuyPoolId.unwrap(key.toId())));
        int24 tickLower = orderInfo.tickLower();
        int24 tickUpper = orderInfo.tickUpper();

        UnibuyPoolKey memory poolKey = isMirrorOrder ? key.mirrorKey() : key;
        (int128 delta0, int128 delta1) =
            poolManager.closeOrder(poolKey, tickLower, tickUpper, bytes32(tid));

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 d0 = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 d1 = delta1 > 0 ? uint256(uint128(delta1)) : 0;

        // Map pool deltas → forward token0 / token1 for the return value.
        // Credits accumulate; TAKE_PAIR handles the actual transfer.
        uint256 token0Amount;
        uint256 token1Amount;
        if (isMirrorOrder) {
            // Mirror pool: currency0 = fwd token1, currency1 = fwd token0
            token1Amount = d0;
            token0Amount = d1;
        } else {
            // Forward pool: currency0 = token0, currency1 = token1
            token0Amount = d0;
            token1Amount = d1;
        }

        _orders[tid] = orderInfo.setInactive();
        _burn(tid);

        emit MakerOrderClosed(caller, tid, token0Amount, token1Amount);
        return abi.encode(token0Amount, token1Amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Settlement action handlers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Settle an explicit amount.
    /// @param params abi.encode(Currency currency, uint256 amount, bool payerIsUser)
    function _handleSettle(bytes calldata params) internal returns (bytes memory) {
        (Currency currency, uint256 amount, bool payerIsUser) = params.decodeSettleParams();
        address payer = payerIsUser ? _getLocker() : address(this);
        _settle(currency, payer, amount);
        return "";
    }

    /// @dev Settle the full outstanding debt for a currency.
    /// @param params abi.encode(Currency currency)
    function _handleSettleAll(bytes calldata params) internal returns (bytes memory) {
        Currency currency = params.decodeCurrency();
        uint256 amount = _getFullDebt(currency);
        _settle(currency, _getLocker(), amount);
        return "";
    }

    /// @dev Transfer an explicit amount of a currency out.
    /// @param params abi.encode(Currency currency, address recipient, uint256 amount)
    function _handleTake(bytes calldata params) internal returns (bytes memory) {
        (Currency currency, address recipient, uint256 amount) = params.decodeTakeParams();
        _take(currency, recipient, amount);
        return "";
    }

    /// @dev Transfer the full credit of a currency to a recipient.
    /// @param params abi.encode(Currency currency, address recipient)
    function _handleTakeAll(bytes calldata params) internal returns (bytes memory) {
        (Currency currency, address recipient) = params.decodeCurrencyAddress();
        uint256 amount = _getFullCredit(currency);
        _take(currency, recipient, amount);
        return "";
    }

    /// @dev Settle the full debt for both currencies in a pair.
    /// @param params abi.encode(Currency currency0, Currency currency1)
    function _handleSettlePair(bytes calldata params) internal returns (bytes memory) {
        (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
        address payer = _getLocker();
        _settle(currency0, payer, _getFullDebt(currency0));
        _settle(currency1, payer, _getFullDebt(currency1));
        return "";
    }

    /// @dev Transfer the full credit for both currencies in a pair to a recipient.
    /// @param params abi.encode(Currency currency0, Currency currency1, address recipient)
    function _handleTakePair(bytes calldata params) internal returns (bytes memory) {
        (Currency currency0, Currency currency1, address recipient) = params.decodeTakePairParams();
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
        return "";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC721 tokenURI implementation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the token URI for a given token ID
    function tokenURI(uint256 /*id*/) public pure override returns (string memory) {
        return "";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function getMakerOrder(uint256 tokenId)
        external view returns (IUnibuyOrderManager.OrderInfo memory)
    {
        return _orders[tokenId].toOrderInfo();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _toMirrorSqrt(uint160 sqrtFwdX96) internal pure returns (uint160) {
        return uint160(FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, sqrtFwdX96));
    }
}
