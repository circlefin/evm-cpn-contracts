/**
 * Copyright 2026 Circle Internet Group, Inc.  All rights reserved.
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

import {IMinimalPermit2} from "./interfaces/IMinimalPermit2.sol";
import {Configurable} from "./utils/Configurable.sol";
import {Pausable} from "./utils/Pausable.sol";
import {Rescuable} from "./utils/Rescuable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title PaymentSettlementV2
/// @notice Circle Payments Network onchain payment contract with Pricing Engine support (V2).
contract PaymentSettlementV2 is
    Ownable2Step,
    Initializable,
    Pausable,
    ReentrancyGuardTransient,
    Rescuable,
    Configurable
{
    using SafeERC20 for IERC20;

    /// @dev EIP-712 domain separator typehash
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev EIP-712 domain separator name hash
    bytes32 private constant _NAME_HASH = keccak256("PaymentSettlementV2");

    /// @dev EIP-712 domain separator version hash
    bytes32 private constant _VERSION_HASH = keccak256("1");

    /// @notice EIP-712 typehash for payee-signed PaymentIntent
    bytes32 public constant PAYEE_PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address token,address from,address to,uint256 payeeSettlementAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,address attester)"
    );

    /// @notice EIP-712 typehash for payer-signed PaymentIntent
    /// @dev Field name `value` matches V1 payer type string for backward compatibility;
    ///      maps to PaymentIntent.payerAmount in the ABI-encoded struct.
    bytes32 public constant PAYER_PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,bool requirePayeeSign,address attester)"
    );

    /// @notice EIP-712 typehash for payer cancel intent
    bytes32 public constant PAYER_CANCEL_PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address from,bytes32 nonce,address beneficiary,uint256 maxFee,address attester)");

    /// @notice EIP-712 typehash for incentive consent witness (payment-scoped authorization)
    bytes32 public constant INCENTIVE_CONSENT_TYPEHASH = keccak256(
        "IncentiveConsent(address from,address to,uint256 payerAmount,uint256 payeeSettlementAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 maxFee,address attester)"
    );

    /// @notice EIP-712 typehash for payer-signed refund intent
    bytes32 public constant PAYER_REFUND_TYPEHASH = keccak256(
        "PayerRefundIntent(address token,uint256 payerRefundAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,address payerRefundTo,uint256 cumulativePayerRefunded,uint256 cumulativeIncentiveRefunded,address attester)"
    );

    /// @notice EIP-712 typehash for incentive provider-signed refund intent
    bytes32 public constant INCENTIVE_PROVIDER_REFUND_TYPEHASH = keccak256(
        "IncentiveProviderRefundIntent(address token,uint256 incentiveProviderRefundAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,address incentiveProviderRefundTo,uint256 cumulativePayerRefunded,uint256 cumulativeIncentiveRefunded,address attester)"
    );

    /// @notice EIP-712 typehash for payee refund source witness
    bytes32 public constant PAYEE_REFUND_SOURCE_TYPEHASH = keccak256(
        "PayeeRefundSourceIntent(address payeeRefundFrom,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 payerRefundAmount,uint256 incentiveProviderRefundAmount,address payerRefundTo,address incentiveProviderRefundTo,bool requireDestinationRefundSig,address attester)"
    );

    /// @notice EIP-712 typehash for beneficiary refund source witness
    bytes32 public constant BENEFICIARY_REFUND_SOURCE_TYPEHASH = keccak256(
        "BeneficiaryRefundSourceIntent(address beneficiaryRefundFrom,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 payerRefundAmount,uint256 incentiveProviderRefundAmount,address payerRefundTo,address incentiveProviderRefundTo,bool requireDestinationRefundSig,address attester)"
    );

    /// @notice EIP-712 witness type string for payment intent
    /// @dev Field name `value` matches V1 payer type string for backward compatibility;
    ///      maps to PaymentIntent.payerAmount in the ABI-encoded struct.
    string public constant _WITNESS_PAYMENT_TYPE_STR = "PaymentIntent witness)"
        "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,bool requirePayeeSign,address attester)"
        "TokenPermissions(address token,uint256 amount)";

    /// @notice EIP-712 witness type string for cancel intent
    string public constant _WITNESS_CANCEL_TYPE_STR = "PaymentIntent witness)"
        "PaymentIntent(address from,bytes32 nonce,address beneficiary,uint256 maxFee,address attester)"
        "TokenPermissions(address token,uint256 amount)";

    /// @notice EIP-712 witness type string for incentive consent
    string public constant _WITNESS_INCENTIVE_TYPE_STR = "IncentiveConsent witness)"
        "IncentiveConsent(address from,address to,uint256 payerAmount,uint256 payeeSettlementAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 maxFee,address attester)"
        "TokenPermissions(address token,uint256 amount)";

    /// @notice EIP-712 witness type string for payee refund source
    string public constant _WITNESS_PAYEE_REFUND_SOURCE_TYPE_STR = "PayeeRefundSourceIntent witness)"
        "PayeeRefundSourceIntent(address payeeRefundFrom,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 payerRefundAmount,uint256 incentiveProviderRefundAmount,address payerRefundTo,address incentiveProviderRefundTo,bool requireDestinationRefundSig,address attester)"
        "TokenPermissions(address token,uint256 amount)";

    /// @notice EIP-712 witness type string for beneficiary refund source
    string public constant _WITNESS_BENEFICIARY_REFUND_SOURCE_TYPE_STR = "BeneficiaryRefundSourceIntent witness)"
        "BeneficiaryRefundSourceIntent(address beneficiaryRefundFrom,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 payerRefundAmount,uint256 incentiveProviderRefundAmount,address payerRefundTo,address incentiveProviderRefundTo,bool requireDestinationRefundSig,address attester)"
        "TokenPermissions(address token,uint256 amount)";

    /// @dev EIP-712 structured data representing an offchain-signed payment intent
    struct PaymentIntent {
        address from;
        address to;
        uint256 payerAmount;
        uint256 payeeSettlementAmount;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        address incentiveProvider;
        address beneficiary;
        uint256 maxFee;
        bool requirePayeeSign;
        address attester;
    }

    /// @dev Data structure containing Permit2 permit and signature
    struct Permit2Data {
        IMinimalPermit2.PermitTransferFrom permit;
        bytes signature;
    }

    /// @dev EIP-712 structured data for refund authorization, includes payment record fields for hash verification
    struct RefundIntent {
        address token;
        address payer;
        address payeeRefundFrom;
        uint256 payerAmount;
        uint256 payeeSettlementAmount;
        uint256 fee;
        uint256 payerRefundAmount;
        uint256 incentiveProviderRefundAmount;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        address incentiveProvider;
        address beneficiaryRefundFrom;
        address payerRefundTo;
        address incentiveProviderRefundTo;
        bool requireDestinationRefundSig;
        address attester;
    }

    /// @dev Nonce lifecycle states
    enum NonceStatus {
        Unused,
        Executed,
        Cancelled,
        Refunded
    }

    /// @dev Tracks nonce state transitions: Unused → Executed → Refunded, or Unused → Cancelled
    mapping(bytes32 => NonceStatus) private _nonceStatus;

    /// @dev Stores payment record hash for refund verification (only written by execute)
    mapping(bytes32 => bytes32) private _paymentRecordHashes;
    /// @dev Tracks cumulative payer-side refunded amount per nonce
    mapping(bytes32 => uint256) private _cumulativePayerRefunded;
    /// @dev Tracks cumulative incentive-provider-side refunded amount per nonce
    mapping(bytes32 => uint256) private _cumulativeIncentiveRefunded;

    /// @dev Mapping of authorized attesters
    mapping(address => bool) private _attesters;

    /// @dev Uniswap Permit2 contract
    IMinimalPermit2 public permit2;

    /// @dev Cached EIP-712 domain separator, set once in constructor
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    /// @notice Emitted when a new attester is added
    event AttesterAdded(address indexed attester);

    /// @notice Emitted when an attester is removed
    event AttesterRemoved(address indexed attester);

    /// @notice Emitted when a payee signature is verified
    event PayeeVerified(bytes32 indexed nonce, address indexed payee);

    /// @notice Emitted when a payer refund signature is verified
    event PayerRefundVerified(bytes32 indexed nonce, address indexed payer);

    /// @notice Emitted when an incentive provider refund signature is verified
    event IncentiveProviderRefundVerified(bytes32 indexed nonce, address indexed incentiveProvider);

    /// @notice Emitted when a nonce is used
    event NonceUsed(
        bytes32 indexed nonce,
        address indexed attester,
        address token,
        address from,
        address to,
        uint256 payerAmount,
        uint256 payeeSettlementAmount,
        address beneficiary,
        uint256 fee
    );

    /// @notice Emitted when a nonce is cancelled
    event NonceCancelled(
        bytes32 indexed nonce, address indexed attester, address token, address beneficiary, uint256 fee
    );

    /// @notice Emitted on each refund call with payer-side refund details.
    /// @dev Incentive-provider refund details are reported separately via IncentiveRefunded.
    event NonceRefunded(
        bytes32 indexed nonce,
        address indexed attester,
        address indexed payer,
        address token,
        uint256 payerRefundAmount,
        address payerRefundTo,
        uint256 cumulativePayerRefunded
    );

    /// @notice Emitted when a settlement uses incentive provider (incentive case)
    event SettlementIncentivized(
        bytes32 indexed nonce, address indexed incentiveProvider, address token, uint256 shortfall
    );

    /// @notice Emitted on any refund call where incentiveProvider is set, including zero-amount refunds.
    /// @dev Fires whenever intent.incentiveProvider != address(0), even when incentiveProviderRefundAmount is zero.
    event IncentiveRefunded(
        bytes32 indexed nonce,
        address indexed attester,
        address indexed incentiveProvider,
        address token,
        uint256 incentiveProviderRefundAmount,
        address incentiveProviderRefundTo,
        uint256 cumulativeIncentiveRefunded
    );

    /// @notice Thrown when a nonce is not in the expected state for the operation
    error InvalidNonceState(bytes32 nonce, NonceStatus current);

    /// @notice Thrown when an intent has expired
    error ExpiredIntent();

    /// @notice Thrown when an intent is not yet valid
    error NotYetValid();

    /// @notice Thrown when a signature is invalid
    error InvalidSignature();

    /// @notice Thrown when an attester is invalid
    error InvalidAttester(address sender);

    /// @notice Thrown when an owner is invalid
    error InvalidOwner(address owner);

    /// @notice Thrown when the actual token transfer amount differs from the expected amount
    error InvalidAmount();

    /// @notice Thrown when a Permit2 permitted amount does not match the expected value
    error PermitAmountMismatch();

    /// @notice Thrown when refund source amounts do not sum to the total refund
    error RefundAmountMismatch();

    /// @notice Thrown when a non-incentive payment specifies a non-zero incentive provider
    error InvalidIncentiveProvider();

    /// @notice Thrown when a payee is invalid
    error InvalidPayee();

    /// @notice Thrown when a Permit2 contract is invalid
    error InvalidPermit2();

    /// @notice Thrown when a beneficiary is invalid
    error InvalidBeneficiary();

    /// @notice Thrown when renouncing ownership is disabled
    error RenounceOwnershipDisabled();

    /// @notice Thrown when a fee exceeds the maximum fee
    error FeeExceedsMax(uint256 fee, uint256 maxFee);

    /// @notice Thrown when payer amount does not equal payee settlement amount (no-incentive case)
    error PayerAmountMismatch();

    /// @notice Thrown when incentive permitted amount does not match the required shortfall
    error InvalidIncentiveAmount();

    /// @notice Thrown when a permit token does not match the intent token
    error InvalidToken();

    /// @notice Thrown when a refund amount exceeds the original payment ceiling
    error RefundExceedsCeiling();

    /// @notice Thrown when the provided payment record fields do not match the stored hash
    error InvalidPaymentRecord();

    /// @notice Thrown when a refund destination address is zero
    error InvalidRefundDestination(address destination);

    /// @notice Initializes Permit2, owner, roles (rescuer, pauser, configurator), and the attester set
    /// @dev Callable only once. Must be called immediately after deployment.
    /// @param permit2_ Address of Uniswap Permit2 contract
    /// @param owner_ Initial contract owner
    /// @param rescuer_ Initial rescuer role address
    /// @param pauser_ Initial pauser role address
    /// @param configurator_ Initial configurator role address
    /// @param attesters_ Initial list of authorized attester addresses
    function initialize(
        IMinimalPermit2 permit2_,
        address owner_,
        address rescuer_,
        address pauser_,
        address configurator_,
        address[] calldata attesters_
    ) external onlyOwner initializer {
        if (address(permit2_) == address(0)) revert InvalidPermit2();
        if (owner_ == address(0)) revert InvalidOwner(owner_);

        permit2 = permit2_;

        _transferOwnership(owner_);
        _initializePauser(pauser_);
        _initializeConfigurator(configurator_);
        _initializeRescuer(rescuer_);

        uint256 len = attesters_.length;
        for (uint256 i; i < len; i++) {
            address a = attesters_[i];
            if (!_attesters[a]) {
                _attesters[a] = true;
                emit AttesterAdded(a);
            }
        }
    }

    constructor() Ownable(_msgSender()) {
        _CACHED_DOMAIN_SEPARATOR =
            keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    /// @notice Modifier to check if the caller is an attester
    /// @dev Reverts if the caller is not an attester
    modifier onlyAttester() {
        if (!_attesters[_msgSender()]) revert InvalidAttester(_msgSender());
        _;
    }

    /// @notice Adds a new attester address
    /// @param attester_ Address to be granted attester role
    function addAttester(address attester_) external onlyConfigurator {
        if (!_attesters[attester_]) {
            _attesters[attester_] = true;
            emit AttesterAdded(attester_);
        }
    }

    /// @notice Removes an attester address
    /// @param attester_ Address to be revoked from attester role
    function removeAttester(address attester_) external onlyConfigurator {
        if (_attesters[attester_]) {
            delete _attesters[attester_];
            emit AttesterRemoved(attester_);
        }
    }

    /// @notice Checks whether an address is a valid attester
    /// @param attester_ Address to check
    /// @return True if the address is authorized as attester
    function isAttester(address attester_) external view returns (bool) {
        return _attesters[attester_];
    }

    /// @notice Executes a payment authorized by the payer and attested by CPN attester
    /// @dev Pulls value+fee from payer and/or incentive provider using Permit2 and distributes to payee and
    /// beneficiary.
    ///      For non-incentive payments (payerAmount == payeeSettlementAmount), intent.incentiveProvider must be
    /// address(0).
    /// @param intent Full PaymentIntent struct including nonce, value, fee, time window, etc.
    /// @param payerData Permit2 permit and signature from the payer
    /// @param incentiveData Permit2 permit and signature from the incentive provider (for incentive case)
    /// @param payeeSignature Optional signature from payee (required if intent.requirePayeeSign is true)
    /// @param fee Fee amount to collect for this payment (must not exceed intent.maxFee)
    // slither-disable-next-line cyclomatic-complexity,timestamp
    function execute(
        PaymentIntent calldata intent,
        Permit2Data calldata payerData,
        Permit2Data calldata incentiveData,
        bytes calldata payeeSignature,
        uint256 fee
    ) external nonReentrant whenNotPaused onlyAttester {
        if (_msgSender() != intent.attester) revert InvalidAttester(_msgSender());

        address token = payerData.permit.permitted.token;

        if (_nonceStatus[intent.nonce] != NonceStatus.Unused) {
            revert InvalidNonceState(intent.nonce, _nonceStatus[intent.nonce]);
        }
        if (block.timestamp < intent.validAfter) revert NotYetValid();
        if (block.timestamp > intent.validBefore) revert ExpiredIntent();
        if (intent.to == address(0)) revert InvalidPayee();
        if (fee > intent.maxFee) revert FeeExceedsMax(fee, intent.maxFee);
        if (payerData.permit.permitted.amount != intent.payerAmount + intent.maxFee) {
            revert PermitAmountMismatch();
        }

        _nonceStatus[intent.nonce] = NonceStatus.Executed;

        uint256 incentiveAmount = 0;
        if (intent.payerAmount < intent.payeeSettlementAmount) {
            incentiveAmount = intent.payeeSettlementAmount - intent.payerAmount;
        } else if (intent.payerAmount != intent.payeeSettlementAmount) {
            revert PayerAmountMismatch();
        } else {
            if (intent.incentiveProvider != address(0)) revert InvalidIncentiveProvider();
        }

        _paymentRecordHashes[intent.nonce] = _hashPaymentRecord(
            token, intent.from, intent.incentiveProvider, intent.payerAmount, intent.payeeSettlementAmount, fee
        );

        emit NonceUsed(
            intent.nonce,
            _msgSender(),
            token,
            intent.from,
            intent.to,
            intent.payerAmount,
            intent.payeeSettlementAmount,
            intent.beneficiary,
            fee
        );

        if (intent.requirePayeeSign || payeeSignature.length != 0) {
            _requireValidPayeeSig(intent, token, payeeSignature);
            emit PayeeVerified(intent.nonce, intent.to);
        }

        if (incentiveAmount > 0) {
            if (incentiveData.permit.permitted.token != token) revert InvalidToken();
            if (incentiveData.permit.permitted.amount != incentiveAmount) revert InvalidIncentiveAmount();
            emit SettlementIncentivized(intent.nonce, intent.incentiveProvider, token, incentiveAmount);
            _pullViaPermit2(
                incentiveData,
                intent.incentiveProvider,
                address(this),
                _hashIncentiveConsent(intent),
                _WITNESS_INCENTIVE_TYPE_STR,
                incentiveAmount
            );
        }

        _pullViaPermit2(
            payerData,
            intent.from,
            address(this),
            _hashPayerPaymentIntent(intent),
            _WITNESS_PAYMENT_TYPE_STR,
            intent.payerAmount + fee
        );
        if (fee != 0) {
            if (intent.beneficiary == address(0)) revert InvalidBeneficiary();
            IERC20(token).safeTransfer(intent.beneficiary, fee);
        }
        IERC20(token).safeTransfer(intent.to, intent.payeeSettlementAmount);
    }

    /// @notice Cancels a payment intent before it is executed.
    /// @dev Marks the intent nonce as cancelled and pulls the fee from the payer via Permit2.
    /// @param intent PaymentIntent (only used fields: from, nonce, beneficiary, maxFee, attester).
    /// @param data Permit2 permit and signature authorizing the fee transfer.
    /// @param fee The fee for cancellation.
    function cancel(PaymentIntent calldata intent, Permit2Data calldata data, uint256 fee)
        external
        nonReentrant
        whenNotPaused
        onlyAttester
    {
        if (_msgSender() != intent.attester) revert InvalidAttester(_msgSender());

        if (_nonceStatus[intent.nonce] != NonceStatus.Unused) {
            revert InvalidNonceState(intent.nonce, _nonceStatus[intent.nonce]);
        }
        if (fee > intent.maxFee) revert FeeExceedsMax(fee, intent.maxFee);
        if (data.permit.permitted.amount != intent.maxFee) revert PermitAmountMismatch();

        _nonceStatus[intent.nonce] = NonceStatus.Cancelled;
        emit NonceCancelled(intent.nonce, _msgSender(), data.permit.permitted.token, intent.beneficiary, fee);

        address beneficiary = intent.beneficiary;
        if (beneficiary == address(0)) {
            if (fee != 0) revert InvalidBeneficiary();
            // Zero-fee cancellation: still consume the Permit2 nonce by pulling 0 to address(this)
            beneficiary = address(this);
        }

        _pullViaPermit2(
            data, intent.from, beneficiary, _hashPayerCancelPaymentIntent(intent), _WITNESS_CANCEL_TYPE_STR, fee
        );
    }

    /// @notice Executes a refund by pulling funds from payeeRefundFrom and/or beneficiaryRefundFrom
    /// @dev Pulls from refund source wallets, distributes to payerRefundTo and incentiveProviderRefundTo
    /// @param intent Refund intent with dual amount fields and conditional signature flags
    /// @param payeeRefundData Permit2 permit and signature from payeeRefundFrom
    /// @param beneficiaryRefundData Permit2 permit and signature from beneficiaryRefundFrom
    /// @param payerSignature Payer's EIP-712 refund signature (required if intent.requireDestinationRefundSig or
    /// non-empty)
    /// @param incentiveProviderSignature Incentive provider's EIP-712 refund signature (required if
    /// intent.requireDestinationRefundSig and original incentive case, or non-empty)
    // slither-disable-next-line cyclomatic-complexity,timestamp
    function refund(
        RefundIntent calldata intent,
        Permit2Data calldata payeeRefundData,
        Permit2Data calldata beneficiaryRefundData,
        bytes calldata payerSignature,
        bytes calldata incentiveProviderSignature
    ) external nonReentrant whenNotPaused onlyAttester {
        if (_msgSender() != intent.attester) revert InvalidAttester(_msgSender());

        _validateRefund(intent, payerSignature, incentiveProviderSignature);

        uint256 payerCap = intent.payerAmount + intent.fee;
        uint256 incentiveCap = intent.payeeSettlementAmount - intent.payerAmount;
        (uint256 newCumPayer, uint256 newCumIncentive) = _checkAndComputeCumulativeRefund(
            intent.nonce, intent.payerRefundAmount, intent.incentiveProviderRefundAmount, payerCap, incentiveCap
        );

        _applyRefundStateAndEmit(intent, newCumPayer, newCumIncentive);

        _executeRefundTransfers(intent, payeeRefundData, beneficiaryRefundData);
    }

    /// @notice Disabled by design – ownership must always be assigned.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Returns the current status of a nonce.
    /// @param nonce The nonce to check
    /// @return The current NonceStatus
    function getNonceStatus(bytes32 nonce) external view returns (NonceStatus) {
        return _nonceStatus[nonce];
    }

    /// @notice Returns the payment record hash associated with a nonce.
    /// @param nonce The nonce to look up
    /// @return The keccak256 hash of (token, payer, incentiveProvider, payerAmount, payeeSettlementAmount, fee)
    function getPaymentRecordHash(bytes32 nonce) external view returns (bytes32) {
        return _paymentRecordHashes[nonce];
    }

    /// @notice Computes the payment record hash from the given fields.
    /// @param token Token address
    /// @param payer Payer address
    /// @param incentiveProvider Incentive provider address (or address(0))
    /// @param payerAmount Payer amount
    /// @param payeeSettlementAmount Payee settlement amount
    /// @param fee Actual fee charged
    /// @return The keccak256 hash matching the format stored by execute()
    function hashPaymentRecord(
        address token,
        address payer,
        address incentiveProvider,
        uint256 payerAmount,
        uint256 payeeSettlementAmount,
        uint256 fee
    ) external pure returns (bytes32) {
        return _hashPaymentRecord(token, payer, incentiveProvider, payerAmount, payeeSettlementAmount, fee);
    }

    /// @notice Returns the EIP-712 domain separator
    /// @return bytes32 The domain separator hash
    function domainSeparator() public view returns (bytes32) {
        return _CACHED_DOMAIN_SEPARATOR;
    }

    /// @notice Returns cumulative refunded amounts for a payment nonce
    function getRefundProgress(bytes32 nonce)
        external
        view
        returns (uint256 cumulativePayerRefunded, uint256 cumulativeIncentiveRefunded)
    {
        return (_cumulativePayerRefunded[nonce], _cumulativeIncentiveRefunded[nonce]);
    }

    /// @dev Constructs the full EIP-712 message digest for a structHash
    /// @param structHash The hashed structured data
    /// @return bytes32 Digest hash
    function _messageHash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @dev Verifies the EIP-712 signature from the payee
    /// @param intent The PaymentIntent being verified
    /// @param token The payment token address (not in Permit2, so must be bound explicitly)
    /// @param sig Signature bytes from payee
    function _requireValidPayeeSig(PaymentIntent calldata intent, address token, bytes calldata sig) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYEE_PAYMENT_INTENT_TYPEHASH,
                token,
                intent.from,
                intent.to,
                intent.payeeSettlementAmount,
                intent.validAfter,
                intent.validBefore,
                intent.nonce,
                intent.attester
            )
        );
        bytes32 digest = _messageHash(structHash);
        if (!SignatureChecker.isValidSignatureNow(intent.to, digest, sig)) revert InvalidSignature();
    }

    /// @dev Computes hash of the Payer-signed PaymentIntent struct
    /// @param intent The PaymentIntent struct
    /// @return bytes32 Struct hash
    function _hashPayerPaymentIntent(PaymentIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PAYER_PAYMENT_INTENT_TYPEHASH,
                intent.from,
                intent.to,
                intent.payerAmount,
                intent.validAfter,
                intent.validBefore,
                intent.nonce,
                intent.beneficiary,
                intent.maxFee,
                intent.requirePayeeSign,
                intent.attester
            )
        );
    }

    /// @dev Computes hash of IncentiveConsent witness struct
    /// @param intent Payment intent
    /// @return bytes32 Struct hash
    function _hashIncentiveConsent(PaymentIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INCENTIVE_CONSENT_TYPEHASH,
                intent.from,
                intent.to,
                intent.payerAmount,
                intent.payeeSettlementAmount,
                intent.validAfter,
                intent.validBefore,
                intent.nonce,
                intent.maxFee,
                intent.attester
            )
        );
    }

    /// @dev Computes hash of the Payer-signed cancel intent struct
    /// @param intent The PaymentIntent struct
    /// @return bytes32 Struct hash
    function _hashPayerCancelPaymentIntent(PaymentIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PAYER_CANCEL_PAYMENT_INTENT_TYPEHASH,
                intent.from,
                intent.nonce,
                intent.beneficiary,
                intent.maxFee,
                intent.attester
            )
        );
    }

    /// @dev Computes hash of PayeeRefundSource witness struct
    /// @param intent Refund intent
    /// @return bytes32 Struct hash
    function _hashPayeeRefundSource(RefundIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PAYEE_REFUND_SOURCE_TYPEHASH,
                intent.payeeRefundFrom,
                intent.validAfter,
                intent.validBefore,
                intent.nonce,
                intent.payerRefundAmount,
                intent.incentiveProviderRefundAmount,
                intent.payerRefundTo,
                intent.incentiveProviderRefundTo,
                intent.requireDestinationRefundSig,
                intent.attester
            )
        );
    }

    /// @dev Computes hash of BeneficiaryRefundSource witness struct
    /// @param intent Refund intent
    /// @return bytes32 Struct hash
    function _hashBeneficiaryRefundSource(RefundIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                BENEFICIARY_REFUND_SOURCE_TYPEHASH,
                intent.beneficiaryRefundFrom,
                intent.validAfter,
                intent.validBefore,
                intent.nonce,
                intent.payerRefundAmount,
                intent.incentiveProviderRefundAmount,
                intent.payerRefundTo,
                intent.incentiveProviderRefundTo,
                intent.requireDestinationRefundSig,
                intent.attester
            )
        );
    }

    /// @dev Pulls tokens via Permit2 witness transfer and verifies received amount
    /// @param data Permit2 permit and signature
    /// @param from Token owner authorizing the transfer
    /// @param to Recipient of the tokens
    /// @param witnessHash EIP-712 hash of the witness struct
    /// @param witnessType EIP-712 witness type string
    /// @param amount Expected number of tokens to receive
    function _pullViaPermit2(
        Permit2Data calldata data,
        address from,
        address to,
        bytes32 witnessHash,
        string memory witnessType,
        uint256 amount
    ) private {
        IERC20 tkn = IERC20(data.permit.permitted.token);
        uint256 beforeBal = tkn.balanceOf(to);
        IMinimalPermit2.SignatureTransferDetails memory details =
            IMinimalPermit2.SignatureTransferDetails({to: to, requestedAmount: amount});
        permit2.permitWitnessTransferFrom(data.permit, details, from, witnessHash, witnessType, data.signature);
        if (tkn.balanceOf(to) - beforeBal != amount) revert InvalidAmount();
    }

    /// @dev Verifies EIP-712 refund signature (used for both payer and incentive provider)
    /// @param signer Address that must have signed the digest
    /// @param typehash EIP-712 typehash (payer or incentive provider)
    /// @param intent Refund intent struct
    /// @param refundAmount Refund amount bound to this signer
    /// @param refundTo Destination address for this signer's refund
    /// @param cumulativePayerRefunded Current on-chain cumulative payer refunded for this nonce
    /// @param cumulativeIncentiveRefunded Current on-chain cumulative incentive refunded for this nonce
    /// @param sig Signature bytes
    function _requireValidRefundSig(
        address signer,
        bytes32 typehash,
        RefundIntent calldata intent,
        uint256 refundAmount,
        address refundTo,
        uint256 cumulativePayerRefunded,
        uint256 cumulativeIncentiveRefunded,
        bytes calldata sig
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encodePacked(
                abi.encode(typehash, intent.token, refundAmount, intent.validAfter, intent.validBefore),
                abi.encode(
                    intent.nonce, refundTo, cumulativePayerRefunded, cumulativeIncentiveRefunded, intent.attester
                )
            )
        );
        bytes32 digest = _messageHash(structHash);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, sig)) revert InvalidSignature();
    }

    /// @dev Computes the payment record hash from the given fields.
    /// @param token Token address
    /// @param payer Payer address
    /// @param incentiveProvider Incentive provider address (or address(0))
    /// @param payerAmount Payer amount
    /// @param payeeSettlementAmount Payee settlement amount
    /// @param fee Actual fee charged
    /// @return The keccak256 hash of the encoded fields
    function _hashPaymentRecord(
        address token,
        address payer,
        address incentiveProvider,
        uint256 payerAmount,
        uint256 payeeSettlementAmount,
        uint256 fee
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, payer, incentiveProvider, payerAmount, payeeSettlementAmount, fee));
    }

    /// @dev Validates nonce state, payment record hash, time window, and conditional refund signatures.
    ///      Reverts if the nonce is not Executed, if the record hash does not match, if the intent
    ///      is outside its validity window, or if a required signature is invalid.
    /// @param intent The refund intent containing all refund parameters and verification fields
    /// @param payerSignature Payer's EIP-712 refund signature (verified if requireDestinationRefundSig or non-empty)
    /// @param incentiveProviderSignature Incentive provider's EIP-712 refund signature (verified if
    /// requireDestinationRefundSig and original incentive case, or non-empty)
    function _validateRefund(
        RefundIntent calldata intent,
        bytes calldata payerSignature,
        bytes calldata incentiveProviderSignature
    ) internal {
        if (_nonceStatus[intent.nonce] != NonceStatus.Executed) {
            revert InvalidNonceState(intent.nonce, _nonceStatus[intent.nonce]);
        }

        bytes32 recordHash = _hashPaymentRecord(
            intent.token,
            intent.payer,
            intent.incentiveProvider,
            intent.payerAmount,
            intent.payeeSettlementAmount,
            intent.fee
        );
        if (recordHash != _paymentRecordHashes[intent.nonce]) revert InvalidPaymentRecord();

        if (block.timestamp < intent.validAfter) revert NotYetValid();
        if (block.timestamp > intent.validBefore) revert ExpiredIntent();

        if (intent.requireDestinationRefundSig || payerSignature.length != 0) {
            _requireValidRefundSig(
                intent.payer,
                PAYER_REFUND_TYPEHASH,
                intent,
                intent.payerRefundAmount,
                intent.payerRefundTo,
                _cumulativePayerRefunded[intent.nonce],
                _cumulativeIncentiveRefunded[intent.nonce],
                payerSignature
            );
            emit PayerRefundVerified(intent.nonce, intent.payer);
        }

        bool isIncentiveCase = intent.payeeSettlementAmount > intent.payerAmount;
        if ((intent.requireDestinationRefundSig && isIncentiveCase) || incentiveProviderSignature.length != 0) {
            _requireValidRefundSig(
                intent.incentiveProvider,
                INCENTIVE_PROVIDER_REFUND_TYPEHASH,
                intent,
                intent.incentiveProviderRefundAmount,
                intent.incentiveProviderRefundTo,
                _cumulativePayerRefunded[intent.nonce],
                _cumulativeIncentiveRefunded[intent.nonce],
                incentiveProviderSignature
            );
            emit IncentiveProviderRefundVerified(intent.nonce, intent.incentiveProvider);
        }
    }

    /// @dev Pulls refund funds from payeeRefundFrom and/or beneficiaryRefundFrom via Permit2 and distributes
    ///      to payerRefundTo and incentiveProviderRefundTo. Validates that source amounts
    ///      sum to total refund amounts and that tokens match the intent token.
    /// @param intent The refund intent specifying amounts, recipients, and token
    /// @param payeeRefundData Permit2 permit and signature authorizing transfer from payeeRefundFrom
    /// @param beneficiaryRefundData Permit2 permit and signature authorizing transfer from beneficiaryRefundFrom
    function _executeRefundTransfers(
        RefundIntent calldata intent,
        Permit2Data calldata payeeRefundData,
        Permit2Data calldata beneficiaryRefundData
    ) internal {
        uint256 payeeAmount = payeeRefundData.permit.permitted.amount;
        uint256 beneficiaryAmount = beneficiaryRefundData.permit.permitted.amount;

        if (payeeAmount + beneficiaryAmount != intent.payerRefundAmount + intent.incentiveProviderRefundAmount) {
            revert RefundAmountMismatch();
        }
        if (payeeAmount > 0) {
            if (payeeRefundData.permit.permitted.token != intent.token) revert InvalidToken();
            _pullViaPermit2(
                payeeRefundData,
                intent.payeeRefundFrom,
                address(this),
                _hashPayeeRefundSource(intent),
                _WITNESS_PAYEE_REFUND_SOURCE_TYPE_STR,
                payeeAmount
            );
        }

        if (beneficiaryAmount > 0) {
            if (beneficiaryRefundData.permit.permitted.token != intent.token) revert InvalidToken();
            _pullViaPermit2(
                beneficiaryRefundData,
                intent.beneficiaryRefundFrom,
                address(this),
                _hashBeneficiaryRefundSource(intent),
                _WITNESS_BENEFICIARY_REFUND_SOURCE_TYPE_STR,
                beneficiaryAmount
            );
        }

        IERC20 tokenContract = IERC20(intent.token);

        if (intent.payerRefundAmount > 0) {
            if (intent.payerRefundTo == address(0)) revert InvalidRefundDestination(intent.payerRefundTo);
            tokenContract.safeTransfer(intent.payerRefundTo, intent.payerRefundAmount);
        }
        if (intent.incentiveProviderRefundAmount > 0) {
            if (intent.incentiveProviderRefundTo == address(0)) {
                revert InvalidRefundDestination(intent.incentiveProviderRefundTo);
            }
            tokenContract.safeTransfer(intent.incentiveProviderRefundTo, intent.incentiveProviderRefundAmount);
        }
    }

    /// @dev Validates that the requested refund amounts do not exceed per-party caps and
    ///      returns the new cumulative totals. Reverts with RefundExceedsCeiling if any
    ///      cumulative total would exceed its cap.
    /// @param nonce The payment nonce to look up current cumulative totals
    /// @param payerRefundAmount Payer refund amount for this call
    /// @param incentiveProviderRefundAmount Incentive provider refund amount for this call
    /// @param payerCap Maximum cumulative payer refund (payerAmount + fee)
    /// @param incentiveCap Maximum cumulative incentive refund (payeeSettlementAmount - payerAmount)
    /// @return newCumPayer Updated cumulative payer refunded amount
    /// @return newCumIncentive Updated cumulative incentive provider refunded amount
    function _checkAndComputeCumulativeRefund(
        bytes32 nonce,
        uint256 payerRefundAmount,
        uint256 incentiveProviderRefundAmount,
        uint256 payerCap,
        uint256 incentiveCap
    ) internal view returns (uint256 newCumPayer, uint256 newCumIncentive) {
        uint256 cumPayer = _cumulativePayerRefunded[nonce];
        uint256 cumIncentive = _cumulativeIncentiveRefunded[nonce];
        newCumPayer = cumPayer + payerRefundAmount;
        newCumIncentive = cumIncentive + incentiveProviderRefundAmount;
        if (newCumPayer > payerCap) revert RefundExceedsCeiling();
        if (newCumIncentive > incentiveCap) revert RefundExceedsCeiling();
    }

    /// @dev Applies cumulative refund state updates and emits NonceRefunded and (conditionally) IncentiveRefunded.
    /// @dev Extracted from refund() to reduce stack depth under coverage instrumentation.
    /// @param intent The refund intent containing all refund parameters
    /// @param newCumPayer Updated cumulative payer refunded amount
    /// @param newCumIncentive Updated cumulative incentive provider refunded amount
    function _applyRefundStateAndEmit(RefundIntent calldata intent, uint256 newCumPayer, uint256 newCumIncentive)
        internal
    {
        uint256 payerCap = intent.payerAmount + intent.fee;
        uint256 incentiveCap = intent.payeeSettlementAmount - intent.payerAmount;

        _cumulativePayerRefunded[intent.nonce] = newCumPayer;
        if (incentiveCap > 0) {
            _cumulativeIncentiveRefunded[intent.nonce] = newCumIncentive;
        }
        if (newCumPayer == payerCap && newCumIncentive == incentiveCap) {
            _nonceStatus[intent.nonce] = NonceStatus.Refunded;
        }

        emit NonceRefunded(
            intent.nonce,
            _msgSender(),
            intent.payer,
            intent.token,
            intent.payerRefundAmount,
            intent.payerRefundTo,
            newCumPayer
        );

        if (intent.incentiveProvider != address(0)) {
            emit IncentiveRefunded(
                intent.nonce,
                _msgSender(),
                intent.incentiveProvider,
                intent.token,
                intent.incentiveProviderRefundAmount,
                intent.incentiveProviderRefundTo,
                newCumIncentive
            );
        }
    }
}
