// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {UnibuyPoolKey, UnibuyPoolId, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency, CurrencyLibrary} from "@unibuy/types/Currency.sol";
import {FullMath}           from "@unibuy/libraries/FullMath.sol";
import {FixedPoint96}       from "@unibuy/libraries/FixedPoint96.sol";
import {StateLibrary}       from "@unibuy/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@unibuy/libraries/TransientStateLibrary.sol";
import {SafeCast}           from "@unibuy/libraries/SafeCast.sol";
import {TickMath}           from "@unibuy/libraries/TickMath.sol";

import {ERC721Permit_v4}     from "./base/ERC721Permit_v4.sol";
import {Multicall_v4}        from "./base/Multicall_v4.sol";
import {ReentrancyLock}      from "./base/ReentrancyLock.sol";
import {PoolInitializer}     from "./base/PoolInitializer.sol";
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
import {ECDSA} from "../lib/permit2/lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
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
    PoolInitializer,
    BaseActionsRouter,
    DeltaResolver,
    Permit2Forwarder,
    NativeWrapper,
    IUnibuyOrderManager
{
    using UnibuyPoolIdLibrary for UnibuyPoolKey;
    using CurrencyLibrary    for Currency;
    using StateLibrary       for IUnibuyPoolManager;
    using TransientStateLibrary for IUnibuyPoolManager;
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
    ///         Populated on first makeOrder for a given pool (mirrors PositionManager.poolKeys).
    mapping(bytes19 poolId => UnibuyPoolKey) public poolKeys;

    /// @inheritdoc IUnibuyOrderManager
    mapping(int24 tickSpacing => uint8 feeBips) public autoCloseFeeBips;

    /// @inheritdoc IUnibuyOrderManager
    address public autoCloseFeeController;

    bytes32 private constant _EXECUTE_SIGNED_TYPEHASH = keccak256(
        "ExecuteSigned(bytes actions,bytes[] params,bytes32 intent,bytes32 data,address sender,bytes32 nonce,uint256 deadline)"
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _poolManager, IAllowanceTransfer _permit2, IWETH9 _weth9)
        ERC721Permit_v4("Unibuy Orders NFT", "UNB-ORD")
        BaseActionsRouter(IUnibuyPoolManager(_poolManager))
        Permit2Forwarder(_permit2)
        NativeWrapper(_weth9)
    {
        autoCloseFeeController = msg.sender;
    }

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
    function makeOrder(
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
        bytes memory actions = abi.encodePacked(Actions.MAKE_ORDER, Actions.SETTLE_ALL);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, orderInfo, liquidity, msg.sender);
        params[1] = abi.encode(key.currency0);

        _executeActions(abi.encode(actions, params));
    }

    /// @inheritdoc IUnibuyOrderManager
    function makeOrderWithTake(
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
            Actions.MAKE_ORDER_WITH_TAKE,
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
        address tokenOwner = ownerOf(tokenId);

        // Look up the stored pool key to determine settlement currencies.
        bytes19 poolId = _orders[tokenId].poolId();
        UnibuyPoolKey memory orderPoolKey = poolKeys[poolId];

        bytes memory actions = abi.encodePacked(
            Actions.CLOSE_ORDER,
            Actions.CLOSE_CURRENCY,
            Actions.TAKE_ALL
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId);
        // Close token1 delta first: settle debt (if any) or take credit to tokenOwner.
        params[1] = abi.encode(orderPoolKey.currency1, tokenOwner);
        // Then take any remaining token0 credit to tokenOwner.
        params[2] = abi.encode(orderPoolKey.currency0, tokenOwner);

        _executeActions(abi.encode(actions, params));
    }

    /// @inheritdoc IUnibuyOrderManager
    function closeOrderAuto(
        uint256 tokenId,
        uint256 deadline
    )
        external
        isNotLocked
        checkDeadline(deadline)
    {
        bytes memory actions = abi.encodePacked(Actions.CLOSE_ORDER_AUTO);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId);

        _executeActions(abi.encode(actions, params));
    }

    /// @inheritdoc IUnibuyOrderManager
    function setAutoCloseFeeBips(int24 tickSpacing, uint8 feeBips) external {
        if (msg.sender != autoCloseFeeController) revert OnlyAutoCloseFeeController();
        autoCloseFeeBips[tickSpacing] = feeBips;
    }

    /// @inheritdoc IUnibuyOrderManager
    function setAutoCloseFeeController(address newController) external {
        if (msg.sender != autoCloseFeeController) revert OnlyAutoCloseFeeController();
        if (newController == address(0)) revert InvalidAutoCloseFeeController(newController);

        address oldController = autoCloseFeeController;
        autoCloseFeeController = newController;
        emit AutoCloseFeeControllerUpdated(oldController, newController);
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
        checkDeadline(deadline)
    {
        execute(actions, params);
    }

    /// @inheritdoc IUnibuyOrderManager
    function execute(
        bytes calldata actions,
        bytes[] calldata params
    )
        public
        payable
        isNotLocked
    {
        _executeActions(abi.encode(actions, params));
    }

    /// @inheritdoc IUnibuyOrderManager
    function executeSigned(
        bytes calldata actions,
        bytes[] calldata params,
        bytes32 intent,
        bytes32 data,
        bool verifySender,
        bytes32 nonce,
        bytes calldata signature,
        uint256 deadline
    )
        external
        payable
        checkDeadline(deadline)
    {
        address sender = verifySender ? msg.sender : address(0);
        bytes32 structHash = keccak256(
            abi.encode(
                _EXECUTE_SIGNED_TYPEHASH,
                keccak256(actions),
                _hashBytesArray(params),
                intent,
                data,
                sender,
                nonce,
                deadline
            )
        );

        (address signer, ECDSA.RecoverError err) = ECDSA.tryRecover(_hashTypedData(structHash), signature);
        if (err != ECDSA.RecoverError.NoError) revert InvalidExecuteSignature();
        if (verifySender && signer != msg.sender) revert InvalidExecuteSignature();

        _useUnorderedNonce(signer, uint256(nonce));
        execute(actions, params);
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
        } else if (action == Actions.MAKE_ORDER) {
            _handleMakeOrder(params);
        } else if (action == Actions.MAKE_ORDER_WITH_TAKE) {
            _handleMakeOrderWithTake(params);
        } else if (action == Actions.CLOSE_ORDER) {
            _handleClose(params);
        } else if (action == Actions.CLOSE_ORDER_AUTO) {
            _handleCloseAuto(params);
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
        } else if (action == Actions.CLOSE_CURRENCY) {
            _handleCloseCurrency(params);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
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

    function _hashBytesArray(bytes[] calldata params) private pure returns (bytes32) {
        uint256 paramsLength = params.length;
        bytes32[] memory paramHashes = new bytes32[](paramsLength);
        for (uint256 i = 0; i < paramsLength; ++i) {
            paramHashes[i] = keccak256(params[i]);
        }
        return keccak256(abi.encodePacked(paramHashes));
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

    /// @dev Makes a maker limit order from packed orderInfo.
    ///      Populates poolKeys on first use.
    ///      Delta is left for SETTLE_ALL.
    /// @param params abi.encode(UnibuyPoolKey poolKey, uint256 orderInfo, uint128 liquidity, address recipient)
    function _handleMakeOrder(bytes calldata params) internal {
        CalldataDecoder.MakeOrderParams calldata makeParams = params.decodeMakeOrderParams();
        PackedOrderInfo orderInfo = PackedOrderInfo.wrap(makeParams.orderInfo);

        _makeOrderInternal(
            makeParams.poolKey,
            orderInfo,
            makeParams.liquidity,
            makeParams.owner
        );
    }

    /// @dev Makes a maker order with optional mirror pre-take using the token0 budget.
    function _handleMakeOrderWithTake(bytes calldata params) internal {
        CalldataDecoder.MakeOrderWithTakeParams calldata makeParams = params.decodeMakeOrderWithTakeParams();
        PackedOrderInfo orderInfo = PackedOrderInfo.wrap(makeParams.orderInfo);

        _makeOrderWithTakeInternal(makeParams.poolKey, orderInfo, makeParams.amount0, makeParams.owner);
    }

    function _makeOrderWithTakeInternal(
        UnibuyPoolKey memory makeKey,
        PackedOrderInfo orderInfo,
        uint256 amount0,
        address owner
    ) internal {
        uint256 remainingAmount0 = amount0;
        int24 tickLowerForMake = orderInfo.tickLower();
        int24 tickUpperForMake = orderInfo.tickUpper();

        // If tickLower implies a better immediate execution region, consume token0 in mirror first.
        UnibuyPoolKey memory mirrorKey = makeKey.mirrorKey();
        (uint160 mirrorCurrentPrice,,,,,, ) = poolManager.getSlot0(mirrorKey.toId());
        uint160 mirrorPriceLimit = TickMath.getSqrtPriceAtTick(-tickLowerForMake);

        if (mirrorPriceLimit > mirrorCurrentPrice) {
            (, int128 delta1) =
                // forge-lint: disable-next-line(unsafe-typecast)
                poolManager.takeOrder(mirrorKey, -int256(amount0), mirrorPriceLimit);

            // mirror currency1 is original currency0, negative delta1 means currency0 spent.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 spentAmount0 = uint256(uint128(-delta1));
            remainingAmount0 = amount0 - spentAmount0;

            // When pre-take is executed, normalize tickLower to the pool tick spacing.
            tickLowerForMake = _alignTickUpToSpacing(tickLowerForMake, makeKey.tickSpacing);
            orderInfo = orderInfo.setTickLower(tickLowerForMake);
        }

        if (remainingAmount0 == 0) return;
        uint128 liquidity = _liquidityForAmount0(tickLowerForMake, tickUpperForMake, remainingAmount0);

        _makeOrderInternal(
            makeKey,
            orderInfo,
            liquidity,
            owner
        );
    }

    /// @dev Shared maker makeOrder implementation for action handlers.
    function _makeOrderInternal(
        UnibuyPoolKey memory poolKey,
        PackedOrderInfo orderInfo,
        uint128 liquidity,
        address recipient
    ) internal {
        recipient = _mapRecipient(recipient);

        int24 tickLower = orderInfo.tickLower();
        int24 tickUpper = orderInfo.tickUpper();

        uint256 tokenId = ++lastTokenId;
        poolManager.makeOrder(poolKey, tickLower, tickUpper, liquidity, bytes32(tokenId));

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
    ///      pool call, NFT burn). Credits are left for TAKE_PAIR.
    /// @param params abi.encode(uint256 tokenId)
    function _handleClose(bytes calldata params) internal {
        uint256 tokenId = params.decodeCloseTokenId();

        address caller = _getLocker();
        address tokenOwner = ownerOf(tokenId);
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotOwnerNorApproved(caller, tokenOwner);

        PackedOrderInfo orderInfo = _orders[tokenId];
        UnibuyPoolKey memory orderPoolKey = poolKeys[orderInfo.poolId()];

        int24 tickLower = orderInfo.tickLower();
        int24 tickUpper = orderInfo.tickUpper();

        (, int128 delta1, ) =
            poolManager.closeOrder(orderPoolKey, tickLower, tickUpper, bytes32(tokenId));

        if (orderInfo.chained() && delta1 > 0) {
            // Roll all received token1 into the mirror pool in [tickLowerMirror, tickUpperMirror].
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount1Received = uint256(uint128(delta1));
            int24 tickLowerMirror = orderInfo.tickLowerMirror();
            int24 tickUpperMirror = orderInfo.tickUpperMirror();
            uint128 mirrorLiquidity = _liquidityForAmount0(tickLowerMirror, tickUpperMirror, amount1Received);

            if (mirrorLiquidity > 0) {
                PackedOrderInfo mirrorOrderInfo = orderInfo
                    .setTickLower(tickLowerMirror)
                    .setTickUpper(tickUpperMirror)
                    .setTickLowerMirror(tickLower)
                    .setTickUpperMirror(tickUpper)
                    .setChained();
                if (orderInfo.autoClose()) {
                    mirrorOrderInfo = mirrorOrderInfo.setAuto();
                }

                _makeOrderWithTakeInternal(orderPoolKey.mirrorKey(), mirrorOrderInfo, amount1Received, tokenOwner);
            }
        }

        _orders[tokenId] = PackedOrderInfo.wrap(0);
        _burn(tokenId);
    }

    /// @dev Permissionless close for stale fully-crossed orders.
    ///      Eligibility is enforced by `poolManager.closeOrder` via `bCloseLate`.
    ///      This manager only validates the returned flag and then settles deltas.
    ///      Token1 credit is distributed between owner and closer fee recipient in one pass,
    ///      without requiring additional owner settlement approvals.
    function _handleCloseAuto(bytes calldata params) internal {
        uint256 tokenId = params.decodeCloseTokenId();

        address closer = _getLocker();
        address tokenOwner = ownerOf(tokenId);
        if (closer == tokenOwner) revert AutoCloseNotEligible(tokenId);

        PackedOrderInfo orderInfo = _orders[tokenId];
        if (!orderInfo.autoClose()) revert AutoCloseNotEligible(tokenId);
        UnibuyPoolKey memory orderPoolKey = poolKeys[orderInfo.poolId()];

        int24 tickLower = orderInfo.tickLower();
        int24 tickUpper = orderInfo.tickUpper();
        (int128 delta0, int128 delta1, bool bCloseLate) =
            poolManager.closeOrder(orderPoolKey, tickLower, tickUpper, bytes32(tokenId));
        if (!bCloseLate) revert AutoCloseNotEligible(tokenId);
        
        if (delta1 < 0) revert AutoCloseNotEligible(tokenId);   // Not possible to have token1 debt when closing.  
        // delta0 < 0 is possible to happen, we could swap token 0 with token 1 for user. Just keep it simple for now.
        if (delta0 < 0) revert AutoCloseNotEligible(tokenId);  
        
        // Seed helper-fee calculation from closeOrder's token1 delta.
        // Final owner payout intentionally refreshes from full transient credit,
        // which allows unified settlement of all token1 credit in this callback.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 token1Out = uint256(uint128(delta1));

        uint8 feeBips = autoCloseFeeBips[orderPoolKey.tickSpacing];
        if (feeBips > 0 && token1Out > 0) {
            uint256 closerFee = FullMath.mulDiv(token1Out, feeBips, 10_000);
            if (closerFee > 0) {
                _take(orderPoolKey.currency1, closer, closerFee);
                token1Out -= closerFee;
            }
        }

        if (orderInfo.chained() && token1Out > 0) {
            // Roll all received token1 into the mirror pool in [tickLowerMirror, tickUpperMirror].
            int24 tickLowerMirror = orderInfo.tickLowerMirror();
            int24 tickUpperMirror = orderInfo.tickUpperMirror();
            uint128 mirrorLiquidity = _liquidityForAmount0(tickLowerMirror, tickUpperMirror, token1Out);

            if (mirrorLiquidity > 0) {
                PackedOrderInfo mirrorOrderInfo = orderInfo
                    .setTickLower(tickLowerMirror)
                    .setTickUpper(tickUpperMirror)
                    .setTickLowerMirror(tickLower)
                    .setTickUpperMirror(tickUpper)
                    .setChained()
                    .setAuto();

                _makeOrderWithTakeInternal(orderPoolKey.mirrorKey(), mirrorOrderInfo, token1Out, tokenOwner);
            }
        }

        // Design choice: unified settlement for all token1 credit accumulated in this callback.
        token1Out = _getFullCredit(orderPoolKey.currency1);
        if (token1Out > 0) {
            _take(orderPoolKey.currency1, tokenOwner, token1Out);
        }

        uint256 token0Out = _getFullCredit(orderPoolKey.currency0);
        if (token0Out > 0) {
            _take(orderPoolKey.currency0, tokenOwner, token0Out);
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

    /// @dev Closes full delta for `currency` using `owner` as payer/recipient.
    ///      If debt exists, settles from owner. If credit exists, transfers to owner.
    /// @param params abi.encode(Currency currency, address owner)
    function _handleCloseCurrency(bytes calldata params) internal {
        (Currency currency, address owner) = params.decodeCurrencyAddress();
        uint256 debt = _getFullDebt(currency);
        if (debt > 0) {
            _settle(currency, owner, debt);
            return;
        }

        uint256 credit = _getFullCredit(currency);
        if (credit > 0) {
            _take(currency, owner, credit);
        }

        _close(currency, owner);
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

    /// @dev Close this contract's transient delta for `currency` against `owner`.
    ///      Mirrors v4-periphery PositionManager _close semantics.
    function _close(Currency currency, address owner) internal {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);

        if (currencyDelta < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            _settle(currency, owner, uint256(-currencyDelta));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            _take(currency, owner, uint256(currencyDelta));
        }
    }
}
