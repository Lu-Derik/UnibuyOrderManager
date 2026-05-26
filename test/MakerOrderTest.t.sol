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

    // ─────────────────────────────────────────────────────────────────────────
    // placeSellOrder (挂单卖出)
    // ─────────────────────────────────────────────────────────────────────────

    function test_placeSellOrder_mintsNFT() public {
        uint256 nextId = orderManager.nextTokenId();
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        assertEq(tokenId, nextId,   "unexpected token ID");
        assertEq(orderManager.ownerOf(tokenId), alice, "alice should own NFT");
    }

    function test_placeSellOrder_recordStored() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        IUnibuyOrderManager.OrderInfo memory rec = orderManager.getMakerOrder(tokenId);
        assertEq(rec.tickLower, TL,  "tickLower mismatch");
        assertEq(rec.tickUpper, TU,  "tickUpper mismatch");
        assertTrue(rec.active,       "should be active");
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

    function test_placeSellOrder_nextTokenIdIncrements() public {
        uint256 id1Before = orderManager.nextTokenId();
        _placeSellOrder(alice, TL, TU, LIQ);
        uint256 id2 = orderManager.nextTokenId();
        assertEq(id2, id1Before + 1, "nextTokenId not incremented");
    }

    function test_placeSellOrder_revert_deadline() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.placeOrderNoTake(poolKey, TL, TU, LIQ, block.timestamp - 1);
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
        uint256 nextId = orderManager.nextTokenId();
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
        assertTrue(rec.active,         "should be active");
    }

    function test_placeBuyOrder_tokenBDeducted() public {
        uint256 beforeBalance = tokenB.balanceOf(alice);
        (uint256 tokenId,) = _placeBuyOrder(alice, -TU, -TL, LIQ);
        uint256 afterBalance = tokenB.balanceOf(alice);
        assertLt(afterBalance, beforeBalance, "token1 should have been deposited into mirror pool");
        uint256 _tid = tokenId; _tid = _tid;
    }

    function test_placeBuyOrder_revert_deadline() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.placeOrderNoTake(mirrorKey, TL, TU, LIQ, block.timestamp - 1);
    }

    function test_placeOrderWithTake_mintsNftAndDepositsToken0() public {
        uint256 beforeA = tokenA.balanceOf(alice);
        uint256 beforeId = orderManager.nextTokenId();

        vm.prank(alice);
        orderManager.placeOrderWithTake(poolKey, TL, TU, 1e18, block.timestamp + 1 hours);

        assertEq(orderManager.ownerOf(beforeId), alice, "alice should own nft");
        assertLt(tokenA.balanceOf(alice), beforeA, "token0 should be spent");
    }

    function test_placeOrderWithTake_executesMirrorTakeWhenNeeded() public {
        // Seed mirror-side liquidity in [60, 120] so mirror take from 0 -> 120 has active segment.
        _placeBuyOrder(bob, -120, -60, LIQ);

        // tickLower below current forward price => mirror threshold above current mirror price.
        int24 lower = -120;
        int24 upper = 120;

        uint256 beforeB = tokenB.balanceOf(alice);

        vm.prank(alice);
        orderManager.placeOrderWithTake(poolKey, lower, upper, 2e18, block.timestamp + 1 hours);

        assertGt(tokenB.balanceOf(alice), beforeB, "mirror pre-take should credit token1");
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
        assertFalse(rec.active, "order should be inactive after close");
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
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);
    }

    function test_closeSellOrder_revert_alreadyClosed() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        _closeOrder(alice, tokenId);

        // NFT burned → ownerOf reverts first — that's fine, revert expected
        vm.prank(alice);
        vm.expectRevert();
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);
    }

    function test_closeSellOrder_revert_deadline() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("DeadlinePassed()"))));
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp - 1);
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
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);

        // Bob can close
        (uint256 t0Back,) = _closeOrder(bob, tokenId);
        assertGt(t0Back, 0, "new owner should receive token0 back");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sell order with full fill → close retrieves only token1
    // ─────────────────────────────────────────────────────────────────────────

    function test_closeSellOrder_fullFill() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        // Large taker buy sweeps past the range
        _takerBuy(dave, 100_000e18, TickMath.getSqrtPriceAtTick(TU + TICK_SPACING));

        (uint256 t0Back, uint256 t1Back) = _closeOrder(alice, tokenId);

        assertGt(t1Back, 0, "alice should have earned token1");
        // token0 may be non-zero due to protocol rounding but should be small
        assertLe(t0Back, 1e10, "after full fill, minimal token0 expected");
    }
}
