// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager}   from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {IUnlockCallback}      from "@unibuy/interfaces/IUnlockCallback.sol";
import {UnibuyPoolKey, UnibuyPoolId, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency}             from "@unibuy/types/Currency.sol";
import {OrderInfo}            from "@unibuy/types/UnibuyTypes.sol";
import {StateLibrary}         from "@unibuy/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@unibuy/libraries/TransientStateLibrary.sol";
import {TickMath}             from "@unibuy/libraries/TickMath.sol";
import {SqrtPriceMath}        from "@unibuy/libraries/SqrtPriceMath.sol";
import {FullMath}             from "@unibuy/libraries/FullMath.sol";

/// @dev Minimal view interface for public ERC-721 and mapping fields on UnibuyOrderManager.
interface IOrderManagerExtra {
    struct MakerOrderInfo {
        bytes19 poolId;
        int24   tickLower;
        int24   tickUpper;
        int24   tickLowerMirror;
        int24   tickUpperMirror;
        bool    chained;
        bool    autoClose;
    }
    function ownerOf(uint256 tokenId) external view returns (address);
    function getMakerOrder(uint256 tokenId) external view returns (MakerOrderInfo memory);
    function poolKeys(bytes19 poolId) external view returns (UnibuyPoolKey memory);
}

