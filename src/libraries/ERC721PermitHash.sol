// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ERC721PermitHash
/// @notice Utility library for ERC721 permit operations
library ERC721PermitHash {
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_FOR_ALL_TYPEHASH =
        keccak256("PermitForAll(address operator,bool approved,uint256 nonce,uint256 deadline)");

    function hashPermit(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline));
    }

    function hashPermitForAll(address operator, bool approved, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline));
    }
}
