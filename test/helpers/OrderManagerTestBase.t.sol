// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {UnibuyPoolManager}    from "@unibuy/UnibuyPoolManager.sol";
import {IUnibuyPoolManager}   from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {IProtocolFees}        from "@unibuy/interfaces/IProtocolFees.sol";
import {PoolFeeLibrary}       from "@unibuy/libraries/PoolFeeLibrary.sol";
import {UnibuyPoolKey, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency}             from "@unibuy/types/Currency.sol";
import {StateLibrary}         from "@unibuy/libraries/StateLibrary.sol";
import {TickMath}             from "@unibuy/libraries/TickMath.sol";

import {UnibuyOrderManager}   from "../../src/UnibuyOrderManager.sol";
import {PackedOrderInfo, OrderInfoLibrary} from "../../src/libraries/OrderInfoLibrary.sol";
import {TestERC20}            from "./TestERC20.sol";
import {IAllowanceTransfer}   from "permit2/interfaces/IAllowanceTransfer.sol";
import {IWETH9}               from "../../src/interfaces/external/IWETH9.sol";

/// @title OrderManagerTestBase
/// @notice Shared test setup for all UnibuyOrderManager tests.
///         Deploys the pool manager, order manager, two ERC-20 tokens, and
///         initialises a pair of mirror pools at price 1:1.
abstract contract OrderManagerTestBase is Test {
    using UnibuyPoolIdLibrary for UnibuyPoolKey;
    using StateLibrary        for IUnibuyPoolManager;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    int24  internal constant TICK_SPACING   = 60;
    uint8  internal constant TAKER_FEE      = 30;   // 0.30 %
    uint8  internal constant MAKER_FEE      = 5;    // 0.05 %
    uint8  internal constant OFFSET_FEE     = 20;   // 0.20 %
    uint8  internal constant TICK_GAP_LIMIT = 50;

    /// @dev Canonical 1:1 sqrt price (tick = 0).
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // ─────────────────────────────────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────────────────────────────────

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave  = makeAddr("dave");   // taker

    // ─────────────────────────────────────────────────────────────────────────
    // Contracts
    // ─────────────────────────────────────────────────────────────────────────

    TestERC20           internal tokenA;
    TestERC20           internal tokenB;
    UnibuyPoolManager   internal poolManager;
    UnibuyOrderManager  internal orderManager;

    /// @dev Forward pool: sell tokenA (currency0) for tokenB (currency1).
    UnibuyPoolKey internal poolKey;
    /// @dev Mirror pool: sell tokenB (currency0) for tokenA (currency1).
    UnibuyPoolKey internal mirrorKey;

    // ─────────────────────────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public virtual {
        tokenA = new TestERC20("Token A", "TKA", 18);
        tokenB = new TestERC20("Token B", "TKB", 18);

        poolManager  = new UnibuyPoolManager();
        
        // Create mock addresses for permit2 and WETH9
        address mockPermit2 = makeAddr("permit2");
        address mockWeth9 = makeAddr("weth9");
        
        orderManager = new UnibuyOrderManager(
            address(poolManager),
            IAllowanceTransfer(mockPermit2),
            IWETH9(mockWeth9)
        );

        poolKey = UnibuyPoolKey({
            currency0:  Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            tickSpacing: TICK_SPACING
        });
        mirrorKey = UnibuyPoolKey({
            currency0:  Currency.wrap(address(tokenB)),
            currency1: Currency.wrap(address(tokenA)),
            tickSpacing: TICK_SPACING
        });

        // Configure fee tier
        uint24 poolFee = PoolFeeLibrary.pack(TAKER_FEE, MAKER_FEE, OFFSET_FEE);
        IProtocolFees(address(poolManager)).setTickSpacingSettings(
            TICK_SPACING, poolFee, TICK_GAP_LIMIT
        );

        // Initialize both pools at price 1:1
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Fund actors
        _fundActors();
    }

    function _fundActors() internal {
        address[4] memory actors = [alice, bob, carol, dave];
        for (uint256 i = 0; i < actors.length; i++) {
            tokenA.mint(actors[i], 10_000_000 ether);
            tokenB.mint(actors[i], 10_000_000 ether);
            vm.prank(actors[i]);
            tokenA.approve(address(orderManager), type(uint256).max);
            vm.prank(actors[i]);
            tokenB.approve(address(orderManager), type(uint256).max);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers — pool state queries
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Read (sqrtPriceX96, tick, poolHeight) for the forward pool.
    function _getSlot0Fwd() internal view returns (uint160 sqrtX96, int24 tick, uint32 height) {
        (sqrtX96, tick, height,,,,) = IUnibuyPoolManager(address(poolManager)).getSlot0(poolKey.toId());
    }

    /// @dev Read (sqrtPriceX96, tick, poolHeight) for the mirror pool.
    function _getSlot0Mirror() internal view returns (uint160 sqrtX96, int24 tick, uint32 height) {
        (sqrtX96, tick, height,,,,) = IUnibuyPoolManager(address(poolManager)).getSlot0(mirrorKey.toId());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers — order operations
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Place a sell maker order in the forward pool via orderManager.
    ///      Returns (tokenId, compensation).
    function _placeSellOrder(
        address maker,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    ) internal returns (uint256 tokenId, uint96 compensation) {
        // Ensure forward pool price is compatible with the tick range.
        _ensureMirrorPriceOk(tickLower);

        tokenId = orderManager.lastTokenId() + 1;
        uint256 orderInfo = _encodeOrderInfo(
            tickLower,
            tickUpper,
            -tickUpper,
            -tickLower,
            true,
            false
        );
        vm.prank(maker);
        orderManager.makeOrder(poolKey, orderInfo, liquidity, block.timestamp + 1 hours);
        compensation = 0;
    }

    /// @dev Place a buy maker order in the mirror pool via orderManager.
    function _placeBuyOrder(
        address maker,
        int24   tickLower,   // forward-pool tick lower
        int24   tickUpper,   // forward-pool tick upper
        uint128 liquidity
    ) internal returns (uint256 tokenId, uint96 compensation) {
        int24 mirrorTl = -tickUpper;
        int24 mirrorTu = -tickLower;
        tokenId = orderManager.lastTokenId() + 1;
        uint256 orderInfo = _encodeOrderInfo(
            mirrorTl,
            mirrorTu,
            -mirrorTu,
            -mirrorTl,
            true,
            false
        );
        vm.prank(maker);
        orderManager.makeOrder(mirrorKey, orderInfo, liquidity, block.timestamp + 1 hours);
        compensation = 0;
    }

    /// @dev Execute a taker buy (pay tokenB, receive tokenA) via orderManager.
    function _takerBuy(
        address taker,
        uint256 token1Amount,   // tokenB to spend
        uint160 sqrtPriceLimit
    ) internal returns (uint256 token0Out, uint256 token1In) {
        tokenB.mint(taker, token1Amount);
        uint256 token0Before = tokenA.balanceOf(taker);
        uint256 token1Before = tokenB.balanceOf(taker);
        vm.prank(taker);
        orderManager.takeOrderInputSingle(
            poolKey,
            taker,              // recipient
            token1Amount,       // amountIn
            0,                  // amountOutMinimum — no slippage guard in helper
            sqrtPriceLimit,
            block.timestamp + 1 hours
        );
        token0Out = tokenA.balanceOf(taker) - token0Before;
        token1In = token1Before - tokenB.balanceOf(taker);
    }

    /// @dev Execute a taker sell (pay tokenA, receive tokenB) via orderManager.
    function _takerSell(
        address taker,
        uint256 token0Amount,   // tokenA to sell
        uint160 sqrtMinPriceFwd // min forward price (1 = no limit)
    ) internal returns (uint256 token0In, uint256 token1Out) {
        tokenA.mint(taker, token0Amount);
        // Convert the old forward-space sentinel to no limit in resolved mirror pool terms.
        uint160 mirrorLimit = sqrtMinPriceFwd <= 1 ? TickMath.MAX_SQRT_PRICE : sqrtMinPriceFwd;
        uint256 token0Before = tokenA.balanceOf(taker);
        uint256 token1Before = tokenB.balanceOf(taker);
        vm.prank(taker);
        orderManager.takeOrderInputSingle(
            mirrorKey,
            taker,              // recipient
            token0Amount,       // amountIn
            0,                  // amountOutMinimum — no slippage guard in helper
            mirrorLimit,
            block.timestamp + 1 hours
        );
        token0In = token0Before - tokenA.balanceOf(taker);
        token1Out = tokenB.balanceOf(taker) - token1Before;
    }

    /// @dev Close a maker order and return (token0Amount, token1Amount).
    function _closeOrder(
        address maker,
        uint256 tokenId
    ) internal returns (uint256 token0Amount, uint256 token1Amount) {
        uint256 token0Before = tokenA.balanceOf(maker);
        uint256 token1Before = tokenB.balanceOf(maker);
        vm.prank(maker);
        orderManager.closeOrder(tokenId, block.timestamp + 1 hours);
        token0Amount = tokenA.balanceOf(maker) - token0Before;
        token1Amount = tokenB.balanceOf(maker) - token1Before;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Stub for checking mirror price compatibility. More comprehensive validation
    ///      can be added if tick ranges in negative territory are tested.
    function _ensureMirrorPriceOk(int24 /*tickLower*/) internal pure {
        // No action required for tests using positive tick ranges.
    }

    function _encodeOrderInfo(
        int24 tickLower,
        int24 tickUpper,
        int24 tickLowerMirror,
        int24 tickUpperMirror,
        bool chained,
        bool autoClose
    ) internal pure returns (uint256) {
        PackedOrderInfo info =
            OrderInfoLibrary.initialize(bytes19(0), tickLower, tickUpper, tickLowerMirror, tickUpperMirror);
        if (!chained) {
            info = info.setUnchained();
        }
        if (autoClose) {
            info = info.setAuto();
        }
        return PackedOrderInfo.unwrap(info);
    }
}
