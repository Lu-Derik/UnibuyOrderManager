// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAllowanceTransfer} from "permit2/interfaces/IAllowanceTransfer.sol";

/// @title IPermit2Forwarder
interface IPermit2Forwarder {
    /// @notice Forward permit call to Permit2
    function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature)
        external
        payable
        returns (bytes memory err);

    /// @notice Forward permitBatch call to Permit2
    function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata _permitBatch, bytes calldata signature)
        external
        payable
        returns (bytes memory err);
}
