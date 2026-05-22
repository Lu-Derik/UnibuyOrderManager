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

    // ─────────────────────────────────────────────────────────────────────────
    // NFT / Order registry
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    uint256 public nextTokenId = 1;

    /// @dev Order metadata for each maker NFT. Packs into one 32-byte slot.
    mapping(uint256 tokenId => IUnibuyOrderManager.OrderInfo) private _orders;

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
    function takeOrder(
        UnibuyPoolKey calldata key,
        bool    exactInput,
        uint256 amount,
        uint160 sqrtPriceLimitX96,
        address recipient,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (uint256 amountIn, uint256 amountOut, uint256 fee)
    {
        // Execute against the provided pool key directly.
        UnibuyPoolKey memory resolvedPool = key;
        (uint160 cur,,,,,, ) = poolManager.getSlot0(key.toId());
        if (sqrtPriceLimitX96 < cur) revert BuyPriceBelowCurrent(sqrtPriceLimitX96, cur);
        uint160 poolPriceLimit = sqrtPriceLimitX96;
        Currency inputCurrency  = resolvedPool.currencyOut; // user pays
        Currency outputCurrency = resolvedPool.currencyIn;  // user receives

        bytes memory actions = abi.encodePacked(
            Actions.TAKER_ORDER,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(resolvedPool, exactInput, amount, poolPriceLimit);
        params[1] = abi.encode(inputCurrency);
        params[2] = abi.encode(outputCurrency, recipient);

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));
        (amountIn, amountOut, fee) = abi.decode(results[0], (uint256, uint256, uint256));
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
        // Place maker directly on the provided pool key/ticks.
        UnibuyPoolKey memory resolvedPool = key;
        int24 poolTl = tickLower;
        int24 poolTu = tickUpper;
        Currency depositCurrency = resolvedPool.currencyIn;

        bytes memory actions = abi.encodePacked(Actions.PLACE_MAKER, Actions.SETTLE_ALL);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(resolvedPool, poolTl, poolTu, liquidity, msg.sender);
        params[1] = abi.encode(depositCurrency);

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
        bytes25 ordPoolId = _orders[tokenId].poolId;
        UnibuyPoolKey memory resolvedPool = poolKeys[ordPoolId];

        bytes memory actions = abi.encodePacked(Actions.CLOSE_MAKER, Actions.TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tokenId);
        params[1] = abi.encode(resolvedPool.currencyIn, resolvedPool.currencyOut, msg.sender);

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
        UnibuyPoolKey memory takerPool = takerKey;
        uint160 takerPoolPriceLimit;
        if (takerAmountIn > 0) {
            (uint160 cur,,,,,, ) = poolManager.getSlot0(takerPool.toId());
            if (takerPriceLimitX96 <= 1) {
                takerPoolPriceLimit = TickMath.MAX_SQRT_PRICE;
            } else {
                if (takerPriceLimitX96 < cur) revert BuyPriceBelowCurrent(takerPriceLimitX96, cur);
                takerPoolPriceLimit = takerPriceLimitX96;
            }
        }

        UnibuyPoolKey memory makerPool = makerKey;
        int24 makerPoolTl = makerTickLower;
        int24 makerPoolTu = makerTickUpper;

        Currency inputCurrency  = takerPool.currencyOut; // user pays (taker spend + maker deposit)
        Currency outputCurrency = takerPool.currencyIn;  // user receives (taker output)

        // Build batch actions dynamically based on which steps are active.
        bytes memory actions;
        bytes[] memory params;

        if (takerAmountIn > 0 && makerLiquidity > 0) {
            actions = abi.encodePacked(
                Actions.TAKER_ORDER,
                Actions.PLACE_MAKER,
                Actions.SETTLE_ALL,
                Actions.TAKE_ALL
            );
            params = new bytes[](4);
            params[0] = abi.encode(takerPool, true, takerAmountIn, takerPoolPriceLimit);
            params[1] = abi.encode(makerPool, makerPoolTl, makerPoolTu, makerLiquidity, msg.sender);
            params[2] = abi.encode(inputCurrency);
            params[3] = abi.encode(outputCurrency, recipient);
        } else if (takerAmountIn > 0) {
            actions = abi.encodePacked(
                Actions.TAKER_ORDER,
                Actions.SETTLE_ALL,
                Actions.TAKE_ALL
            );
            params = new bytes[](3);
            params[0] = abi.encode(takerPool, true, takerAmountIn, takerPoolPriceLimit);
            params[1] = abi.encode(inputCurrency);
            params[2] = abi.encode(outputCurrency, recipient);
        } else {
            // makerLiquidity > 0 only
            actions = abi.encodePacked(Actions.PLACE_MAKER, Actions.SETTLE_ALL);
            params = new bytes[](2);
            params[0] = abi.encode(makerPool, makerPoolTl, makerPoolTu, makerLiquidity, msg.sender);
            params[1] = abi.encode(inputCurrency);
        }

        bytes memory raw = _executeActions(abi.encode(actions, params));
        bytes[] memory results = abi.decode(raw, (bytes[]));

        if (takerAmountIn > 0) {
            (takerAmountSpent, takerAmountOut, ) = abi.decode(results[0], (uint256, uint256, uint256));
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
        (bytes memory actions, bytes[] memory params) = abi.decode(data, (bytes, bytes[]));
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

    function _handleAction(uint8 action, bytes memory params) internal returns (bytes memory) {
        if (action == Actions.TAKER_ORDER)  return _handleTaker(params);
        if (action == Actions.PLACE_MAKER)  return _handleMaker(params);
        if (action == Actions.CLOSE_MAKER)  return _handleClose(params);
        if (action == Actions.SETTLE)       return _handleSettle(params);
        if (action == Actions.SETTLE_ALL)   return _handleSettleAll(params);
        if (action == Actions.TAKE)         return _handleTake(params);
        if (action == Actions.TAKE_ALL)     return _handleTakeAll(params);
        if (action == Actions.SETTLE_PAIR)  return _handleSettlePair(params);
        if (action == Actions.TAKE_PAIR)    return _handleTakePair(params);
        revert InvalidActionType(action);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Order action handlers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Executes a taker swap. The resolved pool key and price limit are pre-computed
    ///      by the calling wrapper. Deltas are left for downstream settlement actions.
    /// @param params abi.encode(UnibuyPoolKey poolKey, bool exactInput, uint256 amount,
    ///                          uint160 poolPriceLimit)
    ///              poolKey: resolved pool (forward for buy, mirror for sell)
    ///              poolPriceLimit: already in resolved-pool terms (wrapper converts for sell)
    /// @return abi.encode(uint256 amountIn, uint256 amountOut, uint256 fee)
    function _handleTaker(bytes memory params) internal returns (bytes memory) {
        (UnibuyPoolKey memory poolKey, bool exactInput, uint256 amount, uint160 poolPriceLimit) =
            abi.decode(params, (UnibuyPoolKey, bool, uint256, uint160));

        if (amount == 0) revert ZeroAmount();

        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amtSpec = exactInput ? -int256(amount) : int256(amount);

        (int128 delta0, int128 delta1, uint256 fee) =
            poolManager.takeOrder(poolKey, amtSpec, poolPriceLimit);

        // delta0 > 0  →  pool owes currencyIn to this contract (user output)
        // delta1 < 0  →  this contract owes currencyOut to pool (user input)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outAmount = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 inAmount  = delta1 < 0 ? uint256(uint128(-delta1)) : 0;

        emit TakerOrderExecuted(
            _getLocker(),
            UnibuyPoolId.unwrap(poolKey.toId()),
            inAmount,
            outAmount,
            fee
        );

        // Deltas accumulate in the pool manager; explicit settlement actions handle them.
        return abi.encode(inAmount, outAmount, fee);
    }

    /// @dev Places a maker limit order. The resolved pool key and pool-term ticks are
    ///      pre-computed by the calling wrapper. Populates poolKeys on first use.
    ///      Delta is left for SETTLE_ALL.
    /// @param params abi.encode(UnibuyPoolKey poolKey, int24 tl, int24 tu,
    ///                          uint128 liquidity, address recipient)
    ///              poolKey: already the resolved pool (wrapper handles forward/mirror selection)
    ///              tl/tu: already in resolved-pool terms (wrapper negates for buy orders)
    /// @return abi.encode(uint256 tokenId, uint96 compensation)
    function _handleMaker(bytes memory params) internal returns (bytes memory) {
        (UnibuyPoolKey memory poolKey, int24 tl, int24 tu, uint128 liq, address recipient) =
            abi.decode(params, (UnibuyPoolKey, int24, int24, uint128, address));

        uint256 tokenId = nextTokenId++;
        (, uint96 comp) = poolManager.placeOrder(poolKey, tl, tu, liq, bytes32(tokenId));

        // Mint the NFT to the recipient and record the order
        _mint(recipient, tokenId);

        bytes25 pid = bytes25(UnibuyPoolId.unwrap(poolKey.toId()));
        // Store the full pool key on first sight (like PositionManager.poolKeys)
        if (poolKeys[pid].tickSpacing == 0) {
            poolKeys[pid] = poolKey;
        }

        _orders[tokenId] = IUnibuyOrderManager.OrderInfo({
            poolId:    pid,
            tickLower: tl,
            tickUpper: tu,
            active:    true
        });

        emit MakerOrderPlaced(
            _getLocker(),
            UnibuyPoolId.unwrap(poolKey.toId()),
            tokenId,
            tl,
            tu,
            comp
        );

        // Deposit delta accumulates; SETTLE_ALL handles payment.
        return abi.encode(tokenId, comp);
    }

    /// @dev Closes a maker order. Contains all business logic (auth check, storage lookup/update,
    ///      pool call, NFT burn, event). Credits are left for TAKE_PAIR.
    ///      Direction (buy vs sell) is derived by comparing ord.poolId to key.toId().
    /// @param params abi.encode(UnibuyPoolKey key, uint256 tokenId)
    ///              key is the FORWARD pool key; used to derive order direction.
    /// @return abi.encode(uint256 token0Amount, uint256 token1Amount)
    function _handleClose(bytes memory params) internal returns (bytes memory) {
        (UnibuyPoolKey memory key, uint256 tid) =
            abi.decode(params, (UnibuyPoolKey, uint256));

        address caller = _getLocker();
        address tokenOwner = ownerOf(tid);
        if (!_isApprovedOrOwner(caller, tid)) revert NotTokenOwner(caller, tokenOwner);

        IUnibuyOrderManager.OrderInfo storage ord = _orders[tid];
        if (!ord.active) revert OrderNotActive(tid);

        // Derive direction: stored poolId != forward pool Id → mirror-pool order.
        bool isMirrorOrder = (ord.poolId != bytes25(UnibuyPoolId.unwrap(key.toId())));
        int24 tl   = ord.tickLower;
        int24 tu   = ord.tickUpper;

        UnibuyPoolKey memory poolKey = isMirrorOrder ? key.mirrorKey() : key;
        (int128 delta0, int128 delta1) =
            poolManager.closeOrder(poolKey, tl, tu, bytes32(tid));

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 d0 = delta0 > 0 ? uint256(uint128(delta0)) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 d1 = delta1 > 0 ? uint256(uint128(delta1)) : 0;

        // Map pool deltas → forward token0 / token1 for the return value.
        // Credits accumulate; TAKE_PAIR handles the actual transfer.
        uint256 token0Amount;
        uint256 token1Amount;
        if (isMirrorOrder) {
            // Mirror pool: currencyIn = fwd token1, currencyOut = fwd token0
            token1Amount = d0;
            token0Amount = d1;
        } else {
            // Forward pool: currencyIn = token0, currencyOut = token1
            token0Amount = d0;
            token1Amount = d1;
        }

        ord.active = false;
        _burn(tid);

        emit MakerOrderClosed(caller, tid, token0Amount, token1Amount);
        return abi.encode(token0Amount, token1Amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Settlement action handlers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Settle an explicit amount.
    /// @param params abi.encode(Currency currency, uint256 amount, bool payerIsUser)
    function _handleSettle(bytes memory params) internal returns (bytes memory) {
        (Currency currency, uint256 amount, bool payerIsUser) =
            abi.decode(params, (Currency, uint256, bool));
        address payer = payerIsUser ? _getLocker() : address(this);
        _settle(currency, payer, amount);
        return "";
    }

    /// @dev Settle the full outstanding debt for a currency.
    /// @param params abi.encode(Currency currency)
    function _handleSettleAll(bytes memory params) internal returns (bytes memory) {
        Currency currency = abi.decode(params, (Currency));
        uint256 amount = _getFullDebt(currency);
        _settle(currency, _getLocker(), amount);
        return "";
    }

    /// @dev Transfer an explicit amount of a currency out.
    /// @param params abi.encode(Currency currency, address recipient, uint256 amount)
    function _handleTake(bytes memory params) internal returns (bytes memory) {
        (Currency currency, address recipient, uint256 amount) =
            abi.decode(params, (Currency, address, uint256));
        _take(currency, recipient, amount);
        return "";
    }

    /// @dev Transfer the full credit of a currency to a recipient.
    /// @param params abi.encode(Currency currency, address recipient)
    function _handleTakeAll(bytes memory params) internal returns (bytes memory) {
        (Currency currency, address recipient) = abi.decode(params, (Currency, address));
        uint256 amount = _getFullCredit(currency);
        _take(currency, recipient, amount);
        return "";
    }

    /// @dev Settle the full debt for both currencies in a pair.
    /// @param params abi.encode(Currency currency0, Currency currency1)
    function _handleSettlePair(bytes memory params) internal returns (bytes memory) {
        (Currency currency0, Currency currency1) = abi.decode(params, (Currency, Currency));
        address payer = _getLocker();
        _settle(currency0, payer, _getFullDebt(currency0));
        _settle(currency1, payer, _getFullDebt(currency1));
        return "";
    }

    /// @dev Transfer the full credit for both currencies in a pair to a recipient.
    /// @param params abi.encode(Currency currency0, Currency currency1, address recipient)
    function _handleTakePair(bytes memory params) internal returns (bytes memory) {
        (Currency currency0, Currency currency1, address recipient) =
            abi.decode(params, (Currency, Currency, address));
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
        return "";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC721 tokenURI implementation
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the token URI for a given token ID
    function tokenURI(uint256 id) public view override returns (string memory) {
        return "";
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function getMakerOrder(uint256 tokenId)
        external view returns (IUnibuyOrderManager.OrderInfo memory)
    {
        return _orders[tokenId];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _toMirrorSqrt(uint160 sqrtFwdX96) internal pure returns (uint160) {
        return uint160(FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, sqrtFwdX96));
    }
}
