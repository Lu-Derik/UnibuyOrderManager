// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@unibuy/types/Currency.sol";

struct PathKey {
    Currency hopCurrency;
    int24 tickSpacing;
}