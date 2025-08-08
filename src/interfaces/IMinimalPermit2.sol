/**
 * SPDX-License-Identifier: UNLICENSED
 *
 * Copyright (c) 2025, Circle Internet Financial Trading Company Limited.
 * All rights reserved.
 *
 * Circle Internet Financial Trading Company Limited CONFIDENTIAL
 *
 * This file includes unpublished proprietary source code of Circle Internet
 * Financial Trading Company Limited, Inc. The copyright notice above does not
 * evidence any actual or intended publication of such source code. Disclosure
 * of this source code or any related proprietary information is strictly
 * prohibited without the express written permission of Circle Internet Financial
 * Trading Company Limited.
 */
pragma solidity 0.8.24;

/// @title IMinimalPermit2
/// @notice Minimal interface for Uniswap Permit2's permitWitnessTransferFrom functionality
interface IMinimalPermit2 {
    /// @dev Structure defining a token and the amount permitted to transfer
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    /// @dev Permit2 data structure authorizing transfer of permitted tokens
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev Transfer details used in conjunction with signature-based transfer
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Executes a token transfer authorized via a signed permit with witness data
    /// @param permit Struct containing permit data including token, amount, nonce, and deadline
    /// @param details Struct containing recipient and requested transfer amount
    /// @param owner Address of the token owner authorizing the transfer
    /// @param witness EIP-712 hash of the signed data
    /// @param witnessType Stringified EIP-712 type used to generate the witness hash
    /// @param signature Signature over the permit and witness data
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes32 witness,
        string calldata witnessType,
        bytes calldata signature
    ) external;
}
