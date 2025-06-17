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

interface IPaymentWithWitness {
    error InvalidWitness();
    error NotWitness();
    error InvalidTokenAddress();
    error InvalidPayer();
    error InvalidPayee();
    error InvalidAmount();
    error UsedNonce();
    error Expired();
    error NotYetValid();
    error InvalidSignature();
    error InexactTransfer();

    /// @notice Event emitted when a witness is added.
    event WitnessAdded(address indexed witness);

    /// @notice Event emitted when a witness is removed.
    event WitnessRemoved(address indexed witness);

    /// @notice Event emitted when a witness nonce is used.
    event NonceUsed(bytes32 indexed nonce);

    /// @notice Event emitted when a witness nonce is cancelled.
    event NonceCancelled(address indexed witness, bytes32 nonce);

    /// @notice Event emitted when transfer is successful.
    event Payment(
        address indexed witness, address indexed from, address indexed to, bytes32 nonce, address token, uint256 value
    );

    /**
     * @dev EOA wallet signatures should be packed in the order of r, s, v.
     * @param token         The address of the token contract.
     * @param from          Payer's address (Authorizer).
     * @param to            Payee's address.
     * @param value         Amount to be transferred.
     * @param validAfter    The time after which this is valid (unix time).
     * @param validBefore   The time before which this is valid (unix time).
     * @param signature     Signature bytes signed by an EOA wallet or a contract wallet.
     */
    struct TransferIntent {
        address token;
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    /**
     * @dev EOA wallet signatures should be packed in the order of r, s, v.
     * @param nonce         Unique nonce.
     * @param witness       The witness address.
     * @param signature     Signature bytes signed by an EOA wallet or a contract wallet.
     */
    struct WitnessData {
        address witness;
        bytes signature;
    }

    /**
     * @dev EOA wallet signatures should be packed in the order of r, s, v.
     * @dev EIP-3009 reseciveWithAuthentication signature, the `to` address must be this contract address.
     * @param nonce         The EIP-3009 unique nonce.
     * @param signature     Signature bytes signed by an EOA wallet or a contract wallet.
     */
    struct ReceiveWithAuthData {
        bytes32 nonce;
        bytes signature;
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
     * @dev Nonces are randomly generated 32-byte data.
     * @param nonce Nonce of the authorization.
     * @return True if the nonce is used.
     */
    function nonceState(bytes32 nonce) external view returns (bool);

    /**
     * @notice Mark a watiness nonce as used.
     * @param _witnessData    The data of the witness.
     * @param nonce           Nonce of the authorization.
     */
    function cancelNonce(WitnessData calldata _witnessData, bytes32 nonce) external;

    /**
     * @notice Transfers tokens from the payer to the payee with intent verification by witness.
     * @dev The from address must have approved this contract for at least `value` with the.
     * `token` ERC-20 contract prior to invoking.
     * @param _transferIntent The transfer intent.
     * @param _witnessData    The data of the witness.
     */
    function payment(TransferIntent calldata _transferIntent, WitnessData calldata _witnessData) external;

    /**
     * @notice Receive tokens using EIP-3009 authorization with intent verification by witness.
     * @dev This method should call the receiveWithAuthorization function in the token contract.
     * @param _transferIntent          The transfer intent.
     * @param _witnessData             The data of the witness.
     * @param _receiveWithAuthData    The data of EIP-3009 nonce and signature.
     */
    function payment(
        TransferIntent calldata _transferIntent,
        WitnessData calldata _witnessData,
        ReceiveWithAuthData calldata _receiveWithAuthData
    ) external;

    /**
     * @notice Transfers tokens from the payer to the payee with intent verification by witness and payee.
     * @dev EOA wallet signatures should be packed in the order of r, s, v.
     * @dev The from address must have approved this contract for at least `value` with the.
     * `token` ERC-20 contract prior to invoking.
     * @param _transferIntent The transfer intent.
     * @param _witnessData    The data of the witness.
     * @param payeeSignature  Signature bytes signed by an EOA wallet or a contract wallet of payee.
     */
    function paymentWithPayee(
        TransferIntent calldata _transferIntent,
        WitnessData calldata _witnessData,
        bytes calldata payeeSignature
    ) external;

    /**
     * @notice Receive tokens using EIP-3009 authorization with intent verification by witness and payee.
     * @dev EOA wallet signatures should be packed in the order of r, s, v.
     * @dev This method should call the receiveWithAuthorization function in the token contract.
     * @param _transferIntent          The transfer intent.
     * @param _witnessData             The data of the witness.
     * @param _receiveWithAuthData    The data of EIP-3009 nonce and signature.
     * @param payeeSignature           Signature bytes signed by an EOA wallet or a contract wallet of payee.
     */
    function paymentWithPayee(
        TransferIntent calldata _transferIntent,
        WitnessData calldata _witnessData,
        ReceiveWithAuthData calldata _receiveWithAuthData,
        bytes calldata payeeSignature
    ) external;
}
