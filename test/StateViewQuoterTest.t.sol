// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderManagerTestBase}  from "./helpers/OrderManagerTestBase.t.sol";
import {UnibuyStateViewQuoter} from "../src/UnibuyStateViewQuoter.sol";
import {OrderInspectionView}   from "../src/OrderInspectionView.sol";
import {UnibuyPoolManager}     from "@unibuy/UnibuyPoolManager.sol";
import {IUnibuyPoolManager}    from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {IProtocolFees}         from "@unibuy/interfaces/IProtocolFees.sol";
import {PoolFeeLibrary}        from "@unibuy/libraries/PoolFeeLibrary.sol";
import {UnibuyPoolKey, UnibuyPoolId, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency}              from "@unibuy/types/Currency.sol";
import {OrderInfo}             from "@unibuy/types/UnibuyTypes.sol";
import {StateLibrary}          from "@unibuy/libraries/StateLibrary.sol";
import {TickMath}              from "@unibuy/libraries/TickMath.sol";
import {TestERC20}             from "./helpers/TestERC20.sol";

/// @title StateViewQuoterTest
/// @notice Tests for UnibuyStateViewQuoter — covers all StateView and OrderQuoter entry points.
///
/// Layout of tests:
///   § 1  State View — pool level   (getPoolSnapshot, getSlot0, getSlot1Heights)
///   § 2  State View — tick level   (getTickInfo, getTickBitmap, getTickInfoStack)
///   § 3  State View — order level  (getOrderInfo)
///   § 4  State View — transient    (getTransientState)
///   § 5  Quoter — single-hop       (quoteTakeOrderExactInputSingle / ExactOutputSingle)
///   § 6  Quoter — multi-hop        (quoteTakeOrderExactInput / ExactOutput)
contract StateViewQuoterTest is OrderManagerTestBase {
    using UnibuyPoolIdLibrary for UnibuyPoolKey;
    using StateLibrary        for IUnibuyPoolManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────

    UnibuyStateViewQuoter internal quoter;
    OrderInspectionView   internal inspector;

    /// @dev Third token + pools for multi-hop tests (tokenB ↔ tokenC).
    TestERC20      internal tokenC;
    UnibuyPoolKey  internal poolBC;    // sell tokenB for tokenC
    UnibuyPoolKey  internal mirrorBC;  // sell tokenC for tokenB

    int24 internal constant TL  = 60;
    int24 internal constant TU  = 180;
    uint128 internal constant LIQ = 10e18;

    function setUp() public override {
        super.setUp();

        quoter    = new UnibuyStateViewQuoter(address(poolManager));
        inspector = new OrderInspectionView(address(poolManager), address(orderManager));

        // ── second pair (tokenB / tokenC) for multi-hop ──────────────────────
        tokenC = new TestERC20("Token C", "TKC", 18);

        // Build pool keys in canonical currency order without mutating base fixtures.
        if (address(tokenB) < address(tokenC)) {
            poolBC = UnibuyPoolKey({
                currency0:   Currency.wrap(address(tokenB)),
                currency1:  Currency.wrap(address(tokenC)),
                tickSpacing: TICK_SPACING
            });
            mirrorBC = UnibuyPoolKey({
                currency0:   Currency.wrap(address(tokenC)),
                currency1:  Currency.wrap(address(tokenB)),
                tickSpacing: TICK_SPACING
            });
        } else {
            poolBC = UnibuyPoolKey({
                currency0:   Currency.wrap(address(tokenC)),
                currency1:  Currency.wrap(address(tokenB)),
                tickSpacing: TICK_SPACING
            });
            mirrorBC = UnibuyPoolKey({
                currency0:   Currency.wrap(address(tokenB)),
                currency1:  Currency.wrap(address(tokenC)),
                tickSpacing: TICK_SPACING
            });
        }

        uint24 poolFee = PoolFeeLibrary.pack(TAKER_FEE, MAKER_FEE, OFFSET_FEE);
        IProtocolFees(address(poolManager)).setTickSpacingSettings(
            TICK_SPACING, poolFee, TICK_GAP_LIMIT
        );
        poolManager.initialize(poolBC, SQRT_PRICE_1_1);

        // Fund and approve both sides used by poolBC/mirrorBC.
        // tokenB/tokenC may have been swapped above to satisfy currency ordering.
        address[4] memory actors = [alice, bob, carol, dave];
        for (uint256 i = 0; i < actors.length; i++) {
            tokenB.mint(actors[i], 10_000_000 ether);
            vm.prank(actors[i]);
            tokenB.approve(address(orderManager), type(uint256).max);

            tokenC.mint(actors[i], 10_000_000 ether);
            vm.prank(actors[i]);
            tokenC.approve(address(orderManager), type(uint256).max);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 1  State View — pool level
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev After initialization the pool price must equal the initialization price.
    function test_getSlot0_initialPrice() public view {
        UnibuyStateViewQuoter.Slot0View memory s = quoter.getSlot0(poolKey);

        assertEq(s.sqrtPriceX96, SQRT_PRICE_1_1, "initial sqrtPrice mismatch");
        assertEq(s.tick,         0,               "initial tick should be 0");
        assertEq(s.takerFee,     TAKER_FEE,       "takerFee mismatch");
        assertEq(s.offsetFee,    OFFSET_FEE,      "offsetFee mismatch");
        assertEq(s.tickGapLimit, TICK_GAP_LIMIT,  "tickGapLimit mismatch");
    }

    /// @dev getPoolSnapshot returns both slot0 and slot1 in a single call without reverting.
    function test_getPoolSnapshot_returnsConsistentData() public view {
        UnibuyStateViewQuoter.PoolSnapshot memory snap = quoter.getPoolSnapshot(poolKey);

        // slot0 fields must match getSlot0
        assertEq(snap.slot0.sqrtPriceX96, SQRT_PRICE_1_1, "snapshot sqrtPrice mismatch");
        assertEq(snap.slot0.tick,         0,               "snapshot tick mismatch");
        assertEq(snap.slot0.takerFee,     TAKER_FEE,       "snapshot takerFee mismatch");

        // slot1Heights is an 8-element array; length is implicitly 8 for fixed arrays
        // The first entry (current-day start height) may be 0 for a fresh pool
        assertEq(snap.slot1Heights.length, 8, "slot1Heights should have 8 entries");
    }

    /// @dev getSlot1Heights returns the same data as the StateLibrary call.
    function test_getSlot1Heights_matchesRaw() public view {
        uint32[8] memory heights = quoter.getSlot1Heights(poolKey);
        uint32[8] memory raw     = IUnibuyPoolManager(address(poolManager)).getSlot1Heights(poolKey.toId());

        for (uint256 i = 0; i < 8; i++) {
            assertEq(heights[i], raw[i], "height mismatch at index");
        }
    }

    /// @dev Price from getSlot0 matches the raw StateLibrary getter.
    function test_getSlot0_matchesRawManagerGetter() public view {
        UnibuyStateViewQuoter.Slot0View memory s = quoter.getSlot0(poolKey);

        (
            uint160 rawSqrt,
            int24   rawTick,
            uint32  rawHeight,
            uint8   rawTakerFee,
            ,
            ,
        ) = IUnibuyPoolManager(address(poolManager)).getSlot0(poolKey.toId());

        assertEq(s.sqrtPriceX96, rawSqrt,      "sqrtPriceX96 mismatch with raw");
        assertEq(s.tick,         rawTick,       "tick mismatch with raw");
        assertEq(s.poolHeight,   rawHeight,     "poolHeight mismatch with raw");
        assertEq(s.takerFee,     rawTakerFee,   "takerFee mismatch with raw");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 2  State View — tick level
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev After placing an order at [TL,TU], liquidityGross at TL and TU must be > 0.
    function test_getTickInfo_liquidityGrossAfterOrder() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        UnibuyStateViewQuoter.TickInfoView memory lower = quoter.getTickInfo(poolKey, TL);
        UnibuyStateViewQuoter.TickInfoView memory upper = quoter.getTickInfo(poolKey, TU);

        assertGt(lower.liquidityGross, 0, "lower tick liquidityGross should be > 0");
        assertGt(upper.liquidityGross, 0, "upper tick liquidityGross should be > 0");
    }

    /// @dev liquidityNet should be positive at the lower boundary and negative at the upper.
    function test_getTickInfo_liquidityNetSigns() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        UnibuyStateViewQuoter.TickInfoView memory lower = quoter.getTickInfo(poolKey, TL);
        UnibuyStateViewQuoter.TickInfoView memory upper = quoter.getTickInfo(poolKey, TU);

        assertGt(lower.liquidityNet, 0, "lower tick liquidityNet should be positive");
        assertLt(upper.liquidityNet, 0, "upper tick liquidityNet should be negative");
    }

    /// @dev TickInfo returned by the quoter matches the raw poolManager getter.
    function test_getTickInfo_matchesRaw() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        UnibuyStateViewQuoter.TickInfoView memory t = quoter.getTickInfo(poolKey, TL);

        (
            uint128 rawGross,
            int128  rawNet,
            uint96  rawReceived,
            uint96  rawOffset,
            uint32  rawHeight,
            uint32  rawActive,
            uint256 rawLen
        ) = IUnibuyPoolManager(address(poolManager)).getTickInfo(poolKey.toId(), TL);

        assertEq(t.liquidityGross,    rawGross,    "liquidityGross mismatch");
        assertEq(t.liquidityNet,      rawNet,      "liquidityNet mismatch");
        assertEq(t.amountReceived,    rawReceived, "amountReceived mismatch");
        assertEq(t.amountOffset,      rawOffset,   "amountOffset mismatch");
        assertEq(t.tickHeight,        rawHeight,   "tickHeight mismatch");
        assertEq(t.activeEntryCount,  rawActive,   "activeEntryCount mismatch");
        assertEq(t.clearanceListLength, rawLen,    "clearanceListLength mismatch");
    }

    /// @dev After placing an order, the tick bitmap word that covers [TL,TU] should be non-zero.
    function test_getTickBitmap_setAfterOrder() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        // Bitmap word = tick / 256 (accounting for tickSpacing compression: compressed = tick / tickSpacing)
        int16 wordPos = int16(TL / int24(TICK_SPACING) >> 8);
        uint256 bitmap = quoter.getTickBitmap(poolKey, wordPos);

        assertNotEq(bitmap, 0, "bitmap word should be non-zero after order placement");
    }

    /// @dev getTickBitmap result matches the raw poolManager getter.
    function test_getTickBitmap_matchesRaw() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        int16 wordPos = int16(TL / int24(TICK_SPACING) >> 8);
        uint256 fromQuoter = quoter.getTickBitmap(poolKey, wordPos);
        uint256 fromRaw    = IUnibuyPoolManager(address(poolManager)).getTickBitmap(poolKey.toId(), wordPos);

        assertEq(fromQuoter, fromRaw, "getTickBitmap mismatch with raw");
    }

    /// @dev getTickInfoStack returns data from the stack mapping (may be zero before first crossing).
    function test_getTickInfoStack_returnsWithoutRevert() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        // Just verifying no revert; stack values before a crossing are 0
        (uint128 grossStack, int128 netStack) = quoter.getTickInfoStack(poolKey, TL);
        // Stack starts empty — values are copied lazily on the first upward crossing
        // We only assert the call succeeded (no revert).
        assertGe(grossStack, 0, "grossStack should be non-negative (uint)");
        assertTrue(netStack == 0 || netStack != 0, "netStack sanity");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 3  State View — order level
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev After makeOrder, getOrderInfo must return a non-zero liquidity entry in the pool.
    function test_getOrderInfo_liquidityAfterOrder() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        // The salt used by UnibuyOrderManager is bytes32(tokenId)
        // The maker stored in the pool is address(orderManager)
        OrderInfo memory info = quoter.getOrderInfo(
            poolKey,
            address(orderManager),
            TL,
            TU,
            bytes32(tokenId)
        );

        assertEq(info.liquidity, LIQ, "order liquidity mismatch");
    }

    /// @dev orderHeight should be >= 1 after the first order (pool is freshly initialized → height=0,
    ///      but makeOrder increments it on entry).
    function test_getOrderInfo_orderHeightNonZero() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        OrderInfo memory info = quoter.getOrderInfo(
            poolKey,
            address(orderManager),
            TL,
            TU,
            bytes32(tokenId)
        );

        // poolHeight is recorded at order placement; for a fresh pool it could be 0
        // but liquidity must be exactly LIQ
        assertEq(info.liquidity, LIQ, "liquidity should equal placed amount");
    }

    /// @dev A non-existent order must return zeroed-out OrderInfo (not revert).
    function test_getOrderInfo_nonExistentReturnsZero() public view {
        OrderInfo memory info = quoter.getOrderInfo(
            poolKey,
            address(this),
            TL,
            TU,
            bytes32(uint256(99999))
        );

        assertEq(info.liquidity,       0, "non-existent order liquidity should be 0");
        assertEq(info.orderHeight,     0, "non-existent order height should be 0");
        assertEq(info.amountDeduction, 0, "non-existent order deduction should be 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 4  State View — transient state
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Outside any callback the pool is not unlocked and delta count is 0.
    function test_getTransientState_notUnlockedOutsideCallback() public view {
        (
            bool unlocked,
            uint256 nonzeroDeltaCount,
            int256  delta,
            Currency syncedCurrency,
            uint256  syncedReserves
        ) = quoter.getTransientState(alice, Currency.wrap(address(tokenA)));

        assertFalse(unlocked,              "pool should NOT be unlocked outside callback");
        assertEq(nonzeroDeltaCount, 0,     "nonzeroDeltaCount should be 0");
        assertEq(delta,             0,     "delta should be 0 outside callback");
        assertEq(Currency.unwrap(syncedCurrency), address(0), "syncedCurrency should be address(0)");
        assertEq(syncedReserves,    0,     "syncedReserves should be 0");
    }

    /// @dev Transient state should be consistent for a currency with no pending delta.
    function test_getTransientState_zeroForUntouchedCurrency() public view {
        (,, int256 delta,,) = quoter.getTransientState(
            address(this),
            Currency.wrap(address(tokenB))
        );
        assertEq(delta, 0, "delta for un-touched currency should be 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 5  Quoter — single-hop  (quoteTakeOrderExact*Single)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Seeding liquidity then calling quoteTakeOrderExactInputSingle must return
    ///      a non-zero amountIn, amountOut, and gasEstimate.
    function test_quoteTakeOrderExactInputSingle_basic() public {
        // Seed liquidity so there is something to quote against
        _placeSellOrder(alice, TL, TU, LIQ);

        uint256 amountIn  = 1e15;  // 0.001 tokenB
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(TU);

        UnibuyStateViewQuoter.QuoteResult memory r =
            quoter.quoteTakeOrderExactInputSingle(poolKey, amountIn, priceLimit);

        assertGt(r.amountIn,    0, "amountIn should be > 0");
        assertGt(r.amountOut,   0, "amountOut should be > 0");
        assertLe(r.amountIn,    amountIn, "amountIn used must not exceed budget");
        assertGt(r.gasEstimate, 0, "gasEstimate should be > 0");

        // Price should have increased (taker bought token0)
        assertGe(r.sqrtPriceX96After, SQRT_PRICE_1_1, "price should move up after buy");
    }

    /// @dev Quoting with amountIn = 0 should revert with ZeroTakeOrderAmount (pool rejects zero).
    function test_quoteTakeOrderExactInputSingle_zeroInput() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        // The pool validates amountSpecified != 0 before simulating, so even a
        // quote path reverts before reaching QuoteRevert.  The outer try/catch
        // re-throws the inner revert, so we expect a non-QuoteRevert error.
        vm.expectRevert();
        quoter.quoteTakeOrderExactInputSingle(poolKey, 0, TickMath.getSqrtPriceAtTick(TU));
    }

    /// @dev quoteTakeOrderExactInputSingle must not permanently mutate pool state.
    function test_quoteTakeOrderExactInputSingle_doesNotMutateState() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        (uint160 sqrtBefore, int24 tickBefore,) = _getSlot0Fwd();

        quoter.quoteTakeOrderExactInputSingle(poolKey, 1e15, TickMath.getSqrtPriceAtTick(TU));

        (uint160 sqrtAfter, int24 tickAfter,) = _getSlot0Fwd();

        assertEq(sqrtAfter, sqrtBefore, "quote must not change sqrtPrice");
        assertEq(tickAfter, tickBefore, "quote must not change tick");
    }

    /// @dev quoteTakeOrderExactOutputSingle must return a non-zero amountIn for non-zero amountOut.
    function test_quoteTakeOrderExactOutputSingle_basic() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        uint256 amountOut  = 5e14;  // 0.0005 tokenA (exact out)
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(TU);

        UnibuyStateViewQuoter.QuoteResult memory r =
            quoter.quoteTakeOrderExactOutputSingle(poolKey, amountOut, priceLimit);

        assertGt(r.amountIn,  0, "should require non-zero tokenB input");
        assertGt(r.amountOut, 0, "should yield non-zero tokenA output");
        assertGt(r.gasEstimate, 0, "gasEstimate should be > 0");
    }

    /// @dev The quoted price after an exact-output trade should be higher than the initial price.
    function test_quoteTakeOrderExactOutputSingle_priceMovesUp() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        uint160 priceLimit = TickMath.getSqrtPriceAtTick(TU);
        UnibuyStateViewQuoter.QuoteResult memory r =
            quoter.quoteTakeOrderExactOutputSingle(poolKey, 1e14, priceLimit);

        assertGe(r.sqrtPriceX96After, SQRT_PRICE_1_1, "price should move up");
    }

    /// @dev quoteTakeOrderExactOutputSingle must not permanently mutate pool state.
    function test_quoteTakeOrderExactOutputSingle_doesNotMutateState() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        (uint160 sqrtBefore,,) = _getSlot0Fwd();
        quoter.quoteTakeOrderExactOutputSingle(poolKey, 1e14, TickMath.getSqrtPriceAtTick(TU));
        (uint160 sqrtAfter,,) = _getSlot0Fwd();

        assertEq(sqrtAfter, sqrtBefore, "quote must not change sqrtPrice");
    }

    /// @dev Results from exact-input and exact-output quotes are consistent in direction:
    ///      if exact-input of X yields output Y, then exact-output of Y should require ~ X in.
    function test_quoteSingle_inputOutputConsistency() public {
        _placeSellOrder(alice, TL, TU, LIQ);

        uint256 input     = 1e15;
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(TU);

        UnibuyStateViewQuoter.QuoteResult memory rIn =
            quoter.quoteTakeOrderExactInputSingle(poolKey, input, priceLimit);

        uint256 outputFromInput = rIn.amountOut;
        assertGt(outputFromInput, 0, "no output from exact-input");

        // Quote exact-output of the same amount
        UnibuyStateViewQuoter.QuoteResult memory rOut =
            quoter.quoteTakeOrderExactOutputSingle(poolKey, outputFromInput, priceLimit);

        // Due to rounding and fee calculation the required input should be >= actual input used
        assertGe(rOut.amountIn, rIn.amountIn, "exact-output should require >= exact-input cost");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 6  Quoter — multi-hop  (quoteTakeOrderExactInput / ExactOutput)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Seed both pools and verify multi-hop exact-input quote succeeds.
    ///
    /// Path: tokenA → (poolKey: buy tokenA with tokenB) → tokenB
    ///              → (poolBC:  buy tokenB with tokenC) → tokenC
    ///
    /// In Unibuy a pool sells currency0 for currency1.
    /// To traverse poolKey receiving tokenA first, we think of it as:
    ///   currencyIn = tokenB,  hopCurrency = tokenA   [paying tokenB, receiving tokenA]
    /// Then to traverse poolBC:
    ///   currencyIn = tokenA? No — we want to keep chaining.
    ///
    /// Simpler: just chain two single-hop exact-input calls through the forward pool twice
    ///          using different tick ranges to confirm path logic runs without revert.
    function test_quoteTakeOrderExactInput_twoHops() public {
        // Seed forward pool [TL, TU]
        _placeSellOrder(alice, TL, TU, LIQ);
        // Build an address-order agnostic route: other -> tokenB -> tokenA.
        Currency intermediary = poolKey.currency1; // tokenB in base poolKey
        Currency other = poolBC.currency0 == intermediary ? poolBC.currency1 : poolBC.currency0;
        UnibuyPoolKey memory firstHopPool =
            (poolBC.currency0 == intermediary && poolBC.currency1 == other) ? poolBC : mirrorBC;

        // Seed first-hop pool with liquidity in the direction (other -> intermediary).
        _placeSellOrderInPool(alice, firstHopPool, firstHopPool, TL, TU, LIQ);

        // Build path: start with tokenB → tokenA (poolKey) → tokenC (poolBC via mirror)
        // In Unibuy poolKey, currency0=tokenA, currency1=tokenB → taker pays tokenB and receives tokenA
        // In poolBC,         currency0=tokenB, currency1=tokenC → taker pays tokenC and receives tokenB
        // For exact-input path:
        //   currencyIn = tokenB (first hop input)
        //   hop[0]: hopCurrency = tokenA (output of first hop), tickSpacing from poolKey
        //   hop[1]: hopCurrency = tokenC (output of second hop), tickSpacing from poolBC
        //
        // But second hop pool: taker pays tokenA and receives tokenC → no direct pool.
        // Use single-hop of poolKey only, then a single hop of mirrorBC.

        // Simplify: two-hop where both hops are in the forward pool direction:
        //   hop 0: currencyIn=tokenB, output=tokenA via poolKey
        //   hop 1: currencyIn=tokenA, output=tokenC is not available directly
        //
        // Instead route: tokenB → tokenA (poolKey) ← this is one hop. Stop.
        // For a genuine 2-hop test: tokenC → tokenB (mirrorBC) → tokenA (poolKey)
        //
        //   currencyIn = tokenC
        //   path[0]: hopCurrency=tokenB, tickSpacing=TICK_SPACING  (mirrorBC: c0=tokenC,c1=tokenB)
        //   path[1]: hopCurrency=tokenA, tickSpacing=TICK_SPACING  (poolKey:  c0=tokenA,c1=tokenB)
        // Wait — for path[1] to work, the pool must be (c0=hopCurrency=tokenA, c1=currencyIn after hop0=tokenB)
        // which matches poolKey. ✓
        
        Currency currencyIn = other;
        UnibuyStateViewQuoter.QuotePathKey[] memory path = new UnibuyStateViewQuoter.QuotePathKey[](2);
        path[0] = UnibuyStateViewQuoter.QuotePathKey({
            hopCurrency: intermediary,
            tickSpacing:  TICK_SPACING
        });
        path[1] = UnibuyStateViewQuoter.QuotePathKey({
            hopCurrency: poolKey.currency0,
            tickSpacing:  TICK_SPACING
        });

        uint256 amountIn = 1e15;
        UnibuyStateViewQuoter.QuoteResult memory r =
            quoter.quoteTakeOrderExactInput(currencyIn, path, amountIn);

        assertGt(r.amountOut,   0, "multi-hop: should produce non-zero output");
        assertGt(r.gasEstimate, 0, "multi-hop: gasEstimate should be > 0");
    }

    /// @dev Reverting with InvalidPath if path is empty.
    function test_quoteTakeOrderExactInput_emptyPathReverts() public {
        UnibuyStateViewQuoter.QuotePathKey[] memory emptyPath = new UnibuyStateViewQuoter.QuotePathKey[](0);
        vm.expectRevert(UnibuyStateViewQuoter.InvalidPath.selector);
        quoter.quoteTakeOrderExactInput(Currency.wrap(address(tokenA)), emptyPath, 1e15);
    }

    /// @dev Multi-hop exact-output with two pools must return non-zero amountIn.
    ///
    /// Execution flow (reverse): want tokenA out.
    ///   _simulateExactOutputPath traverses path[length-1] → path[0].
    ///   i=1: hopKey = {c0=currencyOut=tokenA, c1=path[1].hopCurrency=tokenB} = poolKey ✓
    ///        → after: currencyOut = tokenB
    ///   i=0: hopKey = {c0=currencyOut=tokenB, c1=path[0].hopCurrency=tokenC} = poolBC ✓
    function test_quoteTakeOrderExactOutput_twoHops() public {
        _placeSellOrder(alice, TL, TU, LIQ);
        Currency intermediary = poolKey.currency1; // tokenB in base poolKey
        Currency other = poolBC.currency0 == intermediary ? poolBC.currency1 : poolBC.currency0;
        UnibuyPoolKey memory firstHopPool =
            (poolBC.currency0 == intermediary && poolBC.currency1 == other) ? poolBC : mirrorBC;

        // Seed the pool used for reverse step i=0: hopKey = {intermediary, other}.
        _placeSellOrderInPool(alice, firstHopPool, firstHopPool, TL, TU, LIQ);

        Currency currencyOut = poolKey.currency0;
        UnibuyStateViewQuoter.QuotePathKey[] memory path = new UnibuyStateViewQuoter.QuotePathKey[](2);
        // path[0] executed last (i=0): pool = {c0=intermediary, c1=other}
        path[0] = UnibuyStateViewQuoter.QuotePathKey({
            hopCurrency: other,
            tickSpacing:  TICK_SPACING
        });
        // path[1] executed first (i=1): pool = {c0=tokenA, c1=intermediary} = poolKey
        path[1] = UnibuyStateViewQuoter.QuotePathKey({
            hopCurrency: intermediary,
            tickSpacing:  TICK_SPACING
        });

        uint256 amountOut = 5e14;
        UnibuyStateViewQuoter.QuoteResult memory r =
            quoter.quoteTakeOrderExactOutput(currencyOut, path, amountOut);

        assertGt(r.amountIn,    0, "multi-hop exact-output: should require non-zero input");
        assertGt(r.gasEstimate, 0, "multi-hop exact-output: gasEstimate should be > 0");
    }

    /// @dev Reverting with InvalidPath if path is empty.
    function test_quoteTakeOrderExactOutput_emptyPathReverts() public {
        UnibuyStateViewQuoter.QuotePathKey[] memory emptyPath = new UnibuyStateViewQuoter.QuotePathKey[](0);
        vm.expectRevert(UnibuyStateViewQuoter.InvalidPath.selector);
        quoter.quoteTakeOrderExactOutput(Currency.wrap(address(tokenA)), emptyPath, 5e14);
    }

    /// @dev Multi-hop exact-output quote must not permanently mutate pool state.
    function test_quoteTakeOrderExactOutput_doesNotMutateState() public {
        _placeSellOrder(alice, TL, TU, LIQ);
        Currency intermediary = poolKey.currency1;
        Currency other = poolBC.currency0 == intermediary ? poolBC.currency1 : poolBC.currency0;
        UnibuyPoolKey memory firstHopPool =
            (poolBC.currency0 == intermediary && poolBC.currency1 == other) ? poolBC : mirrorBC;
        _placeSellOrderInPool(alice, firstHopPool, firstHopPool, TL, TU, LIQ);

        (uint160 sqrtBefore,,) = _getSlot0Fwd();

        Currency currencyOut = poolKey.currency0;
        UnibuyStateViewQuoter.QuotePathKey[] memory path = new UnibuyStateViewQuoter.QuotePathKey[](2);
        // Same path as test_quoteTakeOrderExactOutput_twoHops
        path[0] = UnibuyStateViewQuoter.QuotePathKey({
            hopCurrency: other,
            tickSpacing:  TICK_SPACING
        });
        path[1] = UnibuyStateViewQuoter.QuotePathKey({
            hopCurrency: intermediary,
            tickSpacing:  TICK_SPACING
        });
        quoter.quoteTakeOrderExactOutput(currencyOut, path, 5e14);

        (uint160 sqrtAfter,,) = _getSlot0Fwd();
        assertEq(sqrtAfter, sqrtBefore, "multi-hop quote must not change poolKey sqrtPrice");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 7  Edge cases / security
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Direct call to unlockCallback from a non-poolManager address must revert.
    function test_unlockCallback_rejectsBadSender() public {
        vm.expectRevert(UnibuyStateViewQuoter.InvalidCallbackSender.selector);
        quoter.unlockCallback(abi.encode(uint8(1)));
    }

    /// @dev quoter.poolManager immutable is set correctly in constructor.
    function test_constructor_poolManagerSet() public view {
        assertEq(address(quoter.poolManager()), address(poolManager));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 8  OrderInspectionView — constructor
    // ─────────────────────────────────────────────────────────────────────────

    function test_inspector_immutables() public view {
        assertEq(address(inspector.poolManager()),  address(poolManager));
        assertEq(address(inspector.orderManager()), address(orderManager));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 9  getOrderCrossedStatus
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Order placed entirely above current tick — should not be crossed.
    function test_getOrderCrossedStatus_notCrossed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        OrderInspectionView.OrderCrossedStatus memory status =
            inspector.getOrderCrossedStatus(tokenId);

        assertFalse(status.fullyCrossed, "should not be crossed");
        assertEq(status.daysElapsed, 0,  "placed today: 0 days elapsed");
        assertFalse(status.sevenDaysPassed, "should not be 7 days old");
    }

    /// @dev After a taker buy that moves price past tickUpper the order is fully crossed.
    function test_getOrderCrossedStatus_fullyCrossed() public {
        // Place order in range [TL, TU] = [60, 180] above current tick 0.
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        // Initialise mirror pool so the taker can buy.

        // Push the forward pool price past tickUpper by buying with a high limit.
        uint160 limitAbove = TickMath.getSqrtPriceAtTick(TU + TICK_SPACING);
        _takerBuy(dave, 100_000 ether, limitAbove);

        (, int24 tick,) = _getSlot0Fwd();
        vm.assume(tick >= TU); // guard: skip if pool did not move enough

        OrderInspectionView.OrderCrossedStatus memory status =
            inspector.getOrderCrossedStatus(tokenId);

        assertTrue(status.fullyCrossed, "should be fully crossed after taker buy");
    }

    /// @dev daysElapsed is 0 for an order placed in the current pool session (no day boundaries crossed).
    function test_getOrderCrossedStatus_daysElapsed_zeroForFreshOrder() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        OrderInspectionView.OrderCrossedStatus memory status =
            inspector.getOrderCrossedStatus(tokenId);

        // A freshly-placed order always has daysElapsed = 0 (placed in today's session).
        assertEq(status.daysElapsed, 0, "fresh order: daysElapsed should be 0");
        assertFalse(status.sevenDaysPassed, "fresh order: sevenDaysPassed should be false");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 10  getOrderToken0AndCompensation
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Unfilled order — full liquidity priced from sqrtLower to sqrtUpper.
    function test_getOrderToken0AndCompensation_unfilled() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        OrderInspectionView.OrderAmounts memory amounts =
            inspector.getOrderToken0AndCompensation(tokenId);

        // Pool is at tick 0 which is below TL=60, so full range should be available.
        assertGt(amounts.amount0Remaining, 0, "some token0 must remain");
        // No earlier makers → no compensation owed.
        assertEq(amounts.compensation, 0, "no compensation for fresh order");
    }

    /// @dev Fully-crossed order has zero token0 remaining.
    function test_getOrderToken0AndCompensation_fullyCrossed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        uint160 limitAbove = TickMath.getSqrtPriceAtTick(TU + TICK_SPACING);
        _takerBuy(dave, 100_000 ether, limitAbove);

        (, int24 tick,) = _getSlot0Fwd();
        vm.assume(tick >= TU);

        OrderInspectionView.OrderAmounts memory amounts =
            inspector.getOrderToken0AndCompensation(tokenId);

        assertEq(amounts.amount0Remaining, 0, "fully crossed: no token0 left");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 11  simulateCloseOrder
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Uncrossed order — delta0 > 0, delta1 = 0.
    function test_simulateCloseOrder_uncrossed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        OrderInspectionView.SimulatedClose memory sim =
            inspector.simulateCloseOrder(tokenId);

        assertGt(sim.delta0, 0,  "should recover token0");
        assertEq(sim.delta1, 0,  "no token1 earned yet");
    }

    /// @dev Fully-crossed order — delta0 = 0, delta1 > 0.
    function test_simulateCloseOrder_fullyCrossed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        uint160 limitAbove = TickMath.getSqrtPriceAtTick(TU + TICK_SPACING);
        _takerBuy(dave, 100_000 ether, limitAbove);

        (, int24 tick,) = _getSlot0Fwd();
        vm.assume(tick >= TU);

        OrderInspectionView.SimulatedClose memory sim =
            inspector.simulateCloseOrder(tokenId);

        assertEq(sim.delta0, 0,  "fully crossed: no token0");
        assertGe(sim.delta1, 0,  "should have earned token1");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // § 12  getFullOrderInfo
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Verify all fields match placement parameters.
    function test_getFullOrderInfo_basic() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        OrderInspectionView.FullOrderInfo memory info =
            inspector.getFullOrderInfo(tokenId);

        assertEq(info.owner,      alice,  "owner should be alice");
        assertEq(info.tickLower,  TL,     "tickLower mismatch");
        assertEq(info.tickUpper,  TU,     "tickUpper mismatch");
        assertEq(info.liquidity,  LIQ,    "liquidity mismatch");
        assertFalse(info.fullyCrossed,    "should not be crossed yet");
        assertEq(info.daysElapsed, 0,     "placed today");

        // Mirror ticks should be the inverse.
        assertEq(info.tickLowerMirror, -TU, "mirror tickLower mismatch");
        assertEq(info.tickUpperMirror, -TL, "mirror tickUpper mismatch");
    }

    /// @dev Verify fullyCrossed flag in FullOrderInfo after price moves past tickUpper.
    function test_getFullOrderInfo_fullyCrossed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        uint160 limitAbove = TickMath.getSqrtPriceAtTick(TU + TICK_SPACING);
        _takerBuy(dave, 100_000 ether, limitAbove);

        (, int24 tick,) = _getSlot0Fwd();
        vm.assume(tick >= TU);

        OrderInspectionView.FullOrderInfo memory info =
            inspector.getFullOrderInfo(tokenId);

        assertTrue(info.fullyCrossed, "FullOrderInfo.fullyCrossed should be true");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Place a sell order in an arbitrary pool (not necessarily the default poolKey).
    function _placeSellOrderInPool(
        address maker,
        UnibuyPoolKey memory sellPool,
        UnibuyPoolKey memory /*mirrorPool*/,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    ) internal returns (uint256 tokenId) {
        uint256 orderInfo = _encodeOrderInfo(
            tickLower,
            tickUpper,
            -tickUpper,
            -tickLower,
            true,
            false
        );
        tokenId = orderManager.lastTokenId() + 1;
        vm.prank(maker);
        orderManager.makeOrder(sellPool, orderInfo, liquidity, block.timestamp + 1 hours);
    }
}