/// @title UnibuyStateViewQuoter
/// @notice Single contract combining typed pool-state reads (StateView) and
///         off-chain order-quote simulation (OrderQuoter) for the Unibuy protocol.
///
/// StateView features (all `view`):
///   • getPoolSnapshot       — slot0 + 7-day poolHeight history in one call
///   • getSlot0              — current price, tick, poolHeight, fee parameters
///   • getSlot1Heights       — 7-day pool-height snapshot array
///   • getTickInfo           — full TickInfo scalars for a single tick
///   • getTickBitmap         — one bitmap word (for UI tick range scanning)
///   • getTickInfoStack      — stack values used during dirty-tick order placement
///   • getOrderInfo          — maker position details (liquidity, orderHeight, deduction)
///   • getTransientState     — transient unlock / delta / reserve state (debug / integrators)
///
/// OrderQuoter features (non-view, off-chain only — simulate via eth_call):
///   • quoteTakeOrderExactInputSingle  — single-pool exact-input quote
///   • quoteTakeOrderExactOutputSingle — single-pool exact-output quote
///   • quoteTakeOrderExactInput        — multi-hop exact-input quote
///   • quoteTakeOrderExactOutput       — multi-hop exact-output quote
///
/// Each quote returns: amountIn, amountOut, protocolFee, sqrtPriceX96After,
///                     tickAfter, poolHeightAfter, gasEstimate.
///
/// @dev Quote functions call the real PoolManager.takeOrder() through unlock/callback
///      and then revert with a `QuoteRevert` error that encodes the result.
///      The outer function catches the revert and decodes it.  The pool state is
///      never actually mutated because the whole unlock callback reverts.
contract UnibuyStateViewQuoter is IUnlockCallback {
    using UnibuyPoolIdLibrary  for UnibuyPoolKey;
    using StateLibrary         for IUnibuyPoolManager;
    using TransientStateLibrary for IUnibuyPoolManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    IUnibuyPoolManager public immutable poolManager;
    IOrderManagerExtra public immutable orderManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Hop definition for multi-hop path quotes.
    struct QuotePathKey {
        Currency hopCurrency;  // output currency of this hop / input of the next
        int24    tickSpacing;  // tick spacing of the pool for this hop
    }

    /// @notice Full result returned by every quote function.
    struct QuoteResult {
        uint256 amountIn;           // token1 spent by the taker
        uint256 amountOut;          // token0 received by the taker
        uint256 protocolFee;        // protocol fee collected in token1
        uint160 sqrtPriceX96After;  // pool price after the simulated trade
        int24   tickAfter;          // pool tick  after the simulated trade
        uint32  poolHeightAfter;    // poolHeight after the simulated trade
        uint256 gasEstimate;        // gas used for the internal simulation
    }

    /// @notice Typed representation of PoolState.slot0.
    struct Slot0View {
        uint160 sqrtPriceX96;
        int24   tick;
        uint32  poolHeight;
        uint8   takerFee;    // 0.01 % units  e.g. 30 → 0.30 %
        uint8   dayNum;      // day index within the 252-day poolHeight cycle
        uint8   offsetFee;
        uint8   tickGapLimit;
    }

    /// @notice Typed representation of TickInfo scalar fields.
    struct TickInfoView {
        uint128 liquidityGross;
        int128  liquidityNet;
        uint96  amountReceived;
        uint96  amountOffset;
        uint32  tickHeight;
        uint32  activeEntryCount;
        uint256 clearanceListLength;
    }

    /// @notice Combined pool snapshot: slot0 + 7-day poolHeight history.
    struct PoolSnapshot {
        Slot0View  slot0;
        uint32[8]  slot1Heights;
    }

    /// @notice Status of a maker order relative to current pool price and day history.
    struct OrderCrossedStatus {
        bool   fullyCrossed;    // true if current tick >= tickUpper (all token0 sold)
        uint8  daysElapsed;     // day-boundaries crossed since placement (0=today, 7=>=7 days)
        bool   sevenDaysPassed; // true when the order was placed >=7 days ago
    }

    /// @notice Remaining token0 and pending compensation for an open maker order.
    struct OrderAmounts {
        uint256 amount0Remaining; // unsold token0 (from current sqrtPrice up to tickUpper)
        uint96  compensation;     // amountDeduction owed by this order to earlier makers
    }

    /// @notice Simulated settlement deltas if a maker order were closed now.
    struct SimulatedClose {
        int128 delta0; // token0 returned to maker (0 if fully crossed)
        int128 delta1; // net token1 after compensation deduction (negative if deduction > earned)
    }

    /// @notice Comprehensive view of a maker NFT order combining NFT, router, and pool state.
    struct FullOrderInfo {
        address       owner;
        bytes19       poolId;
        UnibuyPoolKey poolKey;
        int24         tickLower;
        int24         tickUpper;
        int24         tickLowerMirror;
        int24         tickUpperMirror;
        bool          chained;
        bool          autoClose;
        uint128       liquidity;
        uint32        orderHeight;
        uint96        amountDeduction;
        bool          fullyCrossed;
        uint8         daysElapsed;
    }

    /// @dev Shared loaded order data for inspection helpers.
    struct LoadedOrderData {
        address       owner;
        bytes19       poolId;
        UnibuyPoolKey poolKey;
        int24         tickLower;
        int24         tickUpper;
        int24         tickLowerMirror;
        int24         tickUpperMirror;
        bool          chained;
        bool          autoClose;
        uint128       liquidity;
        uint32        orderHeight;
        uint96        amountDeduction;
        uint160       sqrtPriceX96;
        int24         currentTick;
        uint32        currentPoolHeight;
        uint32[8]     heights;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error InvalidCallbackSender();
    error InvalidAction();
    error InvalidPath();
    error UnexpectedUnlockResult();

    /// @notice Thrown inside unlockCallback to carry the quote result back to the caller.
    error QuoteRevert(
        uint256 amountIn,
        uint256 amountOut,
        uint256 protocolFee,
        uint160 sqrtPriceX96After,
        int24   tickAfter,
        uint32  poolHeightAfter
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Action codes (internal dispatch inside unlockCallback)
    // ─────────────────────────────────────────────────────────────────────────

    uint8 private constant ACTION_EXACT_INPUT_SINGLE  = 1;
    uint8 private constant ACTION_EXACT_OUTPUT_SINGLE = 2;
    uint8 private constant ACTION_EXACT_INPUT_PATH    = 3;
    uint8 private constant ACTION_EXACT_OUTPUT_PATH   = 4;

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _poolManager, address _orderManager) {
        poolManager  = IUnibuyPoolManager(_poolManager);
        orderManager = IOrderManagerExtra(_orderManager);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // StateView: pool-level
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Return slot0 and 7-day poolHeight history in a single call.
    function getPoolSnapshot(UnibuyPoolKey calldata key)
        external view returns (PoolSnapshot memory snap)
    {
        UnibuyPoolId id = key.toId();
        (
            snap.slot0.sqrtPriceX96,
            snap.slot0.tick,
            snap.slot0.poolHeight,
            snap.slot0.takerFee,
            snap.slot0.dayNum,
            snap.slot0.offsetFee,
            snap.slot0.tickGapLimit
        ) = poolManager.getSlot0(id);
        snap.slot1Heights = poolManager.getSlot1Heights(id);
    }

    /// @notice Return the current price/tick/fee parameters for a pool.
    function getSlot0(UnibuyPoolKey calldata key)
        external view returns (Slot0View memory s)
    {
        (
            s.sqrtPriceX96,
            s.tick,
            s.poolHeight,
            s.takerFee,
            s.dayNum,
            s.offsetFee,
            s.tickGapLimit
        ) = poolManager.getSlot0(key.toId());
    }

    /// @notice Return the 8-element poolHeight history (index 0 = current day start).
    function getSlot1Heights(UnibuyPoolKey calldata key)
        external view returns (uint32[8] memory heights)
    {
        return poolManager.getSlot1Heights(key.toId());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // StateView: tick-level
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Return all scalar TickInfo fields for a specific tick.
    function getTickInfo(UnibuyPoolKey calldata key, int24 tick)
        external view returns (TickInfoView memory t)
    {
        (
            t.liquidityGross,
            t.liquidityNet,
            t.amountReceived,
            t.amountOffset,
            t.tickHeight,
            t.activeEntryCount,
            t.clearanceListLength
        ) = poolManager.getTickInfo(key.toId(), tick);
    }

    /// @notice Return one word from the tick bitmap (for scanning initialised ticks).
    function getTickBitmap(UnibuyPoolKey calldata key, int16 wordPos)
        external view returns (uint256 bitmap)
    {
        return poolManager.getTickBitmap(key.toId(), wordPos);
    }

    /// @notice Return the tickInfoStack (saved liquidityGross/Net) for a tick.
    function getTickInfoStack(UnibuyPoolKey calldata key, int24 tick)
        external view
        returns (uint128 liquidityGrossStack, int128 liquidityNetStack)
    {
        return poolManager.getTickInfoStack(key.toId(), tick);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // StateView: order-level
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Return maker order details stored in the pool.
    /// @param salt  The bytes32 salt used when placing the order (e.g. bytes32(tokenId)).
    function getOrderInfo(
        UnibuyPoolKey calldata key,
        address maker,
        int24   tickLower,
        int24   tickUpper,
        bytes32 salt
    ) external view returns (OrderInfo memory info) {
        return poolManager.getOrderInfo(key.toId(), maker, tickLower, tickUpper, salt);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // StateView: transient state (debug / integrators)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Return the pool's current transient state for a specific address/currency.
    /// @dev Useful during off-chain simulation to verify settle/take invariants.
    function getTransientState(address target, Currency currency)
        external view
        returns (
            bool    unlocked,
            uint256 nonzeroDeltaCount,
            int256  delta,
            Currency syncedCurrency,
            uint256  syncedReserves
        )
    {
        unlocked          = poolManager.isUnlocked();
        nonzeroDeltaCount = poolManager.getNonzeroDeltaCount();
        delta             = poolManager.currencyDelta(target, currency);
        syncedCurrency    = poolManager.getSyncedCurrency();
        syncedReserves    = poolManager.getSyncedReserves();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // OrderQuoter: public entry points  (call via eth_call only)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Quote a single-pool exact-input takeOrder (taker pays token1, receives token0).
    /// @param key               Pool key to trade against.
    /// @param amountIn          Exact token1 input to simulate.
    /// @param sqrtPriceLimitX96 Upper price limit (0 = no limit → TickMath.MAX_SQRT_PRICE).
    function quoteTakeOrderExactInputSingle(
        UnibuyPoolKey calldata key,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (QuoteResult memory result) {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encode(ACTION_EXACT_INPUT_SINGLE, key, amountIn, sqrtPriceLimitX96)) {
            revert UnexpectedUnlockResult();
        } catch (bytes memory reason) {
            result = _parseQuote(reason);
            result.gasEstimate = gasBefore - gasleft();
        }
    }

    /// @notice Quote a single-pool exact-output takeOrder (taker receives exact token0, pays token1).
    /// @param key               Pool key to trade against.
    /// @param amountOut         Exact token0 output to simulate.
    /// @param sqrtPriceLimitX96 Upper price limit (0 = no limit → TickMath.MAX_SQRT_PRICE).
    function quoteTakeOrderExactOutputSingle(
        UnibuyPoolKey calldata key,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external returns (QuoteResult memory result) {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encode(ACTION_EXACT_OUTPUT_SINGLE, key, amountOut, sqrtPriceLimitX96)) {
            revert UnexpectedUnlockResult();
        } catch (bytes memory reason) {
            result = _parseQuote(reason);
            result.gasEstimate = gasBefore - gasleft();
        }
    }

    /// @notice Quote a multi-hop exact-input path.
    /// @param currencyIn  Input token for the first hop.
    /// @param path        Ordered list of hops (hopCurrency = output of each hop).
    /// @param amountIn    Exact input budget for the first hop.
    function quoteTakeOrderExactInput(
        Currency currencyIn,
        QuotePathKey[] calldata path,
        uint256 amountIn
    ) external returns (QuoteResult memory result) {
        if (path.length == 0) revert InvalidPath();
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encode(ACTION_EXACT_INPUT_PATH, currencyIn, path, amountIn)) {
            revert UnexpectedUnlockResult();
        } catch (bytes memory reason) {
            result = _parseQuote(reason);
            result.gasEstimate = gasBefore - gasleft();
        }
    }

    /// @notice Quote a multi-hop exact-output path.
    /// @param currencyOut Final output token.
    /// @param path        Reverse-ordered hops (hopCurrency = input of each hop, walking backwards).
    /// @param amountOut   Exact final output desired.
    function quoteTakeOrderExactOutput(
        Currency currencyOut,
        QuotePathKey[] calldata path,
        uint256 amountOut
    ) external returns (QuoteResult memory result) {
        if (path.length == 0) revert InvalidPath();
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encode(ACTION_EXACT_OUTPUT_PATH, currencyOut, path, amountOut)) {
            revert UnexpectedUnlockResult();
        } catch (bytes memory reason) {
            result = _parseQuote(reason);
            result.gasEstimate = gasBefore - gasleft();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // IUnlockCallback — pool calls back here during quote simulation
    // ─────────────────────────────────────────────────────────────────────────

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidCallbackSender();

        (uint8 action) = abi.decode(data, (uint8));

        if (action == ACTION_EXACT_INPUT_SINGLE) {
            (, UnibuyPoolKey memory key, uint256 amountIn, uint160 sqrtPriceLimitX96) =
                abi.decode(data, (uint8, UnibuyPoolKey, uint256, uint160));
            _simulateExactInputSingle(key, amountIn, sqrtPriceLimitX96);
        } else if (action == ACTION_EXACT_OUTPUT_SINGLE) {
            (, UnibuyPoolKey memory key, uint256 amountOut, uint160 sqrtPriceLimitX96) =
                abi.decode(data, (uint8, UnibuyPoolKey, uint256, uint160));
            _simulateExactOutputSingle(key, amountOut, sqrtPriceLimitX96);
        } else if (action == ACTION_EXACT_INPUT_PATH) {
            (, Currency currencyIn, QuotePathKey[] memory path, uint256 amountIn) =
                abi.decode(data, (uint8, Currency, QuotePathKey[], uint256));
            _simulateExactInputPath(currencyIn, path, amountIn);
        } else if (action == ACTION_EXACT_OUTPUT_PATH) {
            (, Currency currencyOut, QuotePathKey[] memory path, uint256 amountOut) =
                abi.decode(data, (uint8, Currency, QuotePathKey[], uint256));
            _simulateExactOutputPath(currencyOut, path, amountOut);
        } else {
            revert InvalidAction();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Simulation internals
    // ─────────────────────────────────────────────────────────────────────────

    function _simulateExactInputSingle(
        UnibuyPoolKey memory key,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) internal {
        uint256 feeBefore = poolManager.protocolFeesAccrued(key.currency1);
        (int128 delta0, int128 delta1) = poolManager.takeOrder(key, -int256(amountIn), sqrtPriceLimitX96);
        uint256 feeAfter = poolManager.protocolFeesAccrued(key.currency1);

        (uint160 sqrtAfter, int24 tickAfter, uint32 heightAfter,,,,) = poolManager.getSlot0(key.toId());

        uint256 usedIn  = delta1 < 0 ? uint256(uint128(-delta1)) : 0;
        uint256 gotOut  = delta0 > 0 ? uint256(uint128(delta0))  : 0;

        revert QuoteRevert(usedIn, gotOut, feeAfter - feeBefore, sqrtAfter, tickAfter, heightAfter);
    }

    function _simulateExactOutputSingle(
        UnibuyPoolKey memory key,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) internal {
        uint256 feeBefore = poolManager.protocolFeesAccrued(key.currency1);
        (int128 delta0, int128 delta1) = poolManager.takeOrder(key, int256(amountOut), sqrtPriceLimitX96);
        uint256 feeAfter = poolManager.protocolFeesAccrued(key.currency1);

        (uint160 sqrtAfter, int24 tickAfter, uint32 heightAfter,,,,) = poolManager.getSlot0(key.toId());

        uint256 usedIn = delta1 < 0 ? uint256(uint128(-delta1)) : 0;
        uint256 gotOut = delta0 > 0 ? uint256(uint128(delta0))  : 0;

        revert QuoteRevert(usedIn, gotOut, feeAfter - feeBefore, sqrtAfter, tickAfter, heightAfter);
    }

    function _simulateExactInputPath(
        Currency currencyIn,
        QuotePathKey[] memory path,
        uint256 amountIn
    ) internal {
        uint256 currentAmount = amountIn;
        uint256 usedInFirstHop;
        uint256 totalProtocolFee;
        UnibuyPoolKey memory lastHopKey;

        for (uint256 i = 0; i < path.length; i++) {
            QuotePathKey memory hop = path[i];
            // Pool layout: currency0 = output token (what taker receives), currency1 = input token (what taker pays)
            UnibuyPoolKey memory hopKey = UnibuyPoolKey({
                currency0:   hop.hopCurrency,
                currency1:  currencyIn,
                tickSpacing: hop.tickSpacing
            });

            uint256 feeBefore = poolManager.protocolFeesAccrued(hopKey.currency1);
            (int128 delta0, int128 delta1) =
                poolManager.takeOrder(hopKey, -int256(currentAmount), TickMath.MAX_SQRT_PRICE);
            uint256 feeAfter = poolManager.protocolFeesAccrued(hopKey.currency1);

            if (i == 0 && delta1 < 0) {
                usedInFirstHop = uint256(uint128(-delta1));
            }

            currentAmount   = delta0 > 0 ? uint256(uint128(delta0)) : 0;
            totalProtocolFee += (feeAfter - feeBefore);
            currencyIn      = hop.hopCurrency;
            lastHopKey      = hopKey;
        }

        (uint160 sqrtAfter, int24 tickAfter, uint32 heightAfter,,,,) = poolManager.getSlot0(lastHopKey.toId());
        revert QuoteRevert(usedInFirstHop, currentAmount, totalProtocolFee, sqrtAfter, tickAfter, heightAfter);
    }

    function _simulateExactOutputPath(
        Currency currencyOut,
        QuotePathKey[] memory path,
        uint256 amountOut
    ) internal {
        uint256 currentRequiredIn = amountOut;
        uint256 totalProtocolFee;
        UnibuyPoolKey memory firstExecutedHopKey;

        for (uint256 i = path.length; i > 0;) {
            unchecked { --i; }

            QuotePathKey memory hop = path[i];
            UnibuyPoolKey memory hopKey = UnibuyPoolKey({
                currency0:   currencyOut,
                currency1:  hop.hopCurrency,
                tickSpacing: hop.tickSpacing
            });

            uint256 feeBefore = poolManager.protocolFeesAccrued(hopKey.currency1);
            (, int128 delta1) = poolManager.takeOrder(hopKey, int256(currentRequiredIn), TickMath.MAX_SQRT_PRICE);
            uint256 feeAfter = poolManager.protocolFeesAccrued(hopKey.currency1);

            currentRequiredIn = delta1 < 0 ? uint256(uint128(-delta1)) : 0;
            totalProtocolFee += (feeAfter - feeBefore);
            currencyOut = hop.hopCurrency;

            if (i == 0) firstExecutedHopKey = hopKey;
        }

        (uint160 sqrtAfter, int24 tickAfter, uint32 heightAfter,,,,) =
            poolManager.getSlot0(firstExecutedHopKey.toId());
        revert QuoteRevert(currentRequiredIn, amountOut, totalProtocolFee, sqrtAfter, tickAfter, heightAfter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Order inspection — view functions
    // ─────────────────────────────────────────────────────────────────────────

    function getOrderCrossedStatus(uint256 tokenId)
        external view returns (OrderCrossedStatus memory status)
    {
        LoadedOrderData memory o = this.loadOrderInspectionData(tokenId);
        status.fullyCrossed = o.currentTick >= o.tickUpper;

        status.daysElapsed = 7;
        for (uint8 i = 0; i < 8; i++) {
            if (o.heights[i] == 0) {
                status.daysElapsed = i;
                break;
            }
            if (o.orderHeight >= o.heights[i]) {
                status.daysElapsed = i;
                break;
            }
        }
        status.sevenDaysPassed = o.heights[7] > 0 && o.orderHeight < o.heights[7];
    }

    function getOrderToken0AndCompensation(uint256 tokenId)
        external view returns (OrderAmounts memory amounts)
    {
        LoadedOrderData memory o = this.loadOrderInspectionData(tokenId);
        amounts.compensation = o.amountDeduction;

        if (o.liquidity == 0) return amounts;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(o.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(o.tickUpper);

        if (o.currentTick >= o.tickUpper) {
            amounts.amount0Remaining = 0;
        } else if (o.sqrtPriceX96 <= sqrtLower) {
            amounts.amount0Remaining =
                SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, o.liquidity, false);
        } else {
            amounts.amount0Remaining =
                SqrtPriceMath.getAmount0Delta(o.sqrtPriceX96, sqrtUpper, o.liquidity, false);
        }
    }

    function simulateCloseOrder(uint256 tokenId)
        external view returns (SimulatedClose memory result)
    {
        LoadedOrderData memory o = this.loadOrderInspectionData(tokenId);
        if (o.liquidity == 0) return result;

        (uint256 t0, uint256 t1) = _computeSettlement(
            o.poolKey.toId(), o.tickLower, o.tickUpper, o.liquidity, o.orderHeight
        );

        uint96 deduction = o.amountDeduction;
        if (t1 >= uint256(deduction)) {
            result.delta1 = int128(int256(t1 - uint256(deduction)));
        } else {
            result.delta1 = -int128(int256(uint256(deduction) - t1));
        }
        result.delta0 = int128(int256(t0));
    }

    function getFullOrderInfo(uint256 tokenId)
        external view returns (FullOrderInfo memory info)
    {
        LoadedOrderData memory o = this.loadOrderInspectionData(tokenId);

        info.owner           = o.owner;
        info.poolId          = o.poolId;
        info.poolKey         = o.poolKey;
        info.tickLower       = o.tickLower;
        info.tickUpper       = o.tickUpper;
        info.tickLowerMirror = o.tickLowerMirror;
        info.tickUpperMirror = o.tickUpperMirror;
        info.chained         = o.chained;
        info.autoClose       = o.autoClose;
        info.liquidity       = o.liquidity;
        info.orderHeight     = o.orderHeight;
        info.amountDeduction = o.amountDeduction;
        info.fullyCrossed    = o.currentTick >= o.tickUpper;

        info.daysElapsed = 7;
        for (uint8 i = 0; i < 8; i++) {
            if (o.heights[i] == 0) {
                info.daysElapsed = i;
                break;
            }
            if (o.orderHeight >= o.heights[i]) {
                info.daysElapsed = i;
                break;
            }
        }
    }

    /// @notice Shared loader for inspection views.
    /// @dev Kept as a single entrypoint to avoid optimizer issues with repeated call patterns.
    function loadOrderInspectionData(uint256 tokenId)
        external view returns (LoadedOrderData memory o)
    {
        o.owner = orderManager.ownerOf(tokenId);

        IOrderManagerExtra.MakerOrderInfo memory meta = orderManager.getMakerOrder(tokenId);
        o.poolId          = meta.poolId;
        o.tickLower       = meta.tickLower;
        o.tickUpper       = meta.tickUpper;
        o.tickLowerMirror = meta.tickLowerMirror;
        o.tickUpperMirror = meta.tickUpperMirror;
        o.chained         = meta.chained;
        o.autoClose       = meta.autoClose;

        UnibuyPoolKey memory key = orderManager.poolKeys(meta.poolId);
        o.poolKey = key;
        UnibuyPoolId id = key.toId();

        OrderInfo memory poolOrderInfo =
            poolManager.getOrderInfo(id, address(orderManager), meta.tickLower, meta.tickUpper, bytes32(tokenId));
        o.liquidity       = poolOrderInfo.liquidity;
        o.orderHeight     = poolOrderInfo.orderHeight;
        o.amountDeduction = poolOrderInfo.amountDeduction;

        (o.sqrtPriceX96, o.currentTick, o.currentPoolHeight,,,,) = poolManager.getSlot0(id);
        o.heights = poolManager.getSlot1Heights(id);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Settlement helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _computeSettlement(
        UnibuyPoolId id,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        uint32  orderHeight
    ) private view returns (uint256 token0, uint256 token1) {
        (uint160 sqrtPriceX96, int24 currentTick, uint32 currentPoolHeight,,,, ) =
            poolManager.getSlot0(id);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        if (currentTick >= tickUpper) {
            (bool found, uint256 t1) =
                _readClearanceSettlement(id, tickUpper, liquidity, orderHeight, currentPoolHeight);
            if (found) token1 = t1;
        } else if (sqrtPriceX96 <= sqrtLower) {
            token0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else {
            token0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            (uint128 liqGross,,uint96 amtReceived,,,, ) = poolManager.getTickInfo(id, tickLower);
            if (liqGross > 0 && amtReceived > 0) {
                token1 = FullMath.mulDiv(liquidity, amtReceived, liqGross);
            }
        }
    }

    function _clearanceListSlots(UnibuyPoolId id, int24 tick)
        private pure
        returns (bytes32 lengthSlot, bytes32 dataStart)
    {
        bytes32 stateSlot        = keccak256(abi.encode(UnibuyPoolId.unwrap(id), StateLibrary.POOLS_SLOT));
        bytes32 ticksMappingSlot = bytes32(uint256(stateSlot) + StateLibrary.TICKS_OFFSET);
        bytes32 tickBase         = keccak256(abi.encode(int256(tick), ticksMappingSlot));
        lengthSlot               = bytes32(uint256(tickBase) + 2);
        dataStart                = keccak256(abi.encode(lengthSlot));
    }

    function _resolvedCrossHeight(uint24 ch24, uint32 currentPoolHeight)
        private pure returns (uint32 h)
    {
        h = (currentPoolHeight & 0xFF000000) | uint32(ch24);
        if (h > currentPoolHeight) h -= 0x01000000;
    }

    function _readClearanceSettlement(
        UnibuyPoolId id,
        int24        tick,
        uint128      orderLiquidity,
        uint32       orderHeight,
        uint32       currentPoolHeight
    ) private view returns (bool found, uint256 token1Out) {
        (bytes32 lengthSlot, bytes32 dataStart) = _clearanceListSlots(id, tick);

        uint256 listLength = uint256(poolManager.extsload(lengthSlot));
        if (listLength == 0) return (false, 0);

        uint256 lo = 0;
        uint256 hi = listLength;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            bytes32 midPacked = poolManager.extsload(bytes32(uint256(dataStart) + mid));
            uint24 ch24 = uint24(uint256(midPacked) & 0xFFFFFF);
            uint32 h = _resolvedCrossHeight(ch24, currentPoolHeight);
            if (h < orderHeight) { lo = mid + 1; } else { hi = mid; }
        }
        if (lo >= listLength) return (false, 0);

        bytes32 packed = poolManager.extsload(bytes32(uint256(dataStart) + lo));
        uint128 liquiditySold = uint128(uint256(packed) >> 128);
        uint96 amountReceived = uint96((uint256(packed) >> 32) & type(uint96).max);

        if (liquiditySold == 0) return (false, 0);

        token1Out = FullMath.mulDiv(orderLiquidity, amountReceived, liquiditySold);
        found = true;
    }


    // ─────────────────────────────────────────────────────────────────────────
    // Quote result parser
    // ─────────────────────────────────────────────────────────────────────────

    function _parseQuote(bytes memory reason) internal pure returns (QuoteResult memory result) {
        // Minimum: 4-byte selector + 6 × 32-byte fields = 196 bytes
        if (reason.length < 196) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }

        bytes4 selector;
        assembly ("memory-safe") { selector := mload(add(reason, 32)) }

        if (selector != QuoteRevert.selector) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }

        uint256 amountIn;
        uint256 amountOut;
        uint256 protocolFee;
        uint256 sqrtWord;
        uint256 tickWord;
        uint256 heightWord;
        assembly ("memory-safe") {
            amountIn    := mload(add(reason, 0x24))
            amountOut   := mload(add(reason, 0x44))
            protocolFee := mload(add(reason, 0x64))
            sqrtWord    := mload(add(reason, 0x84))
            tickWord    := mload(add(reason, 0xA4))
            heightWord  := mload(add(reason, 0xC4))
        }

        result.amountIn          = amountIn;
        result.amountOut         = amountOut;
        result.protocolFee       = protocolFee;
        result.sqrtPriceX96After = uint160(sqrtWord);
        result.tickAfter         = int24(int256(tickWord));
        // forge-lint: disable-next-line(unsafe-typecast)
        result.poolHeightAfter   = uint32(heightWord);
    }
}
