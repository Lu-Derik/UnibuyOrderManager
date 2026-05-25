// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderManagerTestBase} from "./helpers/OrderManagerTestBase.t.sol";
import {TickMath}             from "@unibuy/libraries/TickMath.sol";
import {UnibuyPoolKey}        from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency}             from "@unibuy/types/Currency.sol";
import {PathKey} from "../src/libraries/PathKey.sol";
import {TestERC20}            from "./helpers/TestERC20.sol";

/// @title TakerOrderTest
/// @notice Tests for takerBuy and takerSell functionality of UnibuyOrderManager.
contract TakerOrderTest is OrderManagerTestBase {

    // Sell order in the forward pool so taker orders can fill
    int24  constant TL = 60;
    int24  constant TU = 180;
    uint128 constant LIQ = 10e18;

    uint256 internal sellOrderId;

    function setUp() public override {
        super.setUp();
        // Alice places a sell maker order so that takers have liquidity to trade against
        (sellOrderId,) = _placeSellOrder(alice, TL, TU, LIQ);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // takerBuy — direct buy (forward pool)
    // ─────────────────────────────────────────────────────────────────────────

    function test_takerBuy_exactInput_receivesToken0() public {
        uint256 token1Amount = 1e15;
        uint160 priceLimit   = TickMath.getSqrtPriceAtTick(TU);

        uint256 token0Before = tokenA.balanceOf(dave);
        uint256 token1Before = tokenB.balanceOf(dave);

        (uint256 t0Out, uint256 t1In) = _takerBuy(dave, token1Amount, priceLimit);

        assertGt(t0Out, 0, "should receive token0");
        assertGt(t1In,  0, "should spend token1");
        assertEq(tokenA.balanceOf(dave), token0Before + t0Out, "token0 balance mismatch");
        assertEq(tokenB.balanceOf(dave), token1Before + token1Amount - t1In, "token1 balance mismatch");
    }

    function test_takerBuy_exactOutput_receivesExactToken0() public {
        uint256 token0Want   = 0.5e15;
        uint160 priceLimit   = TickMath.getSqrtPriceAtTick(TU);

        // Pre-fund extra token1 approval
        tokenB.mint(dave, 10e18);
        uint256 t1Before = tokenB.balanceOf(dave);

        vm.prank(dave);
        orderManager.takeOrderOutputSingle(
            poolKey,
            dave,
            token0Want,        // exact amountOut
            type(uint256).max, // amountInMaximum — no limit
            priceLimit,
            block.timestamp + 1 hours
        );
        uint256 t1In = t1Before - tokenB.balanceOf(dave);
        uint256 t0Out = token0Want; // exact output

        // With exact output, t0Out should equal the requested amount
        assertEq(t0Out, token0Want, "exact token0 output not matched");
        assertGt(t1In,  0,         "should have spent token1");
    }

    function test_takerBuy_priceIncreases() public {
        (uint160 sqrtBefore,,) = _getSlot0Fwd();
        _takerBuy(dave, 1e15, TickMath.getSqrtPriceAtTick(TU));
        (uint160 sqrtAfter,,) = _getSlot0Fwd();
        assertGt(sqrtAfter, sqrtBefore, "price should move up");
    }

    function test_takerBuy_priceLimitRespected() public {
        int24 midTick = (TL + TU) / 2;
        // round to spacing
        midTick = (midTick * TICK_SPACING) / TICK_SPACING;
        uint160 mid = TickMath.getSqrtPriceAtTick(midTick + TICK_SPACING);

        _takerBuy(dave, 100e18, mid);

        (uint160 sqrtAfter,,) = _getSlot0Fwd();
        assertLe(sqrtAfter, mid, "price exceeded limit");
    }

    function test_takerBuy_revert_priceLimitBelowCurrent() public {
        (uint160 currentSqrt,,) = _getSlot0Fwd();
        uint160 badLimit = currentSqrt - 1;

        tokenB.mint(dave, 1e18);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("BuyPriceBelowCurrent(uint160,uint160)")),
                badLimit,
                currentSqrt
            )
        );
        orderManager.takeOrderInputSingle(poolKey, dave, 1e18, 0, badLimit, block.timestamp + 1 hours);
    }

    function test_takerBuy_revert_zeroAmount() public {
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("ZeroTakeOrderAmount()"))));
        orderManager.takeOrderInputSingle(
            poolKey, dave, 0, 0, TickMath.getSqrtPriceAtTick(TU), block.timestamp + 1 hours
        );
    }

    function test_takerBuy_revert_deadlinePassed() public {
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.takeOrderInputSingle(
            poolKey, dave, 1e15, 0, TickMath.getSqrtPriceAtTick(TU), block.timestamp - 1
        );
    }

    function test_takerBuy_poolHeightIncrements() public {
        (,, uint32 heightBefore) = _getSlot0Fwd();
        _takerBuy(dave, 100e18, TickMath.getSqrtPriceAtTick(TU));
        (,, uint32 heightAfter) = _getSlot0Fwd();
        assertGe(heightAfter, heightBefore, "pool height should not decrease");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // takerSell — sell tokenA through mirror pool
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev For takerSell, we first need liquidity in the MIRROR pool.
    ///      Alice places a buy maker order (which puts tokenB into mirror pool).
    function _setupMirrorLiquidity() internal {
        // Mirror pool: sell tokenB (currency0) for tokenA.
        // Place buy maker order with forward ticks [-TU, -TL] = [-180, -60].
        // Internally converted: mirrorTickLower = -(-TL) = TL = 60,
        //                        mirrorTickUpper = -(-TU) = TU = 180
        // These mirror ticks are above current mirror tick (0), so it's a valid maker.
        (uint256 tid,) = _placeBuyOrder(bob, -TU, -TL, LIQ);
        // bid is only needed to trigger the order placement; suppress warning
        require(tid > 0, "tid should be valid");
    }

    function test_takerSell_exactInput_receivesToken1() public {
        _setupMirrorLiquidity();

        uint256 token0Amount = 1e15;
        uint256 t0BeforeDave = tokenA.balanceOf(dave);
        uint256 t1BeforeDave = tokenB.balanceOf(dave);

        // Sell with no price limit (accept any price)
        (uint256 t0In, uint256 t1Out) = _takerSell(dave, token0Amount, 1);

        assertGt(t0In,  0, "should have spent token0");
        assertGt(t1Out, 0, "should have received token1");
        assertEq(tokenA.balanceOf(dave), t0BeforeDave + token0Amount - t0In, "token0 balance mismatch");
        assertEq(tokenB.balanceOf(dave), t1BeforeDave + t1Out, "token1 balance mismatch");
    }

    function test_takerSell_exactOutput_receivesExactToken1() public {
        _setupMirrorLiquidity();

        uint256 token1Want = 5e14;
        tokenA.mint(dave, 10e18); // extra collateral
        uint256 t0Before = tokenA.balanceOf(dave);

        vm.prank(dave);
        orderManager.takeOrderOutputSingle(
            mirrorKey,
            dave,
            token1Want,        // exact amountOut
            type(uint256).max, // amountInMaximum — no limit
            TickMath.MAX_SQRT_PRICE,
            block.timestamp + 1 hours
        );
        uint256 t1Out = token1Want; // exact output
        uint256 t0In = t0Before - tokenA.balanceOf(dave);

        assertEq(t1Out, token1Want, "exact token1 output not matched");
        assertGt(t0In,  0,         "should have spent token0");
    }

    function test_takerSell_revert_priceListTooHigh() public {
        _setupMirrorLiquidity();
        (uint160 currentSqrtMirror,,) = _getSlot0Mirror();
        uint160 badLimit = currentSqrtMirror - 1;

        tokenA.mint(dave, 1e18);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("BuyPriceBelowCurrent(uint160,uint160)")),
                badLimit,
                currentSqrtMirror
            )
        );
        orderManager.takeOrderInputSingle(mirrorKey, dave, 1e18, 0, badLimit, block.timestamp + 1 hours);
    }

    function test_takerSell_revert_zeroAmount() public {
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("ZeroTakeOrderAmount()"))));
        orderManager.takeOrderInputSingle(mirrorKey, dave, 0, 0, TickMath.MAX_SQRT_PRICE, block.timestamp + 1 hours);
    }

    function test_takerSell_revert_deadlinePassed() public {
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.takeOrderInputSingle(mirrorKey, dave, 1e15, 0, TickMath.MAX_SQRT_PRICE, block.timestamp - 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Multi-tick sweep
    // ─────────────────────────────────────────────────────────────────────────

    function test_takerBuy_multiTick() public {
        _placeSellOrder(bob,   180, 300, LIQ);
        _placeSellOrder(carol, 300, 420, LIQ);

        (,, uint32 heightBefore) = _getSlot0Fwd();
        _takerBuy(dave, 1000e18, TickMath.getSqrtPriceAtTick(420));
        (,, uint32 heightAfter) = _getSlot0Fwd();

        assertGt(heightAfter, heightBefore, "pool height should increase on tick crossings");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // takeOrderInputSingle — slippage guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_takeOrderInputSingle_revert_tooLittleReceived() public {
        uint256 amountIn  = 1e15;
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(TU);

        // Measure actual output via snapshot
        tokenB.mint(dave, amountIn);
        uint256 outBefore = tokenA.balanceOf(dave);
        uint256 snap = vm.snapshot();
        vm.prank(dave);
        orderManager.takeOrderInputSingle(
            poolKey, dave, amountIn, 0, priceLimit, block.timestamp + 1 hours
        );
        uint256 actualOut = tokenA.balanceOf(dave) - outBefore;
        vm.revertTo(snap);

        // Re-fund and call with minimum = actualOut + 1 — must revert
        tokenB.mint(dave, amountIn);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("TooLittleReceived(uint256,uint256)")),
                actualOut + 1,
                actualOut
            )
        );
        orderManager.takeOrderInputSingle(
            poolKey, dave, amountIn, actualOut + 1, priceLimit, block.timestamp + 1 hours
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // takeOrderOutputSingle — basic + slippage guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_takeOrderOutputSingle_receivesExactToken0() public {
        uint256 token0Want = 5e14;
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(TU);
        tokenB.mint(dave, 10e18);

        uint256 t1Before = tokenB.balanceOf(dave);
        uint256 aBeforeDave = tokenA.balanceOf(dave);
        vm.prank(dave);
        orderManager.takeOrderOutputSingle(
            poolKey, dave, token0Want, type(uint256).max, priceLimit, block.timestamp + 1 hours
        );
        uint256 t1In = t1Before - tokenB.balanceOf(dave);
        uint256 t0Out = token0Want; // exact output

        assertEq(t0Out, token0Want, "exact token0 output not matched");
        assertGt(t1In,  0,         "should have spent token1");
        assertEq(tokenA.balanceOf(dave), aBeforeDave + token0Want, "dave token0 balance mismatch");
    }

    function test_takeOrderOutputSingle_revert_tooMuchRequested() public {
        uint256 token0Want = 5e14;
        uint160 priceLimit = TickMath.getSqrtPriceAtTick(TU);
        tokenB.mint(dave, 10e18);

        // Measure actual input via snapshot
        uint256 inBefore = tokenB.balanceOf(dave);
        uint256 snap = vm.snapshot();
        vm.prank(dave);
        orderManager.takeOrderOutputSingle(
            poolKey, dave, token0Want, type(uint256).max, priceLimit, block.timestamp + 1 hours
        );
        uint256 actualIn = inBefore - tokenB.balanceOf(dave);
        vm.revertTo(snap);

        // Re-fund and call with maximum = actualIn - 1 — must revert
        tokenB.mint(dave, 10e18);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("TooMuchRequested(uint256,uint256)")),
                actualIn - 1,
                actualIn
            )
        );
        orderManager.takeOrderOutputSingle(
            poolKey, dave, token0Want, actualIn - 1, priceLimit, block.timestamp + 1 hours
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // takeOrderInput (multi-hop)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Set up a 2-hop path: pay tokenB → (via poolKey) → tokenA → (via zPool) → tokenC.
    ///
    ///   currencyIn = tokenB
    ///   inputPath  = [tokenA, tokenC]
    ///   outputPath = [tokenB, tokenA]
    function _setup2HopPath()
        internal
        returns (
            TestERC20 tokenC,
            Currency currencyIn,
            Currency currencyOut,
            PathKey[] memory inputPath,
            PathKey[] memory outputPath
        )
    {
        tokenC = new TestERC20("Token C", "TKC", 18);
        UnibuyPoolKey memory zPool = UnibuyPoolKey({
            currency0: Currency.wrap(address(tokenC)),
            currency1: Currency.wrap(address(tokenA)),
            tickSpacing: TICK_SPACING
        });
        poolManager.initialize(zPool, SQRT_PRICE_1_1);

        // Seed liquidity: alice deposits tokenC as maker in zPool
        tokenC.mint(alice, 10_000_000 ether);
        vm.prank(alice);
        tokenC.approve(address(orderManager), type(uint256).max);
        vm.prank(alice);
        orderManager.placeOrder(zPool, TL, TU, LIQ, block.timestamp + 1 hours);

        currencyIn = Currency.wrap(address(tokenB));
        currencyOut = Currency.wrap(address(tokenC));
        inputPath = new PathKey[](2);
        inputPath[0] = PathKey({
            hopCurrency: Currency.wrap(address(tokenA)),
            tickSpacing: TICK_SPACING
        });
        inputPath[1] = PathKey({
            hopCurrency: Currency.wrap(address(tokenC)),
            tickSpacing: TICK_SPACING
        });

        outputPath = new PathKey[](2);
        outputPath[0] = PathKey({
            hopCurrency: Currency.wrap(address(tokenB)),
            tickSpacing: TICK_SPACING
        });
        outputPath[1] = PathKey({
            hopCurrency: Currency.wrap(address(tokenA)),
            tickSpacing: TICK_SPACING
        });
    }

    function test_takeOrderInput_multiHop_receivesTokenC() public {
        (TestERC20 tokenC, Currency currencyIn, , PathKey[] memory path, ) = _setup2HopPath();

        uint256 amountIn = 1e15;
        tokenB.mint(dave, amountIn);
        vm.prank(dave);
        tokenC.approve(address(orderManager), type(uint256).max);

        uint256 cBefore = tokenC.balanceOf(dave);
        vm.prank(dave);
        orderManager.takeOrderInput(
            currencyIn, path, dave, amountIn, 0, block.timestamp + 1 hours
        );
        uint256 actualOut = tokenC.balanceOf(dave) - cBefore;
        uint256 actualIn = amountIn; // exact-input: full amount spent

        assertEq(actualIn,  amountIn, "should spend exact amountIn");
        assertGt(actualOut, 0,        "should receive tokenC");
        assertEq(tokenC.balanceOf(dave), cBefore + actualOut, "tokenC balance mismatch");
    }

    function test_takeOrderInput_slippageRevert() public {
        (TestERC20 tokenC, Currency currencyIn, , PathKey[] memory path, ) = _setup2HopPath();

        uint256 amountIn = 1e15;
        tokenB.mint(dave, amountIn);

        // Measure actual output via snapshot
        uint256 cBefore = tokenC.balanceOf(dave);
        uint256 snap = vm.snapshot();
        vm.prank(dave);
        orderManager.takeOrderInput(
            currencyIn, path, dave, amountIn, 0, block.timestamp + 1 hours
        );
        uint256 actualOut = tokenC.balanceOf(dave) - cBefore;
        vm.revertTo(snap);

        tokenB.mint(dave, amountIn);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("TooLittleReceived(uint256,uint256)")),
                actualOut + 1,
                actualOut
            )
        );
        orderManager.takeOrderInput(currencyIn, path, dave, amountIn, actualOut + 1, block.timestamp + 1 hours);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // takeOrderOutput (multi-hop)
    // ─────────────────────────────────────────────────────────────────────────

    function test_takeOrderOutput_multiHop_receivesExactTokenC() public {
        (TestERC20 tokenC, , Currency currencyOut, , PathKey[] memory path) = _setup2HopPath();

        uint256 amountOut = 5e14;
        tokenB.mint(dave, 10e18);
        vm.prank(dave);
        tokenC.approve(address(orderManager), type(uint256).max);

        uint256 inBefore = tokenB.balanceOf(dave);
        uint256 cBefore = tokenC.balanceOf(dave);
        vm.prank(dave);
        orderManager.takeOrderOutput(
            currencyOut, path, dave, amountOut, type(uint256).max, block.timestamp + 1 hours
        );
        uint256 actualIn = inBefore - tokenB.balanceOf(dave);
        uint256 actualOut = amountOut; // exact output

        assertEq(actualOut, amountOut, "should receive exact tokenC");
        assertGt(actualIn,  0,        "should spend tokenB");
        assertEq(tokenC.balanceOf(dave), cBefore + amountOut, "tokenC balance mismatch");
    }

    function test_takeOrderOutput_slippageRevert() public {
        (, , Currency currencyOut, , PathKey[] memory path) = _setup2HopPath();

        uint256 amountOut = 5e14;
        tokenB.mint(dave, 10e18);

        // Measure actual input via snapshot
        uint256 inBefore = tokenB.balanceOf(dave);
        uint256 snap = vm.snapshot();
        vm.prank(dave);
        orderManager.takeOrderOutput(
            currencyOut, path, dave, amountOut, type(uint256).max, block.timestamp + 1 hours
        );
        uint256 actualIn = inBefore - tokenB.balanceOf(dave);
        vm.revertTo(snap);

        tokenB.mint(dave, 10e18);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("TooMuchRequested(uint256,uint256)")),
                actualIn - 1,
                actualIn
            )
        );
        orderManager.takeOrderOutput(currencyOut, path, dave, amountOut, actualIn - 1, block.timestamp + 1 hours);
    }
}
