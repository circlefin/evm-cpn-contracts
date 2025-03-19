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

import {IEIP3009} from "./IEIP3009.sol";
import {IERC20} from "./IERC20.sol";

interface ITransferWithWitness {
    error InvalidWitness();
    error NotWitness();
    error InvalidTokenAddress();
    error InvalidPayer();
    error InvalidPayee();
    error InvalidAmount();
    error UsedNonce();
    error Expired();
    error NotYetValid();
    error InvalidWitnessSignature();
    error InexactTransfer();

    /// @notice Event emitted when a witness is added
    event WitnessAdded(address indexed witness);

    /// @notice Event emitted when a witness is removed
    event WitnessRemoved(address indexed witness);

    /// @notice Event emitted when a witness witnessNonce is used
    event WitnessNonceUsed(bytes32 indexed witnessNonce);

    /// @notice Event emitted when a witness witnessNonce is cancelled
    event WitnessNonceCancelled(address indexed witness, bytes32 witnessNonce);

    /// @notice Event emitted when transfer is successful
    event WitnessTransfer(
        address indexed witness,
        address indexed from,
        address indexed to,
        bytes32 witnessNonce,
        bytes32 typehash,
        address token,
        uint256 value
    );

    struct TransferIntent {
        address token;
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct WitnessData {
        address witness;
        bytes32 witnessNonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice Adds a new witness who can sign transfer intents.
     * @param witness The address to be added as a witness.
     */
    function addWitness(address witness) external;

    /**
     * @notice Removes a witness from the contract.
     * @param witness The address to be removed from the witness list.
     */
    function removeWitness(address witness) external;

    /**
     * @notice Checks if an address is a valid witness.
     * @param witness The address to check.
     * @return True if the address is a registered witness, false otherwise.
     */
    function isWitness(address witness) external view returns (bool);

    /**
     * @notice Returns the state of witness nonce.
     * @dev Nonces are randomly generated 32-byte data
     * @param witnessNonce Nonce of the authorization
     * @return True if the nonce is used
     */
    function witnessNonceState(bytes32 witnessNonce) external view returns (bool);

    /**
     * @notice Mark a watiness nonce as used.
     * @param _witnessData    The data of the witness..
     */
    function cancelWitnessNonce(WitnessData calldata _witnessData) external;

    /**
     * @notice Transfers tokens from the payer to the payee with additional intent verification.
     * @dev The from address must have approved this contract for at least `value` with the
     * `token` ERC-20 contract prior to invoking.
     * @param _transferIntent The transfer intent.
     * @param _witnessData    The data of the witness..
     */
    function transferFrom(TransferIntent calldata _transferIntent, WitnessData calldata _witnessData) external;

    /**
     * @notice Receive tokens using EIP-3009 authorization with additional intent verification.
     * @dev This should call the receiveWithAuthorization function in the token contract.
     * @param _transferIntent The transfer intent.
     * @param _witnessData    The data of the witness..
     */
    function transferWithAuthorization(TransferIntent calldata _transferIntent, WitnessData calldata _witnessData)
        external;
}
