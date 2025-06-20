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

import {IEIP3009} from "./interfaces/IEIP3009.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPaymentWithWitness} from "./interfaces/IPaymentWithWitness.sol";

import {Pausable} from "./utils/Pausable.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

import {Rescuable} from "./utils/Rescuable.sol";
import {SafeERC20} from "./utils/SafeERC20.sol";
import {Witnessable} from "./utils/Witnessable.sol";
import {EIP712} from "./utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "./utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "./utils/cryptography/SignatureChecker.sol";

/**
 * @title PaymentWithWitness
 * @notice Implements ERC20 transfer functionality with additional witness signature
 */
contract PaymentWithWitness is IPaymentWithWitness, Witnessable, Rescuable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IEIP3009;

    error DirectTransferNotAllowed();

    // Constants for EIP-712

    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "Payment(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness)"
    );
    bytes32 public constant PAYMENT_WITH_PAYEE_TYPEHASH = keccak256(
        "PaymentWithPayee(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness)"
    );
    bytes32 public constant PAYEE_PAYMENT_WITH_PAYEE_TYPEHASH = keccak256(
        "PaymentWithPayee(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_NONCE_TYPEHASH = keccak256("CancelNonce(address witness,bytes32 nonce)");

    /**
     * @dev authorizer address => nonce => bool (true if nonce is used)
     */
    mapping(bytes32 => bool) private _witnessStates;

    /**
     * @notice authorizer address => witness => bool (true if witness is valid)
     */
    mapping(address => bool) private _witnesses;

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function addWitness(address witness) external override onlyWitnessAuthorizer {
        if (witness == address(0)) revert InvalidWitness();
        _witnesses[witness] = true;
        emit WitnessAdded(witness);
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function removeWitness(address witness) external override onlyWitnessAuthorizer {
        if (!_witnesses[witness]) revert NotWitness();
        delete _witnesses[witness];
        emit WitnessRemoved(witness);
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function isWitness(address witness) external view override returns (bool) {
        return _witnesses[witness];
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function nonceState(bytes32 nonce) external view override returns (bool) {
        return _witnessStates[nonce];
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function cancelNonce(WitnessData calldata _witnessData, bytes32 nonce) external override {
        _requireValidnonce(_witnessData.witness, nonce);
        _requireValidSignature(
            _witnessData.witness,
            keccak256(abi.encode(CANCEL_NONCE_TYPEHASH, _witnessData.witness, nonce)),
            _witnessData.signature
        );
        _witnessStates[nonce] = true;
        emit NonceCancelled(_witnessData.witness, nonce);
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function payment(TransferIntent calldata _transferIntent, WitnessData calldata _witnessData)
        external
        override
        nonReentrant
        whenNotPaused
    {
        _requireValidnonce(_witnessData.witness, _transferIntent.nonce);
        _requireValidIntent(_transferIntent);
        _requireValidSignature(
            _witnessData.witness,
            _hashWitnessTypedData(PAYMENT_TYPEHASH, _transferIntent, _witnessData.witness),
            _witnessData.signature
        );
        _markWitnessAsUsed(_transferIntent.nonce);
        IERC20(_transferIntent.token).safeTransferFrom(_transferIntent.from, _transferIntent.to, _transferIntent.value);
        emit Payment(
            _witnessData.witness,
            _transferIntent.from,
            _transferIntent.to,
            _transferIntent.nonce,
            address(_transferIntent.token),
            _transferIntent.value
        );
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function payment(
        TransferIntent calldata _transferIntent,
        WitnessData calldata _witnessData,
        ReceiveWithAuthData calldata _receiveWithAuthData
    ) external override nonReentrant whenNotPaused {
        _requireValidnonce(_witnessData.witness, _transferIntent.nonce);
        _requireValidIntent(_transferIntent);
        _requireValidSignature(
            _witnessData.witness,
            _hashWitnessTypedData(PAYMENT_TYPEHASH, _transferIntent, _witnessData.witness),
            _witnessData.signature
        );
        _markWitnessAsUsed(_transferIntent.nonce);
        IEIP3009 eip3009 = IEIP3009(_transferIntent.token);
        address contractAddress = address(this);
        uint256 balanceBefore = eip3009.balanceOf(contractAddress);
        eip3009.receiveWithAuthorization(
            _transferIntent.from,
            contractAddress,
            _transferIntent.value,
            _transferIntent.validAfter,
            _transferIntent.validBefore,
            _receiveWithAuthData.nonce,
            _receiveWithAuthData.signature
        );
        if (eip3009.balanceOf(contractAddress) - balanceBefore != _transferIntent.value) revert InexactTransfer();
        eip3009.safeTransfer(_transferIntent.to, _transferIntent.value);
        emit Payment(
            _witnessData.witness,
            _transferIntent.from,
            _transferIntent.to,
            _transferIntent.nonce,
            _transferIntent.token,
            _transferIntent.value
        );
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function paymentWithPayee(
        TransferIntent calldata _transferIntent,
        WitnessData calldata _witnessData,
        bytes calldata payeeSignature
    ) external override nonReentrant whenNotPaused {
        _requireValidnonce(_witnessData.witness, _transferIntent.nonce);
        _requireValidIntent(_transferIntent);
        _requireValidSignature(_transferIntent.to, _hashPayeeTypedData(_transferIntent), payeeSignature);
        _requireValidSignature(
            _witnessData.witness,
            _hashWitnessTypedData(PAYMENT_WITH_PAYEE_TYPEHASH, _transferIntent, _witnessData.witness),
            _witnessData.signature
        );
        _markWitnessAsUsed(_transferIntent.nonce);
        IERC20(_transferIntent.token).safeTransferFrom(_transferIntent.from, _transferIntent.to, _transferIntent.value);
        emit Payment(
            _witnessData.witness,
            _transferIntent.from,
            _transferIntent.to,
            _transferIntent.nonce,
            address(_transferIntent.token),
            _transferIntent.value
        );
    }

    /**
     * @inheritdoc IPaymentWithWitness
     */
    function paymentWithPayee(
        TransferIntent calldata _transferIntent,
        WitnessData calldata _witnessData,
        ReceiveWithAuthData calldata _receiveWithAuthData,
        bytes calldata payeeSignature
    ) external override nonReentrant whenNotPaused {
        _requireValidnonce(_witnessData.witness, _transferIntent.nonce);
        _requireValidIntent(_transferIntent);
        _requireValidSignature(_transferIntent.to, _hashPayeeTypedData(_transferIntent), payeeSignature);
        _requireValidSignature(
            _witnessData.witness,
            _hashWitnessTypedData(PAYMENT_WITH_PAYEE_TYPEHASH, _transferIntent, _witnessData.witness),
            _witnessData.signature
        );
        _markWitnessAsUsed(_transferIntent.nonce);
        IEIP3009 eip3009 = IEIP3009(_transferIntent.token);
        address contractAddress = address(this);
        uint256 balanceBefore = eip3009.balanceOf(contractAddress);
        eip3009.receiveWithAuthorization(
            _transferIntent.from,
            contractAddress,
            _transferIntent.value,
            _transferIntent.validAfter,
            _transferIntent.validBefore,
            _receiveWithAuthData.nonce,
            _receiveWithAuthData.signature
        );
        if (eip3009.balanceOf(contractAddress) - balanceBefore != _transferIntent.value) revert InexactTransfer();
        eip3009.safeTransfer(_transferIntent.to, _transferIntent.value);
        emit Payment(
            _witnessData.witness,
            _transferIntent.from,
            _transferIntent.to,
            _transferIntent.nonce,
            _transferIntent.token,
            _transferIntent.value
        );
    }

    /**
     * @notice Mark an witness as used
     * @param nonce Unique nonce of the witness
     */
    function _markWitnessAsUsed(bytes32 nonce) private {
        _witnessStates[nonce] = true;
        emit NonceUsed(nonce);
    }

    /**
     * @notice Validates witness and witness nonce
     * @param witness    The address of the witness.
     * @param nonce      Unique witness nonce.
     */
    function _requireValidnonce(address witness, bytes32 nonce) private view {
        if (!_witnesses[witness]) revert NotWitness();
        if (_witnessStates[nonce]) revert UsedNonce();
    }

    /**
     * @notice Validates the intent of the witness
     * @param _transferIntent   The transfer intent.
     */
    function _requireValidIntent(TransferIntent calldata _transferIntent) private view {
        if (_transferIntent.token == address(0)) revert InvalidTokenAddress();
        if (_transferIntent.from == address(0)) revert InvalidPayer();
        if (_transferIntent.to == address(0)) revert InvalidPayee();
        if (_transferIntent.value == 0) revert InvalidAmount();
        if (block.timestamp <= _transferIntent.validAfter) revert NotYetValid();
        if (block.timestamp >= _transferIntent.validBefore) revert Expired();
    }

    /**
     * @notice Validates that signature against input data struct
     * @param signer        Signer's address
     * @param dataHash      Hash of encoded data struct
     * @param signature     Signature byte array produced by an EOA wallet or a contract wallet
     */
    function _requireValidSignature(address signer, bytes32 dataHash, bytes calldata signature) private view {
        if (
            !SignatureChecker.isValidSignatureNow(
                signer,
                MessageHashUtils.toTypedDataHash(EIP712.makeDomainSeparator("PaymentWithWitness", "1"), dataHash),
                signature
            )
        ) revert InvalidSignature();
    }

    /**
     * @notice Hash the withness typed data according to EIP-712
     * @param typehash          The type hash.
     * @param _transferIntent   The transfer intent.
     * @param witness           The witness address.
     */
    function _hashWitnessTypedData(bytes32 typehash, TransferIntent calldata _transferIntent, address witness)
        private
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                typehash,
                _transferIntent.token,
                _transferIntent.from,
                _transferIntent.to,
                _transferIntent.value,
                _transferIntent.validAfter,
                _transferIntent.validBefore,
                _transferIntent.nonce,
                witness
            )
        );
    }

    /**
     * @notice Hash the payee typed data according to EIP-712
     * @param _transferIntent   The transfer intent.
     */
    function _hashPayeeTypedData(TransferIntent calldata _transferIntent) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PAYEE_PAYMENT_WITH_PAYEE_TYPEHASH,
                _transferIntent.token,
                _transferIntent.from,
                _transferIntent.to,
                _transferIntent.value,
                _transferIntent.validAfter,
                _transferIntent.validBefore,
                _transferIntent.nonce
            )
        );
    }

    /**
     * @dev Prevents the contract from receiving Ether via simple transfers.
     */
    receive() external payable {
        revert DirectTransferNotAllowed();
    }

    /**
     * @dev Prevents the contract from receiving Ether via transactions with data.
     */
    fallback() external payable {
        revert DirectTransferNotAllowed();
    }
}
