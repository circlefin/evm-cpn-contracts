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

import {ITransferWithWitness} from "./interfaces/ITransferWithWitness.sol";
import {Witnessable} from "./utils/Witnessable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IEIP3009} from "./interfaces/IEIP3009.sol";
import {EIP712} from "./utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "./utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "./utils/cryptography/SignatureChecker.sol";
import {Pausable} from "./utils/Pausable.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {SafeERC20} from "./utils/SafeERC20.sol";
import {Rescuable} from "./utils/Rescuable.sol";

/**
 * @title TransferWithWitness
 * @notice Implements ERC20 transfer functionality with additional witness signature
 */
contract TransferWithWitness is ITransferWithWitness, Witnessable, Rescuable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeERC20 for IEIP3009;

    error DirectTransferNotAllowed();

    // Constants for EIP-712
    // keccak256("WitnessTransferFrom(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,address witness,bytes32 witnessNonce)");
    bytes32 public constant WITNESS_TRANSFER_FROM_TYPEHASH =
        0xcc5ce2301a9e31667b4c6609ad873726f54fbc619a9fe190988e2dc92b31c20e;
    // keccak256("WitnessTransferWithAuthorization(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness,bytes32 witnessNonce)");
    bytes32 public constant WITNESS_TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x21ed5cab8eb9944ea574ce76c30de377888e1cd3d6ff38f345ac5d808a915c5a;
    // keccak256("CancelWitnessNonce(address witness,bytes32 witnessNonce)");
    bytes32 public constant CANCEL_WITNESS_NONCE_TYPEHASH =
        0x46b213526d0fb6ed009ef22e42e2671095dc3120a40512ee0076f33f38da33c7;

    /**
     * @dev authorizer address => nonce => bool (true if nonce is used)
     */
    mapping(bytes32 => bool) private _witnessStates;

    /**
     * @notice authorizer address => witness => bool (true if witness is valid)
     */
    mapping(address => bool) private _witnesses;

    /**
     * @inheritdoc ITransferWithWitness
     */
    function addWitness(address witness) external override onlyWitnessAuthorizer {
        if (witness == address(0)) revert InvalidWitness();
        _witnesses[witness] = true;
        emit WitnessAdded(witness);
    }

    /**
     * @inheritdoc ITransferWithWitness
     */
    function removeWitness(address witness) external override onlyWitnessAuthorizer {
        if (!_witnesses[witness]) revert NotWitness();
        delete _witnesses[witness];
        emit WitnessRemoved(witness);
    }

    /**
     * @inheritdoc ITransferWithWitness
     */
    function isWitness(address witness) external view override returns (bool) {
        return _witnesses[witness];
    }

    /**
     * @inheritdoc ITransferWithWitness
     */
    function witnessNonceState(bytes32 witnessNonce) external view override returns (bool) {
        return _witnessStates[witnessNonce];
    }

    /**
     * @inheritdoc ITransferWithWitness
     */
    function cancelWitnessNonce(WitnessData calldata _witnessData) external override {
        _requireValidWitnessNonce(_witnessData.witness, _witnessData.witnessNonce);
        _requireValidSignature(
            _witnessData.witness,
            keccak256(abi.encode(CANCEL_WITNESS_NONCE_TYPEHASH, _witnessData.witness, _witnessData.witnessNonce)),
            abi.encodePacked(_witnessData.r, _witnessData.s, _witnessData.v)
        );
        _witnessStates[_witnessData.witnessNonce] = true;
        emit WitnessNonceCancelled(_witnessData.witness, _witnessData.witnessNonce);
    }

    /**
     * @inheritdoc ITransferWithWitness
     */
    function transferFrom(TransferIntent calldata _transferIntent, WitnessData calldata _witnessData)
        external
        override
        nonReentrant
        whenNotPaused
    {
        _requireValidWitnessNonce(_witnessData.witness, _witnessData.witnessNonce);
        _requireValidIntent(
            _transferIntent.token,
            _transferIntent.from,
            _transferIntent.to,
            _transferIntent.value,
            _transferIntent.validAfter,
            _transferIntent.validBefore
        );
        _requireValidSignature(
            _witnessData.witness,
            keccak256(
                abi.encode(
                    WITNESS_TRANSFER_FROM_TYPEHASH,
                    _transferIntent.token,
                    _transferIntent.from,
                    _transferIntent.to,
                    _transferIntent.value,
                    _transferIntent.validAfter,
                    _transferIntent.validBefore,
                    _witnessData.witness,
                    _witnessData.witnessNonce
                )
            ),
            abi.encodePacked(_witnessData.r, _witnessData.s, _witnessData.v)
        );
        _markWitnessAsUsed(_witnessData.witnessNonce);
        IERC20(_transferIntent.token).safeTransferFrom(_transferIntent.from, _transferIntent.to, _transferIntent.value);
        emit WitnessTransfer(
            _witnessData.witness,
            _transferIntent.from,
            _transferIntent.to,
            _witnessData.witnessNonce,
            WITNESS_TRANSFER_FROM_TYPEHASH,
            address(_transferIntent.token),
            _transferIntent.value
        );
    }

    /**
     * @inheritdoc ITransferWithWitness
     */
    function transferWithAuthorization(TransferIntent calldata _transferIntent, WitnessData calldata _witnessData)
        external
        override
        nonReentrant
        whenNotPaused
    {
        _requireValidWitnessNonce(_witnessData.witness, _witnessData.witnessNonce);
        _requireValidIntent(
            _transferIntent.token,
            _transferIntent.from,
            _transferIntent.to,
            _transferIntent.value,
            _transferIntent.validAfter,
            _transferIntent.validBefore
        );
        _requireValidSignature(
            _witnessData.witness,
            keccak256(
                abi.encode(
                    WITNESS_TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                    _transferIntent.token,
                    _transferIntent.from,
                    _transferIntent.to,
                    _transferIntent.value,
                    _transferIntent.validAfter,
                    _transferIntent.validBefore,
                    _transferIntent.nonce,
                    _witnessData.witness,
                    _witnessData.witnessNonce
                )
            ),
            abi.encodePacked(_witnessData.r, _witnessData.s, _witnessData.v)
        );
        _markWitnessAsUsed(_witnessData.witnessNonce);
        IEIP3009 eip3009 = IEIP3009(_transferIntent.token);
        address contractAddress = address(this);
        uint256 balanceBefore = eip3009.balanceOf(contractAddress);
        eip3009.receiveWithAuthorization(
            _transferIntent.from,
            contractAddress,
            _transferIntent.value,
            _transferIntent.validAfter,
            _transferIntent.validBefore,
            _transferIntent.nonce,
            abi.encodePacked(_transferIntent.r, _transferIntent.s, _transferIntent.v)
        );
        if (eip3009.balanceOf(contractAddress) - balanceBefore != _transferIntent.value) revert InexactTransfer();
        eip3009.safeTransfer(_transferIntent.to, _transferIntent.value);
        emit WitnessTransfer(
            _witnessData.witness,
            _transferIntent.from,
            _transferIntent.to,
            _witnessData.witnessNonce,
            WITNESS_TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            _transferIntent.token,
            _transferIntent.value
        );
    }

    /**
     * @notice Mark an witness as used
     * @param witnessNonce Unique nonce of the witness
     */
    function _markWitnessAsUsed(bytes32 witnessNonce) private {
        _witnessStates[witnessNonce] = true;
        emit WitnessNonceUsed(witnessNonce);
    }

    /**
     * @notice Validates witness and witness nonce
     * @param witness           The address of the witness.
     * @param witnessNonce      Unique witness nonce.
     */
    function _requireValidWitnessNonce(address witness, bytes32 witnessNonce) private view {
        if (!_witnesses[witness]) revert NotWitness();
        if (_witnessStates[witnessNonce]) revert UsedNonce();
    }

    /**
     * @notice Validates the intent of the witness
     * @param token             The ERC-20 token address.
     * @param from              Payer's address.
     * @param to                Payee's address.
     * @param value             Amount to be transferred.
     * @param validAfter        The time after which this is valid (unix time).
     * @param validBefore       The time before which this is valid (unix time).
     */
    function _requireValidIntent(
        address token,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore
    ) private view {
        if (token == address(0)) revert InvalidTokenAddress();
        if (from == address(0)) revert InvalidPayer();
        if (to == address(0)) revert InvalidPayee();
        if (value == 0) revert InvalidAmount();
        if (block.timestamp <= validAfter) revert NotYetValid();
        if (block.timestamp >= validBefore) revert Expired();
    }

    /**
     * @notice Validates that signature against input data struct
     * @param signer        Signer's address
     * @param dataHash      Hash of encoded data struct
     * @param signature     Signature byte array produced by an EOA wallet or a contract wallet
     */
    function _requireValidSignature(address signer, bytes32 dataHash, bytes memory signature) private view {
        if (
            !SignatureChecker.isValidSignatureNow(
                signer,
                MessageHashUtils.toTypedDataHash(EIP712.makeDomainSeparator("TransferWithWitness", "1"), dataHash),
                signature
            )
        ) revert InvalidWitnessSignature();
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
