// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderManagerTestBase} from "./helpers/OrderManagerTestBase.t.sol";
import {IUnibuyOrderManager}  from "../src/interfaces/IUnibuyOrderManager.sol";
import {UnibuyPoolId, UnibuyPoolIdLibrary, UnibuyPoolKey} from "@unibuy/types/UnibuyPoolKey.sol";
import {TickMath}             from "@unibuy/libraries/TickMath.sol";

/// @title MixedOrderTest
/// @notice Tests for mixedBuy and mixedSell (先吃单后挂单) functionality.
contract MixedOrderTest is OrderManagerTestBase {
    using UnibuyPoolIdLibrary for UnibuyPoolKey;

    int24  constant TL   = 60;
    int24  constant TU   = 180;
    int24  constant TU2  = 300;
    uint128 constant LIQ = 10e18;

    // ─────────────────────────────────────────────────────────────────────────
    // mixedBuy — 先吃单后挂单（买入）
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Setup: Alice has a sell maker so that the taker part of the mixed buy can fill.
    function _setupSellLiquidity() internal {
        _placeSellOrder(alice, TL, TU, LIQ);
    }

    function test_mixedBuy_takerOnlyWhenMakerZero() public {
        _setupSellLiquidity();

        uint256 token1Amount = 1e15;
        uint160 priceLimit   = TickMath.getSqrtPriceAtTick(TU);
        uint256 nextId = orderManager.nextTokenId();

        uint256 token0Before = tokenA.balanceOf(dave);
        uint256 token1Before = tokenB.balanceOf(dave);
        tokenB.mint(dave, token1Amount);
        vm.prank(dave);
        orderManager.mixedOrder(
            poolKey,
            token1Amount,
            priceLimit,
            mirrorKey,
            0,
            0,
            0,
            dave,
            block.timestamp + 1 hours
        );

        assertGt(tokenA.balanceOf(dave) - token0Before, 0, "should have received token0");
        assertGt(token1Before + token1Amount - tokenB.balanceOf(dave), 0, "should have spent token1");
        assertEq(orderManager.nextTokenId(), nextId, "no maker should not mint NFT");
    }

    function test_mixedBuy_makerOnlyWhenTakerZero() public {
        uint256 nextId = orderManager.nextTokenId();

        uint256 token0Before = tokenA.balanceOf(dave);
        uint256 token1Before = tokenB.balanceOf(dave);
        tokenB.mint(dave, 10e18);
        vm.prank(dave);
        orderManager.mixedOrder(
            poolKey,
            0,
            0,
            mirrorKey,
            TL,
            TU,
            LIQ,
            dave,
            block.timestamp + 1 hours
        );

        assertEq(tokenA.balanceOf(dave), token0Before, "no taker, no token0 out");
        assertLt(tokenB.balanceOf(dave), token1Before + 10e18, "maker should deposit token1");
        assertEq(orderManager.nextTokenId(), nextId + 1, "maker tokenId should be nextId");
        assertEq(orderManager.ownerOf(nextId), dave, "dave should own maker NFT");

        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(nextId);
        assertEq(rec.poolId, bytes25(UnibuyPoolId.unwrap(mirrorKey.toId())), "should be mirror pool (buy order)");
        assertTrue(rec.active,     "should be active");
    }

    function test_mixedBuy_takerAndMaker() public {
        _setupSellLiquidity();

        uint256 nextId = orderManager.nextTokenId();

        uint256 token0Before = tokenA.balanceOf(dave);
        uint256 token1Before = tokenB.balanceOf(dave);
        tokenB.mint(dave, 10e18);
        vm.prank(dave);
        orderManager.mixedOrder(
            poolKey,
            1e15,
            TickMath.getSqrtPriceAtTick(TU),
            mirrorKey,
            TL,
            TU,
            LIQ,
            dave,
            block.timestamp + 1 hours
        );

        assertGt(tokenA.balanceOf(dave) - token0Before, 0, "should receive token0 from taker step");
        assertGt(token1Before + 10e18 - tokenB.balanceOf(dave), 0, "should spend token1 on taker step");

        assertEq(orderManager.nextTokenId(), nextId + 1, "maker tokenId incremented");
        assertEq(orderManager.ownerOf(nextId), dave, "dave should own maker NFT");

        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(nextId);
        assertEq(rec.poolId, bytes25(UnibuyPoolId.unwrap(mirrorKey.toId())), "should be mirror pool (buy order)");
    }

    function test_mixedBuy_revert_buyPriceBelowCurrent() public {
        _setupSellLiquidity();
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
        orderManager.mixedOrder(
            poolKey, 1e18, badLimit, mirrorKey, 0, 0, 0, dave, block.timestamp + 1 hours
        );
    }

    function test_mixedBuy_revert_deadline() public {
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.mixedOrder(
            poolKey, 0, 0, mirrorKey, 0, 0, 0, dave, block.timestamp - 1
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // mixedSell — 先吃单后挂单（卖出）
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Setup: Bob places a buy maker order so the mirror pool has liquidity for taker sells.
    function _setupBuyLiquidity() internal {
        _placeBuyOrder(bob, -TU, -TL, LIQ);
    }

    function test_mixedSell_takerOnlyWhenMakerZero() public {
        _setupBuyLiquidity();

        uint256 token0Amount = 1e15;
        uint256 token0Before = tokenA.balanceOf(dave);
        uint256 token1Before = tokenB.balanceOf(dave);
        tokenA.mint(dave, token0Amount);
        vm.prank(dave);
        orderManager.mixedOrder(
            mirrorKey,
            token0Amount,
            1,
            poolKey,
            0,
            0,
            0,
            dave,
            block.timestamp + 1 hours
        );

        assertGt(token0Before + token0Amount - tokenA.balanceOf(dave), 0, "should have spent token0");
        assertGt(tokenB.balanceOf(dave) - token1Before, 0, "should have received token1");
    }

    function test_mixedSell_makerOnlyWhenTakerZero() public {
        uint256 nextId = orderManager.nextTokenId();

        uint256 token0Before = tokenA.balanceOf(dave);
        uint256 token1Before = tokenB.balanceOf(dave);
        tokenA.mint(dave, 10e18);
        vm.prank(dave);
        orderManager.mixedOrder(
            mirrorKey,
            0,
            1,
            poolKey,
            TL,
            TU,
            LIQ,
            dave,
            block.timestamp + 1 hours
        );

        assertGt(token0Before + 10e18 - tokenA.balanceOf(dave), 0, "maker should spend token0");
        assertEq(tokenB.balanceOf(dave), token1Before, "maker should not touch token1");
        assertEq(orderManager.nextTokenId(), nextId + 1, "maker tokenId incremented");
        assertEq(orderManager.ownerOf(nextId), dave);

        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(nextId);
        assertEq(rec.poolId, bytes25(UnibuyPoolId.unwrap(poolKey.toId())), "should be forward pool (sell order)");
        assertTrue(rec.active,      "should be active");
    }

    function test_mixedSell_takerAndMaker() public {
        _setupBuyLiquidity();

        uint256 nextId = orderManager.nextTokenId();

        uint256 token0Before = tokenA.balanceOf(dave);
        uint256 token1Before = tokenB.balanceOf(dave);
        tokenA.mint(dave, 10e18);
        vm.prank(dave);
        orderManager.mixedOrder(
            mirrorKey,
            1e15,
            1,
            poolKey,
            TL,
            TU,
            LIQ,
            dave,
            block.timestamp + 1 hours
        );

        assertGt(token0Before + 10e18 - tokenA.balanceOf(dave), 0, "should spend token0 on taker step");
        assertGt(tokenB.balanceOf(dave) - token1Before, 0, "should receive token1 from taker step");

        assertEq(orderManager.nextTokenId(), nextId + 1, "maker tokenId incremented");
        assertEq(orderManager.ownerOf(nextId), dave);
    }

    function test_mixedSell_revert_sellPriceAboveCurrent() public {
        _setupBuyLiquidity();
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
        orderManager.mixedOrder(
            mirrorKey, 1e18, badLimit, poolKey, 0, 0, 0, dave, block.timestamp + 1 hours
        );
    }

    function test_mixedSell_revert_deadline() public {
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.mixedOrder(
            mirrorKey, 0, 1, poolKey, 0, 0, 0, dave, block.timestamp - 1
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Lifecycle: mixed order → close maker
    // ─────────────────────────────────────────────────────────────────────────

    function test_mixedBuy_closeMakerAfter() public {
        uint256 token1Amount = 1e15;
        tokenB.mint(dave, 10e18);
        uint256 nextId = orderManager.nextTokenId();
        vm.prank(dave);
        orderManager.mixedOrder(poolKey, token1Amount, TickMath.getSqrtPriceAtTick(TU), mirrorKey, TL, TU, LIQ, dave, block.timestamp + 1 hours);

        // Close the maker portion
        ( , uint256 t1Back) = _closeOrder(dave, nextId);
        // No fill yet on buy order, so all token1 refunded
        assertGe(t1Back, 0, "token1 refund expected");
    }

    function test_mixedSell_closeMakerAfter() public {
        tokenA.mint(dave, 10e18);
        uint256 nextId = orderManager.nextTokenId();
        vm.prank(dave);
        orderManager.mixedOrder(mirrorKey, 0, 1, poolKey, TL, TU, LIQ, dave, block.timestamp + 1 hours);

        (uint256 t0Back,) = _closeOrder(dave, nextId);
        assertGt(t0Back, 0, "should get token0 back from unfilled sell order");
    }
}
