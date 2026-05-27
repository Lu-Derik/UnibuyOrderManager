// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnibuyPoolManager}   from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {UnibuyPoolKey, UnibuyPoolId, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency}             from "@unibuy/types/Currency.sol";
import {OrderInfo}            from "@unibuy/types/UnibuyTypes.sol";
import {StateLibrary}         from "@unibuy/libraries/StateLibrary.sol";
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

/// @title OrderInspectionView
/// @notice View-only lens contract for inspecting individual maker orders on the Unibuy protocol.
///
/// Functions:
///   • getOrderCrossedStatus       — crossed flag + how many days since placement
///   • getOrderToken0AndCompensation — unsold token0 + pending compensation
///   • simulateCloseOrder          — estimated (delta0, delta1) if closed now
///   • getFullOrderInfo            — comprehensive order snapshot in one call
///
/// @dev Deployed alongside UnibuyStateViewQuoter.  Kept in a separate contract to work
///      around an internal solc optimizer bug (via_ir + many similar external-call patterns).
contract OrderInspectionView {
    using UnibuyPoolIdLibrary  for UnibuyPoolKey;
    using StateLibrary         for IUnibuyPoolManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables
    // ─────────────────────────────────────────────────────────────────────────

    IUnibuyPoolManager public immutable poolManager;
    IOrderManagerExtra public immutable orderManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Status of a maker order relative to current pool price and day history.
    struct OrderCrossedStatus {
        bool   fullyCrossed;    // true if current tick >= tickUpper (all token0 sold)
        uint8  daysElapsed;     // day-boundaries crossed since placement (0=today, 7=≥7 days)
        bool   sevenDaysPassed; // true when the order was placed ≥7 days ago
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
        // Pool-level order state
        uint128       liquidity;
        uint32        orderHeight;
        uint96        amountDeduction;
        // Derived status
        bool          fullyCrossed;
        uint8         daysElapsed;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _poolManager, address _orderManager) {
        poolManager  = IUnibuyPoolManager(_poolManager);
        orderManager = IOrderManagerExtra(_orderManager);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Order inspection — view functions (no simulation required)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Return whether the NFT order is fully crossed and how many days have elapsed
    ///         since placement, compared against the pool's 7-day poolHeight history.
    ///
    /// @param tokenId  ERC-721 token ID of the maker order.
    function getOrderCrossedStatus(uint256 tokenId)
        external view returns (OrderCrossedStatus memory status)
    {
        IOrderManagerExtra.MakerOrderInfo memory meta = orderManager.getMakerOrder(tokenId);
        UnibuyPoolKey memory key = orderManager.poolKeys(meta.poolId);
        UnibuyPoolId id = key.toId();

        (, int24 currentTick,,,,,) = poolManager.getSlot0(id);
        status.fullyCrossed = currentTick >= meta.tickUpper;

        // Read pool-level order info to get orderHeight (placement height).
        OrderInfo memory info =
            poolManager.getOrderInfo(id, address(orderManager), meta.tickLower, meta.tickUpper, bytes32(tokenId));

        // 7-day poolHeight history: heights[0] = today start, heights[7] = 7 days ago start.
        uint32[8] memory heights = poolManager.getSlot1Heights(id);

        // Find the most recent day boundary that the orderHeight is at or above.
        // daysElapsed = 0  → placed today
        // daysElapsed = N  → placed N day-boundaries ago  (1 ≤ N ≤ 7)
        // Initial value of 7 handles the "≥7 days" case when no break fires.
        status.daysElapsed = 7;
        for (uint8 i = 0; i < 8; i++) {
            if (heights[i] == 0) {
                // No snapshot exists for day i — pool is younger than i days old.
                status.daysElapsed = i;
                break;
            }
            if (info.orderHeight >= heights[i]) {
                status.daysElapsed = i;
                break;
            }
        }
        status.sevenDaysPassed = heights[7] > 0 && info.orderHeight < heights[7];
    }

    /// @notice Return the estimated unsold token0 remaining in an open maker order, and the
    ///         compensation amount (token1 deduction) the order owes to earlier makers.
    ///
    /// @param tokenId  ERC-721 token ID of the maker order.
    function getOrderToken0AndCompensation(uint256 tokenId)
        external view returns (OrderAmounts memory amounts)
    {
        IOrderManagerExtra.MakerOrderInfo memory meta = orderManager.getMakerOrder(tokenId);
        UnibuyPoolKey memory key = orderManager.poolKeys(meta.poolId);
        UnibuyPoolId id = key.toId();

        OrderInfo memory info =
            poolManager.getOrderInfo(id, address(orderManager), meta.tickLower, meta.tickUpper, bytes32(tokenId));
        amounts.compensation = info.amountDeduction;

        if (info.liquidity == 0) return amounts; // order does not exist

        (uint160 sqrtPriceX96, int24 currentTick,,,,,) = poolManager.getSlot0(id);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(meta.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(meta.tickUpper);

        if (currentTick >= meta.tickUpper) {
            // Fully crossed — all token0 was sold.
            amounts.amount0Remaining = 0;
        } else if (sqrtPriceX96 <= sqrtLower) {
            // Price at or below tickLower — order not yet touched.
            amounts.amount0Remaining =
                SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, info.liquidity, false);
        } else {
            // Price inside the order range — unsold portion from current price to tickUpper.
            amounts.amount0Remaining =
                SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, info.liquidity, false);
        }
    }

    /// @notice Estimate the settlement deltas (token0 back + net token1) if the maker order
    ///         were closed at the current block state.
    ///
    ///         For fully-crossed orders the token1 estimate is derived from the clearanceList
    ///         entry at tickUpper.  For active or uncrossed orders the token0 refund is derived
    ///         from SqrtPriceMath; any in-progress token1 from the active range is included as
    ///         a proportional share of ticks[tickLower].amountReceived.
    ///         Multi-range orders (when tickLower..tickUpper spans several initialised ticks)
    ///         may produce approximate token1 estimates.
    ///
    /// @param tokenId  ERC-721 token ID of the maker order.
    function simulateCloseOrder(uint256 tokenId)
        external view returns (SimulatedClose memory result)
    {
        IOrderManagerExtra.MakerOrderInfo memory meta = orderManager.getMakerOrder(tokenId);
        UnibuyPoolId id = orderManager.poolKeys(meta.poolId).toId();

        OrderInfo memory info =
            poolManager.getOrderInfo(id, address(orderManager), meta.tickLower, meta.tickUpper, bytes32(tokenId));
        if (info.liquidity == 0) return result; // order does not exist

        (uint256 t0, uint256 t1) = _computeSettlement(
            id, meta.tickLower, meta.tickUpper, info.liquidity, info.orderHeight
        );

        uint96 deduction = info.amountDeduction;
        if (t1 >= uint256(deduction)) {
            result.delta1 = int128(int256(t1 - uint256(deduction)));
        } else {
            result.delta1 = -int128(int256(uint256(deduction) - t1));
        }
        result.delta0 = int128(int256(t0));
    }

    /// @notice Return comprehensive information about a maker NFT order combining NFT-level,
    ///         router-level, pool-key, and pool-level state in a single call.
    ///
    /// @param tokenId  ERC-721 token ID of the maker order.
    function getFullOrderInfo(uint256 tokenId)
        external view returns (FullOrderInfo memory info)
    {
        info.owner = orderManager.ownerOf(tokenId);

        IOrderManagerExtra.MakerOrderInfo memory meta = orderManager.getMakerOrder(tokenId);
        info.poolId          = meta.poolId;
        info.tickLower       = meta.tickLower;
        info.tickUpper       = meta.tickUpper;
        info.tickLowerMirror = meta.tickLowerMirror;
        info.tickUpperMirror = meta.tickUpperMirror;
        info.chained         = meta.chained;
        info.autoClose       = meta.autoClose;

        UnibuyPoolKey memory poolKey = orderManager.poolKeys(meta.poolId);
        info.poolKey = poolKey;
        UnibuyPoolId id = poolKey.toId();

        // Pool-level order state
        OrderInfo memory poolOrderInfo =
            poolManager.getOrderInfo(id, address(orderManager), meta.tickLower, meta.tickUpper, bytes32(tokenId));
        info.liquidity       = poolOrderInfo.liquidity;
        info.orderHeight     = poolOrderInfo.orderHeight;
        info.amountDeduction = poolOrderInfo.amountDeduction;

        // Derived status
        (, int24 currentTick,,,,,) = poolManager.getSlot0(id);
        info.fullyCrossed = currentTick >= meta.tickUpper;

        uint32[8] memory heights = poolManager.getSlot1Heights(id);
        info.daysElapsed = 7; // default: ≥7 days
        for (uint8 i = 0; i < 8; i++) {
            if (heights[i] == 0) {
                info.daysElapsed = i;
                break;
            }
            if (poolOrderInfo.orderHeight >= heights[i]) {
                info.daysElapsed = i;
                break;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers for clearanceList storage reads
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Compute gross token0 / token1 amounts for an order at current state (before deduction).
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
            // Fully crossed — all token0 sold.
            (bool found, uint256 t1) =
                _readClearanceSettlement(id, tickUpper, liquidity, orderHeight, currentPoolHeight);
            if (found) token1 = t1;
        } else if (sqrtPriceX96 <= sqrtLower) {
            // Not yet crossed — full token0 refund.
            token0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else {
            // Active range — partial token0 + proportional token1.
            token0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            (uint128 liqGross,,uint96 amtReceived,,,, ) = poolManager.getTickInfo(id, tickLower);
            if (liqGross > 0 && amtReceived > 0) {
                token1 = FullMath.mulDiv(liquidity, amtReceived, liqGross);
            }
        }
    }

    /// @dev Compute the storage slots for a tick's clearanceList (bytes32[]).
    ///      Layout mirrors StateLibrary: tickBase = keccak256(tick, ticks_mapping_slot)
    ///                                   clearanceList length at tickBase + 2
    ///                                   clearanceList data at keccak256(tickBase + 2)
    function _clearanceListSlots(UnibuyPoolId id, int24 tick)
        private pure
        returns (bytes32 lengthSlot, bytes32 dataStart)
    {
        bytes32 stateSlot       = keccak256(abi.encode(UnibuyPoolId.unwrap(id), StateLibrary.POOLS_SLOT));
        bytes32 ticksMappingSlot = bytes32(uint256(stateSlot) + StateLibrary.TICKS_OFFSET);
        bytes32 tickBase        = keccak256(abi.encode(int256(tick), ticksMappingSlot));
        lengthSlot              = bytes32(uint256(tickBase) + 2);
        dataStart               = keccak256(abi.encode(lengthSlot));
    }

    /// @dev Resolve a 24-bit stored crossHeight to uint32 using current poolHeight's high byte.
    ///      Mirrors ClearanceList._resolvedCrossHeight.
    function _resolvedCrossHeight(uint24 ch24, uint32 currentPoolHeight)
        private pure returns (uint32 h)
    {
        h = (currentPoolHeight & 0xFF000000) | uint32(ch24);
        if (h > currentPoolHeight) h -= 0x01000000;
    }

    /// @dev Binary-search the clearanceList at `tick` for the first entry whose resolved
    ///      crossHeight is >= `orderHeight`.  If found, compute the proportional token1
    ///      earned by the order (before deduction).
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

        // Binary search for first index with resolvedCrossHeight >= orderHeight.
        uint256 lo = 0;
        uint256 hi = listLength;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            bytes32 midPacked = poolManager.extsload(bytes32(uint256(dataStart) + mid));
            uint24  ch24      = uint24(uint256(midPacked) & 0xFFFFFF);
            uint32  h         = _resolvedCrossHeight(ch24, currentPoolHeight);
            if (h < orderHeight) { lo = mid + 1; } else { hi = mid; }
        }
        if (lo >= listLength) return (false, 0);

        // Decode the found entry.
        // ClearanceList packing: bits[255:128]=liquiditySold, bits[127:32]=amountReceived,
        //                         bits[31:24]=gap, bits[23:0]=crossHeight24.
        bytes32 packed = poolManager.extsload(bytes32(uint256(dataStart) + lo));
        uint128 liquiditySold  = uint128(uint256(packed) >> 128);
        uint96  amountReceived = uint96((uint256(packed) >> 32) & type(uint96).max);

        if (liquiditySold == 0) return (false, 0);

        token1Out = FullMath.mulDiv(orderLiquidity, amountReceived, liquiditySold);
        found = true;
    }
}
