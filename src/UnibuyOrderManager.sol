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
import {DeltaResolver}       from "./base/DeltaResolver.sol";
import {IUnibuyOrderManager} from "./interfaces/IUnibuyOrderManager.sol";
import {Actions}             from "./libraries/Actions.sol";
import {ActionConstants}     from "./libraries/ActionConstants.sol";
import {PathKey} from "./libraries/PathKey.sol";
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
    DeltaResolver,
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
    uint256 public lastTokenId;

    /// @dev Packed order metadata for each maker NFT. One 32-byte slot per order.
    mapping(uint256 tokenId => PackedOrderInfo) private _orders;

    /// @notice Full UnibuyPoolKey for each pool, keyed by its truncated bytes19 pool ID.
    ///         Populated on first placeOrder for a given pool (mirrors PositionManager.poolKeys).
    mapping(bytes19 poolId => UnibuyPoolKey) public poolKeys;

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
    {
        (uint160 cur,,,,,, ) = poolManager.getSlot0(key.toId());
        if (sqrtPriceLimitX96 <= cur) revert BuyPriceBelowCurrent(sqrtPriceLimitX96, cur);

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_INPUT_SINGLE,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, amountIn, amountOutMinimum, sqrtPriceLimitX96);
        params[1] = abi.encode(key.currency1);             // user pays
        params[2] = abi.encode(key.currency0, recipient);  // user receives

        _executeActions(abi.encode(actions, params));
    }

    /// @inheritdoc IUnibuyOrderManager
    function takeOrderInput(
        Currency currencyIn,
        PathKey[] calldata path,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        if (path.length == 0) revert InvalidPath();

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_INPUT,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            CalldataDecoder.TakeOrderInputParams({
                currencyIn: currencyIn,
                path: path,
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum
            })
        );
        params[1] = abi.encode(currencyIn); // user pays
        params[2] = abi.encode(
            path[path.length - 1].hopCurrency,
            recipient
        ); // user receives

        _executeActions(abi.encode(actions, params));
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
    {
        (uint160 cur,,,,,, ) = poolManager.getSlot0(key.toId());
        if (sqrtPriceLimitX96 <= cur) revert BuyPriceBelowCurrent(sqrtPriceLimitX96, cur);

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_OUTPUT_SINGLE,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, amountOut, amountInMaximum, sqrtPriceLimitX96);
        params[1] = abi.encode(key.currency1);             // user pays
        params[2] = abi.encode(key.currency0, recipient);  // user receives

        _executeActions(abi.encode(actions, params));
    }

    /// @inheritdoc IUnibuyOrderManager
    function takeOrderOutput(
        Currency currencyOut,
        PathKey[] calldata path,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        if (path.length == 0) revert InvalidPath();

        bytes memory actions = abi.encodePacked(
            Actions.TAKE_ORDER_OUTPUT,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            CalldataDecoder.TakeOrderOutputParams({
                currencyOut: currencyOut,
                path: path,
                amountOut: amountOut,
                amountInMaximum: amountInMaximum
            })
        );
        params[1] = abi.encode(path[0].hopCurrency); // user pays
        params[2] = abi.encode(currencyOut, recipient); // user receives

        _executeActions(abi.encode(actions, params));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Maker order
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function placeOrderNoTake(
        UnibuyPoolKey calldata key,
        uint256 orderInfo,
        uint128 liquidity,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        bytes memory actions = abi.encodePacked(Actions.PLACE_ORDER, Actions.SETTLE_ALL);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, orderInfo, liquidity, msg.sender);
        params[1] = abi.encode(key.currency0);

        _executeActions(abi.encode(actions, params));
    }

    /// @inheritdoc IUnibuyOrderManager
    function placeOrderWithTake(
        UnibuyPoolKey calldata key,
        uint256 orderInfo,
        uint256 amount0,
        uint256 deadline
    )
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        bytes memory actions = abi.encodePacked(
            Actions.PLACE_ORDER_WITH_TAKE,
            Actions.SETTLE_ALL,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, orderInfo, amount0, msg.sender);
        params[1] = abi.encode(key.currency0);            // user pays token0 debt
        params[2] = abi.encode(key.currency1, msg.sender); // user receives token1 from mirror take

        _executeActions(abi.encode(actions, params));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Close Maker Order
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IUnibuyOrderManager
    function closeOrder(
        uint256 tokenId,
        uint256 deadline
    )
        external
        isNotLocked
        checkDeadline(deadline)
    {
        // Look up the stored pool key to determine settlement currencies for TAKE_PAIR.
        bytes19 poolId = _orders[tokenId].poolId();
        UnibuyPoolKey memory resolvedPool = poolKeys[poolId];

        bytes memory actions = abi.encodePacked(Actions.CLOSE_ORDER, Actions.TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(resolvedPool, tokenId);
        params[1] = abi.encode(resolvedPool.currency0, resolvedPool.currency1, msg.sender);

        _executeActions(abi.encode(actions, params));
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
    {
        _executeActions(abi.encode(actions, params));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Action dispatcher
    // ─────────────────────────────────────────────────────────────────────────

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == Actions.TAKE_ORDER_INPUT_SINGLE) {
            _handleTakeOrderInputSingle(params);
        } else if (action == Actions.TAKE_ORDER_INPUT) {
            _handleTakeOrderInput(params);
        } else if (action == Actions.TAKE_ORDER_OUTPUT_SINGLE) {
            _handleTakeOrderOutputSingle(params);
        } else if (action == Actions.TAKE_ORDER_OUTPUT) {
            _handleTakeOrderOutput(params);
        } else if (action == Actions.PLACE_ORDER) {
            _handlePlaceOrder(params);
        } else if (action == Actions.PLACE_ORDER_WITH_TAKE) {
            _handlePlaceOrderWithTake(params);
        } else if (action == Actions.CLOSE_ORDER) {
            _handleClose(params);
        } else if (action == Actions.SETTLE) {
            _handleSettle(params);
        } else if (action == Actions.SETTLE_ALL) {
            _handleSettleAll(params);
        } else if (action == Actions.TAKE) {
            _handleTake(params);
        } else if (action == Actions.TAKE_ALL) {
            _handleTakeAll(params);
        } else if (action == Actions.SETTLE_PAIR) {
            _handleSettlePair(params);
        } else if (action == Actions.TAKE_PAIR) {
            _handleTakePair(params);
        } else {
            revert InvalidActionType(uint8(action));
        }
    }

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Order action handlers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Executes a single-pool exact-input taker order.
    /// @param params abi.encode(UnibuyPoolKey poolKey, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)
    function _handleTakeOrderInputSingle(bytes calldata params) internal {
        CalldataDecoder.TakeOrderInputSingleParams calldata takeParams = params.decodeTakeOrderInputSingleParams();

        uint256 amountIn = takeParams.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn = _getFullCredit(takeParams.poolKey.currency1);
        }

        (int128 delta0,) =
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.takeOrder(takeParams.poolKey, -int256(amountIn), takeParams.sqrtPriceLimitX96);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 outAmount = uint256(uint128(delta0));

        if (outAmount < takeParams.amountOutMinimum) revert TooLittleReceived(takeParams.amountOutMinimum, outAmount);
    }

    /// @dev Executes a multi-hop exact-input taker order.
    /// @param params abi.encode(CalldataDecoder.TakeOrderInputParams)
    function _handleTakeOrderInput(bytes calldata params) internal {
        CalldataDecoder.TakeOrderInputParams calldata takeParams = params.decodeTakeOrderInputParams();

        if (takeParams.path.length == 0) revert InvalidPath();

        uint256 currentAmount = takeParams.amountIn;
        if (currentAmount == ActionConstants.OPEN_DELTA) {
            currentAmount = _getFullCredit(takeParams.currencyIn);
        }
        Currency currencyIn = takeParams.currencyIn;
        for (uint256 i = 0; i < takeParams.path.length; i++) {
            PathKey calldata hop = takeParams.path[i];
            UnibuyPoolKey memory hopKey = UnibuyPoolKey({
                currency0: hop.hopCurrency,
                currency1: currencyIn,
                tickSpacing: hop.tickSpacing
            });

            (int128 delta0,) =
                // forge-lint: disable-next-line(unsafe-typecast)
                poolManager.takeOrder(hopKey, -int256(currentAmount), TickMath.MAX_SQRT_PRICE);

            // forge-lint: disable-next-line(unsafe-typecast)
            currentAmount = uint256(uint128(delta0));
            currencyIn = hop.hopCurrency;
        }

        if (currentAmount < takeParams.amountOutMinimum) revert TooLittleReceived(takeParams.amountOutMinimum, currentAmount);
    }

    /// @dev Executes a single-pool exact-output taker order.
    /// @param params abi.encode(UnibuyPoolKey poolKey, uint256 amountOut, uint256 amountInMaximum, uint160 sqrtPriceLimitX96)
    function _handleTakeOrderOutputSingle(bytes calldata params) internal {
        CalldataDecoder.TakeOrderOutputSingleParams calldata takeParams = params.decodeTakeOrderOutputSingleParams();

        uint256 amountOut = takeParams.amountOut;
        if (amountOut == ActionConstants.OPEN_DELTA) {
            amountOut = _getFullDebt(takeParams.poolKey.currency0);
        }

        (, int128 delta1) =
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.takeOrder(takeParams.poolKey, int256(amountOut), takeParams.sqrtPriceLimitX96);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 inAmount = uint256(uint128(-delta1));

        if (inAmount > takeParams.amountInMaximum) revert TooMuchRequested(takeParams.amountInMaximum, inAmount);
    }

    /// @dev Executes a multi-hop exact-output taker order (reversed path traversal).
    /// @param params abi.encode(CalldataDecoder.TakeOrderOutputParams)
    function _handleTakeOrderOutput(bytes calldata params) internal {
        CalldataDecoder.TakeOrderOutputParams calldata takeParams = params.decodeTakeOrderOutputParams();

        if (takeParams.path.length == 0) revert InvalidPath();

        // Traverse in reverse to compute required input for exact output
        uint256 currentAmount = takeParams.amountOut;
        if (currentAmount == ActionConstants.OPEN_DELTA) {
            currentAmount = _getFullDebt(takeParams.currencyOut);
        }
        Currency currencyOut = takeParams.currencyOut;
        for (uint256 i = takeParams.path.length; i > 0; ) {
            unchecked { --i; }
            PathKey calldata pathKey = takeParams.path[i];
            UnibuyPoolKey memory hopKey = UnibuyPoolKey({
                currency0: currencyOut,
                currency1: pathKey.hopCurrency,
                tickSpacing: pathKey.tickSpacing
            });
            (, int128 delta1) =
                // forge-lint: disable-next-line(unsafe-typecast)
                poolManager.takeOrder(hopKey, int256(currentAmount), TickMath.MAX_SQRT_PRICE);

            // forge-lint: disable-next-line(unsafe-typecast)    
            currentAmount = uint256(uint128(-delta1));
            currencyOut = pathKey.hopCurrency;
        }

        if (currentAmount > takeParams.amountInMaximum) revert TooMuchRequested(takeParams.amountInMaximum, currentAmount);
    }

    /// @dev Places a maker limit order from packed orderInfo.
    ///      Populates poolKeys on first use.
    ///      Delta is left for SETTLE_ALL.
    /// @param params abi.encode(UnibuyPoolKey poolKey, uint256 orderInfo, uint128 liquidity, address recipient)
    function _handlePlaceOrder(bytes calldata params) internal {
        CalldataDecoder.PlaceOrderParams calldata placeParams = params.decodePlaceMakerParams();
        PackedOrderInfo orderInfo = PackedOrderInfo.wrap(placeParams.orderInfo);

        _placeMakerInternal(
            placeParams.poolKey,
            orderInfo,
            placeParams.liquidity,
            placeParams.owner
        );
    }

    /// @dev Places a maker order with optional mirror pre-take using the token0 budget.
    function _handlePlaceOrderWithTake(bytes calldata params) internal {
        CalldataDecoder.PlaceOrderWithTakeParams calldata placeParams = params.decodePlaceOrderWithTakeParams();
        PackedOrderInfo orderInfo = PackedOrderInfo.wrap(placeParams.orderInfo);

        uint256 remainingAmount0 = placeParams.amount0;
        int24 tickLowerForPlace = orderInfo.tickLower();
        int24 tickUpperForPlace = orderInfo.tickUpper();

        // If tickLower implies a better immediate execution region, consume token0 in mirror first.
        UnibuyPoolKey memory placeKey = placeParams.poolKey;
        UnibuyPoolKey memory mirrorKey = placeKey.mirrorKey();
        (uint160 mirrorCurrentPrice,,,,,, ) = poolManager.getSlot0(mirrorKey.toId());
        uint160 mirrorPriceLimit = TickMath.getSqrtPriceAtTick(-tickLowerForPlace);

        if (mirrorPriceLimit > mirrorCurrentPrice) {
            (, int128 delta1) =
                // forge-lint: disable-next-line(unsafe-typecast)
                poolManager.takeOrder(mirrorKey, -int256(placeParams.amount0), mirrorPriceLimit);

            // mirror currency1 is original currency0, negative delta1 means currency0 spent.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 spentAmount0 = uint256(uint128(-delta1));
            remainingAmount0 = placeParams.amount0 - spentAmount0;

            // When pre-take is executed, normalize tickLower to the pool tick spacing.
            tickLowerForPlace = _alignTickUpToSpacing(tickLowerForPlace, placeKey.tickSpacing);
            orderInfo = orderInfo.setTickLower(tickLowerForPlace);
        }

        if (remainingAmount0 == 0) return;
        uint128 liquidity = _liquidityForAmount0(tickLowerForPlace, tickUpperForPlace, remainingAmount0);

        _placeMakerInternal(
            placeKey,
            orderInfo,
            liquidity,
            placeParams.owner
        );
    }

    /// @dev Shared maker placement implementation for action handlers.
    function _placeMakerInternal(
        UnibuyPoolKey memory poolKey,
        PackedOrderInfo orderInfo,
        uint128 liquidity,
        address recipient
    ) internal {
        recipient = _mapRecipient(recipient);

        int24 tickLower = orderInfo.tickLower();
        int24 tickUpper = orderInfo.tickUpper();

        uint256 tokenId = ++lastTokenId;
        poolManager.placeOrder(poolKey, tickLower, tickUpper, liquidity, bytes32(tokenId));

        // Mint the NFT to the recipient and record the order
        _mint(recipient, tokenId);

        bytes19 poolId = bytes19(UnibuyPoolId.unwrap(poolKey.toId()));
        // Store the full pool key on first sight
        if (poolKeys[poolId].tickSpacing == 0) {
            poolKeys[poolId] = poolKey;
        }

        _orders[tokenId] = orderInfo.setPoolId(poolId);
    }

    /// @dev Closes a maker order. Contains all business logic (auth check, storage lookup/update,
    ///      pool call, NFT burn, event). Credits are left for TAKE_PAIR.
    ///      Direction (buy vs sell) is derived by comparing ord.poolId to key.toId().
    /// @param params abi.encode(UnibuyPoolKey key, uint256 tokenId)
    ///              key is the FORWARD pool key; used to derive order direction.
    function _handleClose(bytes calldata params) internal {
        (, uint256 tokenId) = params.decodeCloseMakerParams();

        address caller = _getLocker();
        address tokenOwner = ownerOf(tokenId);
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotOwnerNorApproved(caller, tokenOwner);

        PackedOrderInfo orderInfo = _orders[tokenId];
        UnibuyPoolKey memory orderPoolKey = poolKeys[orderInfo.poolId()];

        int24 tickLower = orderInfo.tickLower();
        int24 tickUpper = orderInfo.tickUpper();

        (, int128 delta1, bool fullyClosed) =
            poolManager.closeOrder(orderPoolKey, tickLower, tickUpper, bytes32(tokenId));

        if (fullyClosed && orderInfo.chained() && delta1 > 0) {
            // Roll all received token1 into the mirror pool in [tickLowerMirror, tickUpperMirror].
            uint256 amount1Received = uint256(uint128(delta1));
            int24 tickLowerMirror = orderInfo.tickLowerMirror();
            int24 tickUpperMirror = orderInfo.tickUpperMirror();
            uint128 mirrorLiquidity = _liquidityForAmount0(tickLowerMirror, tickUpperMirror, amount1Received);

            if (mirrorLiquidity > 0) {
                PackedOrderInfo mirrorOrderInfo = orderInfo
                    .setTickLower(tickLowerMirror)
                    .setTickUpper(tickUpperMirror)
                    .setTickLowerMirror(tickLower)
                    .setTickUpperMirror(tickUpper);

                _placeMakerInternal(orderPoolKey.mirrorKey(), mirrorOrderInfo, mirrorLiquidity, tokenOwner);
            }
        }

        _orders[tokenId] = PackedOrderInfo.wrap(0);
        _burn(tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Settlement action handlers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Settle an explicit amount.
    /// @param params abi.encode(Currency currency, uint256 amount, bool payerIsUser)
    function _handleSettle(bytes calldata params) internal {
        (Currency currency, uint256 amount, bool payerIsUser) = params.decodeSettleParams();
        address payer = payerIsUser ? _getLocker() : address(this);
        _settle(currency, payer, amount);
    }

    /// @dev Settle the full outstanding debt for a currency.
    /// @param params abi.encode(Currency currency)
    function _handleSettleAll(bytes calldata params) internal {
        Currency currency = params.decodeCurrency();
        uint256 amount = _getFullDebt(currency);
        _settle(currency, _getLocker(), amount);
    }

    /// @dev Transfer an explicit amount of a currency out.
    /// @param params abi.encode(Currency currency, address recipient, uint256 amount)
    function _handleTake(bytes calldata params) internal {
        (Currency currency, address recipient, uint256 amount) = params.decodeTakeParams();
        _take(currency, recipient, amount);
    }

    /// @dev Transfer the full credit of a currency to a recipient.
    /// @param params abi.encode(Currency currency, address recipient)
    function _handleTakeAll(bytes calldata params) internal {
        (Currency currency, address recipient) = params.decodeCurrencyAddress();
        uint256 amount = _getFullCredit(currency);
        _take(currency, recipient, amount);
    }

    /// @dev Settle the full debt for both currencies in a pair.
    /// @param params abi.encode(Currency currency0, Currency currency1)
    function _handleSettlePair(bytes calldata params) internal {
        (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
        address payer = _getLocker();
        _settle(currency0, payer, _getFullDebt(currency0));
        _settle(currency1, payer, _getFullDebt(currency1));
    }

    /// @dev Transfer the full credit for both currencies in a pair to a recipient.
    /// @param params abi.encode(Currency currency0, Currency currency1, address recipient)
    function _handleTakePair(bytes calldata params) internal {
        (Currency currency0, Currency currency1, address recipient) = params.decodeTakePairParams();
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
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
        PackedOrderInfo info = _orders[tokenId];
        return IUnibuyOrderManager.OrderInfo({
            poolId: info.poolId(),
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            tickLowerMirror: info.tickLowerMirror(),
            tickUpperMirror: info.tickUpperMirror(),
            chained: info.chained(),
            autoClose: info.autoClose()
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────
    function _liquidityForAmount0(int24 tickLower, int24 tickUpper, uint256 amount0) internal pure returns (uint128) {
        if (amount0 == 0) return 0;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtLower > sqrtUpper) (sqrtLower, sqrtUpper) = (sqrtUpper, sqrtLower);
        if (sqrtLower == sqrtUpper) return 0;

        uint256 sqrtProductDivQ96 = FullMath.mulDiv(uint256(sqrtLower), uint256(sqrtUpper), FixedPoint96.Q96);
        uint256 liquidity = FullMath.mulDiv(amount0, sqrtProductDivQ96, uint256(sqrtUpper) - uint256(sqrtLower));
        return liquidity.toUint128();
    }

    function _alignTickUpToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick > 0 && tick % tickSpacing != 0) {
            compressed++;
        }
        return compressed * tickSpacing;
    }
}
