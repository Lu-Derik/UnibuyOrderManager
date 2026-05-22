// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IEIP712_v4
interface IEIP712_v4 {
    /// @notice Get the domain separator used to sign for permits
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
