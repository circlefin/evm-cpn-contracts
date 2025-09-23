/**
 * Copyright 2025 Circle Internet Group, Inc.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
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
