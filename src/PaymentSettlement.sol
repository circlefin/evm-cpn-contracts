/**
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright (c) 2025, Circle Internet Financial, LLC.
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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title PaymentSettlement
/// @notice Circle Payments Network onchain payment contract.
contract PaymentSettlement is Initializable, Ownable2Step, Pausable, ReentrancyGuard, Rescuable, Configurable {
    using SafeERC20 for IERC20;

    /// @notice EIP-712 domain separator parameters
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 domain separator name hash
    bytes32 private constant _NAME_HASH = keccak256("PaymentSettlement");

    /// @notice EIP-712 domain separator version hash
    bytes32 private constant _VERSION_HASH = keccak256("1");

    /// @notice EIP-712 typehash for payee-signed PaymentIntent
    bytes32 public constant PAYEE_PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address attester)"
    );

    /// @notice EIP-712 typehash for payer-signed PaymentIntent
    bytes32 public constant PAYER_PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,bool requirePayeeSign,address attester)"
    );

    /// @notice EIP-712 typehash for payer cancel intent
    bytes32 public constant PAYER_CANCEL_PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address from,bytes32 nonce,address beneficiary,uint256 maxFee)");

    /// @notice EIP-712 witness type string for payment intent
    string public constant _WITNESS_PAYMENT_TYPE_STR = "PaymentIntent witness)"
        "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,bool requirePayeeSign,address attester)"
        "TokenPermissions(address token,uint256 amount)";

    /// @notice EIP-712 witness type string for cancel intent
    string public constant _WITNESS_CANCEL_TYPE_STR = "PaymentIntent witness)"
        "PaymentIntent(address from,bytes32 nonce,address beneficiary,uint256 maxFee)"
        "TokenPermissions(address token,uint256 amount)";

    /// @dev EIP-712 structured data representing an offchain-signed payment intent
    struct PaymentIntent {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        address beneficiary;
        uint256 maxFee;
        bool requirePayeeSign;
        address attester;
    }

    /// @dev Data structure containing Permit2 permit and the payer's signature
    struct PayerData {
        IMinimalPermit2.PermitTransferFrom permit;
        bytes signature;
    }

    /// @dev Bundled parameters for a single Permit2 pull – keeps the stack shallow
    struct PullParams {
        bytes32 witnessHash;
        string witnessType;
        uint256 amount;
    }

    /// @dev Tracks used payment intent nonces to prevent replay
    mapping(bytes32 => bool) private _nonceUsed;

    /// @dev Mapping of authorized attesters
    mapping(address => bool) private _attesters;

    /// @dev Uniswap Permit2 contract
    IMinimalPermit2 public permit2;

    /// @notice Emitted when a new attester is added
    event AttesterAdded(address indexed attester);

    /// @notice Emitted when an attester is removed
    event AttesterRemoved(address indexed attester);

    /// @notice Emitted when a payee signature is verified
    event PayeeVerified(bytes32 indexed nonce, address indexed payee);

    /// @notice Emitted when a nonce is used
    event NonceUsed(
        bytes32 indexed nonce,
        address indexed attester,
        address token,
        address payer,
        address payee,
        uint256 value,
        address beneficiary,
        uint256 fee
    );

    /// @notice Emitted when a nonce is cancelled
    event NonceCancelled(bytes32 indexed nonce, address indexed attester, address beneficiary, uint256 fee);

    /// @notice Emitted when a nonce is used
    error AlreadyUsed(bytes32 nonce);

    /// @notice Emitted when an intent has expired
    error ExpiredIntent();

    /// @notice Emitted when an intent is not yet valid
    error NotYetValid();

    /// @notice Emitted when a signature is invalid
    error InvalidSignature();

    /// @notice Emitted when an attester is invalid
    error InvalidAttester(address sender);

    /// @notice Emitted when an owner is invalid
    error InvalidOwner(address owner);

    /// @notice Emitted when an amount is invalid
    error InvalidAmount();

    /// @notice Emitted when a payee is invalid
    error InvalidPayee();

    /// @notice Emitted when a Permit2 contract is invalid
    error InvalidPermit2();

    /// @notice Emitted when a beneficiary is invalid
    error InvalidBeneficiary();

    /// @notice Emitted when renouncing ownership is disabled
    error RenounceOwnershipDisabled();

    /// @notice Emitted when a fee exceeds the maximum fee
    error FeeExceedsMax(uint256 fee, uint256 maxFee);

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
    ) external initializer {
        if (address(permit2_) == address(0)) revert InvalidPermit2();
        if (owner_ == address(0)) revert InvalidOwner(owner_);

        permit2 = permit2_;

        _transferOwnership(owner_);
        _initializePauser(pauser_);
        _initializeConfigurator(configurator_);
        _initializeRescuer(rescuer_);

        uint256 len = attesters_.length;
        for (uint256 i; i < len;) {
            _attesters[attesters_[i]] = true;
            emit AttesterAdded(attesters_[i]);
            unchecked {
                ++i;
            }
        }
    }

    // slither-disable-next-line dead-code, solhint-disable-next-line no-empty-blocks
    /// @notice Initializes ownership to the deployer
    /// @dev Call `initialize` once after deployment to set roles and the attester set
    constructor() Ownable(_msgSender()) {}

    /// @notice Modifier to check if the caller is an attester
    /// @dev Reverts if the caller is not an attester
    modifier onlyAttester() {
        if (!_attesters[_msgSender()]) revert InvalidAttester(_msgSender());
        _;
    }

    /// @notice Adds a new attester address
    /// @param attester_ Address to be granted attester role
    function addAttester(address attester_) external onlyConfigurator {
        _attesters[attester_] = true;
        emit AttesterAdded(attester_);
    }

    /// @notice Removes an attester address
    /// @param attester_ Address to be revoked from attester role
    function removeAttester(address attester_) external onlyConfigurator {
        delete _attesters[attester_];
        emit AttesterRemoved(attester_);
    }

    /// @notice Checks whether an address is a valid attester
    /// @param attester_ Address to check
    /// @return True if the address is authorized as attester
    function isAttester(address attester_) external view returns (bool) {
        return _attesters[attester_];
    }

    /// @notice Executes a payment authorized by the payer and attested by CPN attester
    /// @dev Pulls value+fee from payer using Permit2 and distributes to payee and beneficiary
    /// @param intent Full PaymentIntent struct including nonce, value, fee, time window, etc.
    /// @param payerData Includes Permit2 witness permit and signature from the payer
    /// @param payeeSig Optional signature from payee (required if intent.requirePayeeSign is true)
    /// @param fee Fee amount to collect for this payment (must not exceed intent.maxFee)
    function execute(PaymentIntent calldata intent, PayerData calldata payerData, bytes calldata payeeSig, uint256 fee)
        external
        nonReentrant
        whenNotPaused
        onlyAttester
    {
        if (_msgSender() != intent.attester) revert InvalidAttester(_msgSender());
        _validateAndMarkNonce(intent);
        emit NonceUsed(
            intent.nonce,
            _msgSender(),
            payerData.permit.permitted.token,
            intent.from,
            intent.to,
            intent.value,
            intent.beneficiary,
            fee
        );
        _validateTimeWindow(intent.validAfter, intent.validBefore);
        if (intent.to == address(0)) revert InvalidPayee();

        // Fee must not exceed maxFee in the signed intent
        if (fee > intent.maxFee) revert FeeExceedsMax(fee, intent.maxFee);
        // Ensure payer provides exact amount (value + fee)
        if (payerData.permit.permitted.amount != intent.value + intent.maxFee) {
            revert InvalidAmount();
        }

        // Payee signature validation if required
        if (intent.requirePayeeSign || payeeSig.length != 0) {
            _requireValidPayeeSig(intent, payerData.permit.permitted.token, payeeSig);
            emit PayeeVerified(intent.nonce, intent.to);
        }

        // Pull funds (value + fee)
        _pullViaPermit2(
            payerData,
            intent.from,
            address(this),
            PullParams({
                witnessHash: _hashPayerPaymentIntent(intent),
                witnessType: _WITNESS_PAYMENT_TYPE_STR,
                amount: intent.value + fee
            })
        );

        // Fee handling
        if (fee != 0) {
            if (intent.beneficiary == address(0)) revert InvalidBeneficiary();
            IERC20(payerData.permit.permitted.token).safeTransfer(intent.beneficiary, fee);
        }

        // Transfer net to payee
        IERC20(payerData.permit.permitted.token).safeTransfer(intent.to, intent.value);
    }

    /// @notice Cancels a payment intent before it is executed.
    /// @dev Marks the intent nonce as used and pulls the fee from the payer via Permit2. No payment is executed.
    /// @param intent PaymentIntent (only used fields: from, nonce, beneficiary, maxFee).
    /// @param data Permit2 permit and signature authorizing the fee transfer.
    /// @param fee The fee for cancellation.
    function cancel(PaymentIntent calldata intent, PayerData calldata data, uint256 fee)
        external
        nonReentrant
        whenNotPaused
        onlyAttester
    {
        if (_msgSender() != intent.attester) revert InvalidAttester(_msgSender());
        _validateAndMarkNonce(intent);
        emit NonceCancelled(intent.nonce, _msgSender(), intent.beneficiary, fee);
        if (fee > intent.maxFee) revert FeeExceedsMax(fee, intent.maxFee);
        if (data.permit.permitted.amount != intent.maxFee) revert InvalidAmount();
        address beneficiary = intent.beneficiary;
        if (intent.beneficiary == address(0)) {
            if (fee == 0) {
                beneficiary = address(this);
            } else {
                revert InvalidBeneficiary();
            }
        }
        _pullViaPermit2(
            data,
            intent.from,
            beneficiary,
            PullParams({
                witnessHash: _hashPayerCancelPaymentIntent(intent),
                witnessType: _WITNESS_CANCEL_TYPE_STR,
                amount: fee
            })
        );
    }

    /// @notice Disabled by design – ownership must always be assigned.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Returns true if the given nonce has already been used.
    /// @param nonce The nonce to check
    /// @return True if the nonce has already been used
    function isNonceUsed(bytes32 nonce) public view returns (bool) {
        return _nonceUsed[nonce];
    }

    /// @dev Validates the intent nonce and marks it as used
    /// @param intent PaymentIntent to validate and mark
    function _validateAndMarkNonce(PaymentIntent calldata intent) internal {
        if (isNonceUsed(intent.nonce)) revert AlreadyUsed(intent.nonce);
        _nonceUsed[intent.nonce] = true;
    }

    /// @dev Validates that the current time is within the valid time window
    /// @param after_ Timestamp after which the intent becomes valid
    /// @param before_ Timestamp after which the intent expires
    function _validateTimeWindow(uint256 after_, uint256 before_) internal view {
        if (block.timestamp < after_) revert NotYetValid();
        if (block.timestamp > before_) revert ExpiredIntent();
    }

    /// @notice Returns the EIP-712 domain separator
    /// @return bytes32 The domain separator hash
    function _domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    /// @dev Constructs the full EIP-712 message digest for a structHash
    /// @param structHash The hashed structured data
    /// @return bytes32 Digest hash
    function _messageHash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @dev Verifies the EIP-712 signature from the payee
    /// @param intent The PaymentIntent being verified
    /// @param token ERC20 token address involved in payment
    /// @param sig Signature bytes from payee
    function _requireValidPayeeSig(PaymentIntent calldata intent, address token, bytes calldata sig) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYEE_PAYMENT_INTENT_TYPEHASH,
                token,
                intent.from,
                intent.to,
                intent.value,
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
                intent.value,
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

    /// @dev Computes hash of the Payer-signed cancel intent struct
    /// @param intent The PaymentIntent struct (partial fields used)
    /// @return bytes32 Struct hash
    function _hashPayerCancelPaymentIntent(PaymentIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PAYER_CANCEL_PAYMENT_INTENT_TYPEHASH, intent.from, intent.nonce, intent.beneficiary, intent.maxFee
            )
        );
    }

    /// @dev Pulls tokens from the payer using Permit2 witness and verifies received amount
    /// @param payerData Includes Permit2 permit and signature
    /// @param owner Token owner who authorized the permit
    /// @param to Recipient address (contract or beneficiary)
    /// @param params Bundled pull parameters (hash, type, amount)
    function _pullViaPermit2(PayerData calldata payerData, address owner, address to, PullParams memory params)
        private
    {
        IERC20 tkn = IERC20(payerData.permit.permitted.token);
        uint256 beforeBal = tkn.balanceOf(to);

        IMinimalPermit2.SignatureTransferDetails memory details =
            IMinimalPermit2.SignatureTransferDetails({to: to, requestedAmount: params.amount});

        permit2.permitWitnessTransferFrom(
            payerData.permit, details, owner, params.witnessHash, params.witnessType, payerData.signature
        );

        uint256 received = tkn.balanceOf(to) - beforeBal;
        if (received != params.amount) revert InvalidAmount();
    }
}
