// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@unibuy/types/Currency.sol";
import {IERC20Minimal} from "@unibuy/interfaces/external/IERC20Minimal.sol";
import {TransientStateLibrary} from "@unibuy/libraries/TransientStateLibrary.sol";
import {IUnibuyPoolManager} from "@unibuy/interfaces/IUnibuyPoolManager.sol";
import {ImmutableState} from "./ImmutableState.sol";

/// @title DeltaResolver
/// @notice Abstract contract used to sync, send, and settle funds to the Unibuy pool manager.
///         Mirrors the v4-periphery DeltaResolver pattern adapted for UnibuyPoolManager.
abstract contract DeltaResolver is ImmutableState {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IUnibuyPoolManager;

    /// @notice Take an amount of currency out of the PoolManager to a recipient
    /// @param currency Currency to take
    /// @param recipient Address to receive the currency
    /// @param amount Amount to take
    /// @dev Returns early if the amount is 0
    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.take(currency, recipient, amount);
    }

    /// @notice Pay and settle a currency to the PoolManager
    /// @dev The implementing contract must ensure that the `payer` is a secure address
    /// @param currency Currency to settle
    /// @param payer Address of the payer
    /// @param amount Amount to send
    /// @dev Returns early if the amount is 0
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            // Native ETH: forward value directly to poolManager
            poolManager.settle{value: amount}();
        } else {
            _pay(currency, payer, amount);
            poolManager.settle();
        }
    }

    /// @notice Pay tokens to the poolManager via transferFrom
    /// @param token The token to settle. Not the native currency.
    /// @param payer The address who should pay tokens
    /// @param amount The number of tokens to send
    function _pay(Currency token, address payer, uint256 amount) internal virtual {
        bool ok = IERC20Minimal(Currency.unwrap(token)).transferFrom(payer, address(poolManager), amount);
        require(ok, "TRANSFER_FROM_FAILED");
    }

    /// @notice Returns the full outstanding debt (negative delta) owed to the pool for `currency`.
    /// @dev    Returns 0 if the delta is non-negative (no debt).
    function _getFullDebt(Currency currency) internal view returns (uint256) {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        // forge-lint: disable-next-line(unsafe-typecast)
        return delta < 0 ? uint256(-delta) : 0;
    }

    /// @notice Returns the full outstanding credit (positive delta) the pool owes to this contract
    ///         for `currency`.
    /// @dev    Returns 0 if the delta is non-positive (no credit).
    function _getFullCredit(Currency currency) internal view returns (uint256) {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        // forge-lint: disable-next-line(unsafe-typecast)
        return delta > 0 ? uint256(delta) : 0;
    }
}
