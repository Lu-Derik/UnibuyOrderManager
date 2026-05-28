// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OrderManagerTestBase} from "./helpers/OrderManagerTestBase.t.sol";
import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {IProtocolFees} from "@unibuy/interfaces/IProtocolFees.sol";
import {PoolFeeLibrary} from "@unibuy/libraries/PoolFeeLibrary.sol";
import {StateLibrary} from "@unibuy/libraries/StateLibrary.sol";
import {UnibuyPoolKey, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency} from "@unibuy/types/Currency.sol";

/// @title PoolInitializerTest
/// @notice Tests for PoolInitializer behavior exposed by UnibuyOrderManager.
contract PoolInitializerTest is OrderManagerTestBase {
    using UnibuyPoolIdLibrary for UnibuyPoolKey;
    using StateLibrary for IUnibuyPoolManager;

    function _configureTickSpacing(int24 tickSpacing) internal {
        uint24 poolFee = PoolFeeLibrary.pack(TAKER_FEE, MAKER_FEE, OFFSET_FEE);
        IProtocolFees(address(poolManager)).setTickSpacingSettings(tickSpacing, poolFee, TICK_GAP_LIMIT);
    }

    function _keyForSpacing(int24 tickSpacing) internal view returns (UnibuyPoolKey memory) {
        return UnibuyPoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            tickSpacing: tickSpacing
        });
    }

    function test_initializePool_initializesAndReturnsTick() public {
        int24 newSpacing = 120;
        _configureTickSpacing(newSpacing);

        UnibuyPoolKey memory key = _keyForSpacing(newSpacing);
        int24 returnedTick = orderManager.initializePool(key, SQRT_PRICE_1_1);

        (uint160 sqrtAfter, int24 tickAfter,,,,,) = IUnibuyPoolManager(address(poolManager)).getSlot0(key.toId());

        assertEq(returnedTick, tickAfter, "returned tick should match slot0");
        assertEq(sqrtAfter, SQRT_PRICE_1_1, "pool should initialize at requested sqrt price");
    }

    function test_initializePool_alreadyInitializedReturnsMaxInt24() public {
        int24 newSpacing = 120;
        _configureTickSpacing(newSpacing);

        UnibuyPoolKey memory key = _keyForSpacing(newSpacing);

        int24 firstTick = orderManager.initializePool(key, SQRT_PRICE_1_1);
        int24 secondTick = orderManager.initializePool(key, SQRT_PRICE_1_1);

        assertTrue(firstTick != type(int24).max, "first initialize should succeed");
        assertEq(secondTick, type(int24).max, "second initialize should return sentinel");
    }

    function test_initializePool_zeroTickSpacingReturnsMaxInt24() public {
        UnibuyPoolKey memory key = _keyForSpacing(0);

        int24 returnedTick = orderManager.initializePool(key, SQRT_PRICE_1_1);

        assertEq(returnedTick, type(int24).max, "invalid tick spacing should return sentinel");
    }

    function test_multicall_initializePool_twiceInOneTransaction() public {
        int24 newSpacing = 240;
        _configureTickSpacing(newSpacing);

        UnibuyPoolKey memory key = _keyForSpacing(newSpacing);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(orderManager.initializePool, (key, SQRT_PRICE_1_1));
        calls[1] = abi.encodeCall(orderManager.initializePool, (key, SQRT_PRICE_1_1));

        bytes[] memory results = orderManager.multicall(calls);

        int24 firstTick = abi.decode(results[0], (int24));
        int24 secondTick = abi.decode(results[1], (int24));

        assertTrue(firstTick != type(int24).max, "first init in multicall should succeed");
        assertEq(secondTick, type(int24).max, "second init in multicall should return sentinel");
    }
}
