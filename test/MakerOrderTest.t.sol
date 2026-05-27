// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderManagerTestBase}   from "./helpers/OrderManagerTestBase.t.sol";
import {IUnibuyOrderManager}    from "../src/interfaces/IUnibuyOrderManager.sol";
import {UnibuyPoolId, UnibuyPoolIdLibrary, UnibuyPoolKey} from "@unibuy/types/UnibuyPoolKey.sol";
import {TickMath}               from "@unibuy/libraries/TickMath.sol";

/// @title MakerOrderTest
/// @notice Tests for placeSellOrder, placeBuyOrder and closeMakerOrder.
contract MakerOrderTest is OrderManagerTestBase {
    using UnibuyPoolIdLibrary for UnibuyPoolKey;

    int24  constant TL  = 60;
    int24  constant TU  = 180;
    uint128 constant LIQ = 10e18;
    uint256 private _day;

    function _advanceDayWithCrossing(int24 tickL) internal returns (int24 nextTickL) {
        _day++;
        vm.warp(1 + _day * 86400);

        int24 tickU = tickL + 2 * TICK_SPACING;
        _placeSellOrder(bob, tickL, tickU, 5e18);
        _takerBuy(dave, 1e30, TickMath.getSqrtPriceAtTick(tickU));
        nextTickL = tickU + TICK_SPACING;
    }

    function _advanceNDaysWithCrossings(uint8 n) internal {
        int24 tickL = TU + TICK_SPACING;
        for (uint8 i = 0; i < n; i++) {
            tickL = _advanceDayWithCrossing(tickL);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // placeSellOrder (挂单卖出)
    // ─────────────────────────────────────────────────────────────────────────

    function test_placeSellOrder_mintsNFT() public {
        uint256 nextId = orderManager.lastTokenId() + 1;
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        assertEq(tokenId, nextId,   "unexpected token ID");
        assertEq(orderManager.ownerOf(tokenId), alice, "alice should own NFT");
    }

    function test_placeSellOrder_recordStored() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(tokenId);
        assertEq(rec.tickLower, TL,  "tickLower mismatch");
        assertEq(rec.tickUpper, TU,  "tickUpper mismatch");
        assertTrue(rec.chained,      "should be chained");
        assertEq(rec.poolId, bytes19(UnibuyPoolId.unwrap(poolKey.toId())), "should be forward pool (sell order)");
    }

    function test_placeSellOrder_tokenADeducted() public {
        uint256 beforeBalance = tokenA.balanceOf(alice);
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        uint256 afterBalance = tokenA.balanceOf(alice);
        assertLt(afterBalance, beforeBalance, "token0 should have been deposited");
        // suppress unused warning
        uint256 _tid = tokenId; _tid = _tid;
    }

    function test_placeSellOrder_lastTokenIdIncrements() public {
        uint256 id1Before = orderManager.lastTokenId();
        _placeSellOrder(alice, TL, TU, LIQ);
        uint256 id2 = orderManager.lastTokenId();
        assertEq(id2, id1Before + 1, "lastTokenId not incremented");
    }

    function test_placeSellOrder_revert_deadline() public {
        uint256 orderInfo = _encodeOrderInfo(TL, TU, -TU, -TL, true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.makeOrder(poolKey, orderInfo, LIQ, block.timestamp - 1);
    }

    // Multiple sell orders from different makers
    function test_placeSellOrder_multipleMakers() public {
        (uint256 id1,) = _placeSellOrder(alice, TL,  TU,  LIQ);
        (uint256 id2,) = _placeSellOrder(bob,   TU,  300, LIQ);
        (uint256 id3,) = _placeSellOrder(carol, 300, 420, LIQ);

        assertEq(orderManager.ownerOf(id1), alice);
        assertEq(orderManager.ownerOf(id2), bob);
        assertEq(orderManager.ownerOf(id3), carol);
        assertEq(id3, id1 + 2, "IDs should be sequential");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // placeBuyOrder (挂单买入)
    // ─────────────────────────────────────────────────────────────────────────

    // Buy order: forward tick range below current tick (current=0, use [-180, -60])
    function test_placeBuyOrder_mintsNFT() public {
        uint256 nextId = orderManager.lastTokenId() + 1;
        (uint256 tokenId,) = _placeBuyOrder(alice, -TU, -TL, LIQ);
        assertEq(tokenId, nextId,  "unexpected token ID");
        assertEq(orderManager.ownerOf(tokenId), alice, "alice should own NFT");
    }

    function test_placeBuyOrder_recordStoredAsMirrorTicks() public {
        (uint256 tokenId,) = _placeBuyOrder(alice, -TU, -TL, LIQ);
        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(tokenId);
        // Stored as mirror ticks: mirrorTl = -(-TL) = TL, mirrorTu = -(-TU) = TU
        assertEq(rec.tickLower,  TL,   "mirrorTickLower should be -fwdTickUpper = TL");
        assertEq(rec.tickUpper,  TU,   "mirrorTickUpper should be -fwdTickLower = TU");
        assertEq(rec.poolId, bytes19(UnibuyPoolId.unwrap(mirrorKey.toId())), "should be mirror pool (buy order)");
        assertTrue(rec.chained,        "should be chained");
    }

    function test_placeBuyOrder_tokenBDeducted() public {
        uint256 beforeBalance = tokenB.balanceOf(alice);
        (uint256 tokenId,) = _placeBuyOrder(alice, -TU, -TL, LIQ);
        uint256 afterBalance = tokenB.balanceOf(alice);
        assertLt(afterBalance, beforeBalance, "token1 should have been deposited into mirror pool");
        uint256 _tid = tokenId; _tid = _tid;
    }

    function test_placeBuyOrder_revert_deadline() public {
        uint256 orderInfo = _encodeOrderInfo(TL, TU, -TU, -TL, true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.makeOrder(mirrorKey, orderInfo, LIQ, block.timestamp - 1);
    }

    function test_makeOrderWithTake_mintsNftAndDepositsToken0() public {
        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 beforeId = orderManager.lastTokenId() + 1;
        uint256 orderInfo = _encodeOrderInfo(TL, TU, -TU, -TL, true, false);

        vm.prank(alice);
        orderManager.makeOrderWithTake(poolKey, orderInfo, 1e18, block.timestamp + 1 hours);

        assertEq(orderManager.ownerOf(beforeId), alice, "alice should own nft");
        assertLt(tokenA.balanceOf(alice), beforeA, "token0 should be spent");
    }

    function test_makeOrderWithTake_executesMirrorTakeWhenNeeded() public {
        // Seed mirror-side liquidity in [60, 120] so mirror take from 0 -> 120 has active segment.
        _placeBuyOrder(bob, -120, -60, LIQ);

        // tickLower below current forward price => mirror threshold above current mirror price.
        int24 lower = -120;
        int24 upper = 120;
        uint256 orderInfo = _encodeOrderInfo(lower, upper, -upper, -lower, true, false);

        uint256 beforeB = tokenB.balanceOf(alice);

        vm.prank(alice);
        orderManager.makeOrderWithTake(poolKey, orderInfo, 2e18, block.timestamp + 1 hours);

        assertGt(tokenB.balanceOf(alice), beforeB, "mirror pre-take should credit token1");
    }

    function test_makeOrderWithTake_zeroAmount_doesNotMint() public {
        uint256 beforeId = orderManager.lastTokenId();
        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 orderInfo = _encodeOrderInfo(TL, TU, -TU, -TL, true, false);

        vm.prank(alice);
        orderManager.makeOrderWithTake(poolKey, orderInfo, 0, block.timestamp + 1 hours);

        assertEq(orderManager.lastTokenId(), beforeId, "zero amount should not mint a new NFT");
        assertEq(tokenA.balanceOf(alice), beforeA, "zero amount should not spend token0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // closeMakerOrder — sell order (without prior fill)
    // ─────────────────────────────────────────────────────────────────────────

    function test_closeSellOrder_returnsDeposit() public {
        uint256 token0Before = tokenA.balanceOf(alice);
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        uint256 token0AfterPlace = tokenA.balanceOf(alice);

        uint256 deposited = token0Before - token0AfterPlace;
        assertGt(deposited, 0, "should have deposited token0");

        (uint256 t0Back, uint256 t1Back) = _closeOrder(alice, tokenId);

        assertGt(t0Back, 0,          "should get token0 back");
        assertEq(t1Back, 0,          "no token1 earned yet (no takers)");
        // Approximate: returned ≈ deposited (may differ slightly due to protocol rounding)
        assertApproxEqRel(t0Back, deposited, 1e15, "returned token0 differs from deposit");
        assertEq(tokenA.balanceOf(alice), token0AfterPlace + t0Back, "balance not restored");
    }

    function test_closeSellOrder_burnsNFT() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        _closeOrder(alice, tokenId);

        vm.expectRevert(); // ERC721NonexistentToken
        orderManager.ownerOf(tokenId);
    }

    function test_closeSellOrder_marksInactive() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        _closeOrder(alice, tokenId);

        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(tokenId);
        assertFalse(rec.chained, "order should be unchained after close");
    }

    function test_closeSellOrder_partialFill() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        // Taker buys some of Alice's token0
        uint256 buyAmount = 1e15;
        _takerBuy(dave, buyAmount, TickMath.getSqrtPriceAtTick(TU));

        ( , uint256 t1Back) = _closeOrder(alice, tokenId);

        // After partial fill, Alice gets some token1 earned
        assertGt(t1Back, 0, "alice should have earned some token1");
        // And residual token0 back
        // (could be zero if fully swept, but with small taker amount, some remains)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // closeMakerOrder — buy order
    // ─────────────────────────────────────────────────────────────────────────

    function test_closeBuyOrder_returnsDeposit() public {
        uint256 token1Before = tokenB.balanceOf(bob);
        (uint256 tokenId,) = _placeBuyOrder(bob, -TU, -TL, LIQ);
        uint256 token1AfterPlace = tokenB.balanceOf(bob);

        uint256 deposited = token1Before - token1AfterPlace;
        assertGt(deposited, 0, "should have deposited token1");

        (uint256 t0Back, uint256 t1Back) = _closeOrder(bob, tokenId);

        assertEq(t0Back, 0,   "no token0 earned yet");
        assertGt(t1Back, 0,   "should get token1 back");
        assertApproxEqRel(t1Back, deposited, 1e15, "returned token1 differs from deposit");
    }

    function test_closeBuyOrder_burnsNFT() public {
        (uint256 tokenId,) = _placeBuyOrder(bob, -TU, -TL, LIQ);
        _closeOrder(bob, tokenId);
        vm.expectRevert();
        orderManager.ownerOf(tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // closeMakerOrder — access control
    // ─────────────────────────────────────────────────────────────────────────

    function test_closeSellOrder_revert_notOwner() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("NotOwnerNorApproved(address,address)")),
                bob,
                alice
            )
        );
        orderManager.closeOrder(tokenId, block.timestamp + 1 hours);
    }

    function test_closeSellOrder_revert_alreadyClosed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        _closeOrder(alice, tokenId);

        // NFT burned → ownerOf reverts first — that's fine, revert expected
        vm.prank(alice);
        vm.expectRevert();
        orderManager.closeOrder(tokenId, block.timestamp + 1 hours);
    }

    function test_closeSellOrder_revert_deadline() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.closeOrder(tokenId, block.timestamp - 1);
    }

    function test_closeMakerOrder_usesStoredPoolNotCallerKey() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        vm.prank(alice);
        orderManager.closeOrder(tokenId, block.timestamp + 1 hours);

        vm.expectRevert();
        orderManager.ownerOf(tokenId);
    }

    function test_closeOrderAuto_revert_notFullyCrossed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUnibuyOrderManager.AutoCloseNotEligible.selector, tokenId));
        orderManager.closeOrderAuto(tokenId, block.timestamp + 1 hours);
    }

    function test_closeOrderAuto_revert_beforeSevenDays() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        _takerBuy(dave, 100_000e18, TickMath.getSqrtPriceAtTick(TU + TICK_SPACING));

        // 7 day snapshots are not enough; condition requires older than 7 days.
        _advanceNDaysWithCrossings(7);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUnibuyOrderManager.AutoCloseNotEligible.selector, tokenId));
        orderManager.closeOrderAuto(tokenId, block.timestamp + 1 hours);
    }

    function test_closeOrderAuto_anyoneCanClose_afterSevenDays_andPayCloserFee() public {
        orderManager.setAutoCloseFeeBips(TICK_SPACING, 50); // 0.50%

        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        _takerBuy(dave, 100_000e18, TickMath.getSqrtPriceAtTick(TU + TICK_SPACING));

        _advanceNDaysWithCrossings(8);

        uint256 ownerToken1Before = tokenB.balanceOf(alice);
        uint256 closerToken1Before = tokenB.balanceOf(carol);
        uint256 closerToken0Before = tokenA.balanceOf(carol);

        vm.prank(carol);
        orderManager.closeOrderAuto(tokenId, block.timestamp + 1 hours);

        vm.expectRevert();
        orderManager.ownerOf(tokenId);

        uint256 ownerToken1After = tokenB.balanceOf(alice);
        uint256 closerToken1After = tokenB.balanceOf(carol);
        uint256 closerToken0After = tokenA.balanceOf(carol);

        assertGt(ownerToken1After, ownerToken1Before, "token1 proceeds should go to owner");
        assertGt(closerToken1After, closerToken1Before, "closer should receive token1 fee");
        assertEq(closerToken0After, closerToken0Before, "closer should not receive token0");
    }

    function test_setAutoCloseFeeBips_onlyController() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IUnibuyOrderManager.OnlyAutoCloseFeeController.selector));
        orderManager.setAutoCloseFeeBips(TICK_SPACING, 25);

        // Controller is deployer (this test contract in setUp)
        orderManager.setAutoCloseFeeBips(TICK_SPACING, 25);
        assertEq(orderManager.autoCloseFeeBips(TICK_SPACING), 25, "controller should update fee bips");
    }

    function test_closeMakerOrder_clearsOrderInfoSlot() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        _closeOrder(alice, tokenId);

        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(tokenId);
        assertEq(rec.poolId, bytes19(0), "poolId should be cleared");
        assertEq(rec.tickLower, 0, "tickLower should be cleared");
        assertEq(rec.tickUpper, 0, "tickUpper should be cleared");
        assertEq(rec.tickLowerMirror, 0, "tickLowerMirror should be cleared");
        assertEq(rec.tickUpperMirror, 0, "tickUpperMirror should be cleared");
        assertFalse(rec.chained, "chained should be false after clear");
        assertFalse(rec.autoClose, "autoClose should be false after clear");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NFT transfer → new owner can close
    // ─────────────────────────────────────────────────────────────────────────

    function test_transferNFT_newOwnerCanClose() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        // Alice transfers to Bob
        vm.prank(alice);
        orderManager.transferFrom(alice, bob, tokenId);
        assertEq(orderManager.ownerOf(tokenId), bob);

        // Alice can no longer close
        vm.prank(alice);
        vm.expectRevert();
        orderManager.closeOrder(tokenId, block.timestamp + 1 hours);

        // Bob can close
        (uint256 t0Back,) = _closeOrder(bob, tokenId);
        assertGt(t0Back, 0, "new owner should receive token0 back");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sell order with full fill + chained roll → close auto-places into mirror pool
    // ─────────────────────────────────────────────────────────────────────────

    function test_closeSellOrder_fullFill() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        uint256 lastIdBeforeClose = orderManager.lastTokenId();

        // Large taker buy sweeps past the range
        _takerBuy(dave, 100_000e18, TickMath.getSqrtPriceAtTick(TU + TICK_SPACING));

        (uint256 t0Back, uint256 t1Back) = _closeOrder(alice, tokenId);

        assertEq(t1Back, 0, "token1 should be rolled into mirror order");
        uint256 rolledTokenId = lastIdBeforeClose + 1;
        assertEq(orderManager.lastTokenId(), rolledTokenId, "mirror roll should mint a new NFT");
        assertEq(orderManager.ownerOf(rolledTokenId), alice, "rolled mirror order should belong to alice");
        // token0 may be non-zero due to protocol rounding but should be small
        assertLe(t0Back, 1e10, "after full fill, minimal token0 expected");
    }
}
