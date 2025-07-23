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

/// ───────────────────────────────────────── IMPORTS ──────────────────────────────────────────

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

/// @title CPNPayment
/// @notice Circle Payments Network onchain payment contract.
contract CPNPayment is Initializable, Ownable2Step, Pausable, ReentrancyGuard, Rescuable, Configurable {
    using SafeERC20 for IERC20;

    //──────────────────────────── CONSTANTS ─────────────────────────────

    // EIP-1271 magic value
    bytes4 private constant EIP1271_MAGICVALUE = 0x1626ba7e;

    // EIP‑712 domain separator parameters
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("CPNPayment");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    // Typed data hashes (see design doc p.4‑6)
    bytes32 public constant PAYEE_PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant PAYER_PAYMENT_INTENT_TYPEHASH = keccak256(
        "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 fee,bool requirePayeeSign)"
    );
    bytes32 public constant PAYER_CANCEL_PAYMENT_INTENT_TYPEHASH =
        keccak256("PaymentIntent(address from,bytes32 nonce,address beneficiary,uint256 fee)");

    //────────────── Added literal witness-type strings to move them off the stack ─────────────
    string public constant _WITNESS_PAYMENT_TYPE_STR = "PaymentIntent witness)"
        "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 fee,bool requirePayeeSign)"
        "TokenPermissions(address token,uint256 amount)";

    string public constant _WITNESS_CANCEL_TYPE_STR = "PaymentIntent witness)"
        "PaymentIntent(address from,bytes32 nonce,address beneficiary,uint256 fee)"
        "TokenPermissions(address token,uint256 amount)";

    //─────────────────────────────── STRUCTS ───────────────────────────────
    struct PaymentIntent {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        address beneficiary;
        uint256 fee; // total platform + gas fee (in token)
        bool requirePayeeSign; // whether payee signature mandatory
    }

    struct PayerData {
        IMinimalPermit2.PermitTransferFrom permit;
        bytes signature;
    }

    //──────────────────────── STATE VARIABLES ───────────────────────
    mapping(bytes32 => bool) private _nonceUsed; // paymentRef => used?

    mapping(address => bool) private _attesters; // relayer wallets

    IMinimalPermit2 public permit2; // Uniswap Permit2 contract

    //────────────────────────────── EVENTS ──────────────────────────
    event AttesterAdded(address indexed attester);
    event AttesterRemoved(address indexed attester);

    event PayeeVerified(bytes32 indexed nonce, address indexed payee);
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
    event NonceCancelled(bytes32 indexed nonce, address indexed attester, address beneficiary, uint256 fee);

    //────────────────────────────── ERRORS ──────────────────────────
    error AlreadyUsed(bytes32 nonce);
    error ExpiredIntent();
    error NotYetValid();
    error InvalidSignature();
    error InvalidAttester(address sender);
    error InvalidAmount();
    error InvalidPayee();
    error InvalidPermit2();
    error InvalidBeneficiary();
    error RenounceOwnershipDisabled();

    //───────────────────────────── INITIALIZER ─────────────────────
    function initialize(
        IMinimalPermit2 permit2_,
        address owner_,
        address rescuer_,
        address pauser_,
        address configurator_,
        address[] calldata attesters_
    ) external initializer {
        if (address(permit2_) == address(0)) revert InvalidPermit2();
        if (owner_ == address(0)) revert InvalidAttester(address(0));

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
    constructor() Ownable(msg.sender) {}

    //──────────────────────────── MODIFIERS ─────────────────────────
    modifier onlyAttester() {
        if (!_attesters[_msgSender()]) revert InvalidAttester(_msgSender());
        _;
    }

    //──────────────────────────── ADMIN FNS ─────────────────────────
    function addAttester(address a) external onlyConfigurator {
        _attesters[a] = true;
        emit AttesterAdded(a);
    }

    function removeAttester(address a) external onlyConfigurator {
        delete _attesters[a];
        emit AttesterRemoved(a);
    }

    /// @notice Returns true if the given address is an authorized attester.
    function isAttester(address a) external view returns (bool) {
        return _attesters[a];
    }

    //──────────────────────── CORE PAYMENT LOGIC ────────────────────

    /// @notice Executes a payment authorized via Permit2 witness.
    /// @dev Follows design‑doc §Payment. Pulls `value+fee` from payer, distributes fee, sends net to payee.
    /// @param intent     Full payment intent struct.
    /// @param payerData  Permit2 witness + signature.
    /// @param payeeSig   Optional payee EIP‑712 signature.
    function payment(PaymentIntent calldata intent, PayerData calldata payerData, bytes calldata payeeSig)
        external
        nonReentrant
        whenNotPaused
        onlyAttester
    {
        _validateAndMarkNonce(intent);
        _validateTimeWindow(intent.validAfter, intent.validBefore);
        if (intent.to == address(0)) revert InvalidPayee();

        // Ensure payer provides exact amount (value + fee)
        if (payerData.permit.permitted.amount != intent.value + intent.fee) {
            revert InvalidAmount();
        }

        // Payee signature validation if required
        if (intent.requirePayeeSign || payeeSig.length != 0) {
            _requireValidPayeeSig(intent, payerData.permit.permitted.token, payeeSig);
            emit PayeeVerified(intent.nonce, intent.to);
        }

        emit NonceUsed(
            intent.nonce,
            _msgSender(),
            payerData.permit.permitted.token,
            intent.from,
            intent.to,
            intent.value,
            intent.beneficiary,
            intent.fee
        );

        // Pull funds via helper to keep local-variable count low
        _pullViaPermit2(
            payerData, intent.from, address(this), _hashPayerPaymentIntent(intent), _WITNESS_PAYMENT_TYPE_STR
        );

        // Fee handling
        if (intent.fee != 0) {
            if (intent.beneficiary == address(0)) revert InvalidBeneficiary();
            IERC20(payerData.permit.permitted.token).safeTransfer(intent.beneficiary, intent.fee);
        }

        // Transfer net to payee
        IERC20(payerData.permit.permitted.token).safeTransfer(intent.to, intent.value);
    }

    /// @notice Cancels a payment intent before it is executed.
    /// @dev Funds are pulled (value+fee) and refunded minus fee.
    /// @param intent   PaymentIntent (only fields used: from, nonce, beneficiary, fee).
    /// @param data     Cancel permit + signature.
    function cancelPayment(PaymentIntent calldata intent, PayerData calldata data)
        external
        nonReentrant
        whenNotPaused
        onlyAttester
    {
        _validateAndMarkNonce(intent);

        if (data.permit.permitted.amount != intent.fee) revert InvalidAmount();

        emit NonceCancelled(intent.nonce, _msgSender(), intent.beneficiary, intent.fee);
        address beneficiary = intent.beneficiary;
        if (intent.beneficiary == address(0)) {
            if (intent.fee == 0) {
                beneficiary = address(this);
            } else {
                revert InvalidBeneficiary();
            }
        }
        _pullViaPermit2(data, intent.from, beneficiary, _hashPayerCancelPaymentIntent(intent), _WITNESS_CANCEL_TYPE_STR);
    }

    /// @notice Disabled by design – ownership must always be assigned.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Returns true if the given nonce has already been used.
    function isNonceUsed(bytes32 nonce) public view returns (bool) {
        return _nonceUsed[nonce];
    }

    //────────────────────── INTERNAL HELPERS ───────────────────────
    function _validateAndMarkNonce(PaymentIntent calldata intent) internal {
        if (isNonceUsed(intent.nonce)) revert AlreadyUsed(intent.nonce);
        _nonceUsed[intent.nonce] = true;
    }

    function _validateTimeWindow(uint256 after_, uint256 before_) internal view {
        if (block.timestamp < after_) revert NotYetValid();
        if (block.timestamp > before_) revert ExpiredIntent();
    }

    function _domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this)));
    }

    function _messageHash(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _requireValidPayeeSig(PaymentIntent calldata intent, address token, bytes calldata sig) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                PAYEE_PAYMENT_INTENT_TYPEHASH,
                token,
                intent.to,
                intent.value,
                intent.validAfter,
                intent.validBefore,
                intent.nonce
            )
        );
        bytes32 digest = _messageHash(structHash);
        if (!_verifySig(intent.to, digest, sig)) revert InvalidSignature();
    }

    function _verifySig(address signer, bytes32 digest, bytes calldata signature) internal view returns (bool ok) {
        if (signer.code.length == 0) {
            // EOA
            if (signature.length != 65) return false;
            bytes32 r;
            bytes32 s;
            uint8 v;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // `signature.offset` already points to the first byte of data.
                r := calldataload(signature.offset) // 0x00 – 0x1f
                s := calldataload(add(signature.offset, 0x20)) // 0x20 – 0x3f
                v := byte(0, calldataload(add(signature.offset, 0x40))) // first byte of the last 32-byte word
            }
            address recovered = ecrecover(digest, v, r, s);
            ok = recovered == signer && recovered != address(0);
        } else {
            // SCA
            (bool success, bytes memory result) =
                signer.staticcall(abi.encodeWithSelector(EIP1271_MAGICVALUE, digest, signature));
            ok = success && result.length == 32 && bytes4(result) == EIP1271_MAGICVALUE;
        }
    }

    function _hashPayerPaymentIntent(PaymentIntent calldata i) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                PAYER_PAYMENT_INTENT_TYPEHASH,
                i.from,
                i.to,
                i.value,
                i.validAfter,
                i.validBefore,
                i.nonce,
                i.beneficiary,
                i.fee,
                i.requirePayeeSign
            )
        );
    }

    function _hashPayerCancelPaymentIntent(PaymentIntent calldata i) internal pure returns (bytes32) {
        return keccak256(abi.encode(PAYER_CANCEL_PAYMENT_INTENT_TYPEHASH, i.from, i.nonce, i.beneficiary, i.fee));
    }

    //────────────────────────── New internal helper ──────────────────────────

    /// @dev Wraps Permit2 `permitWitnessTransferFrom` call and verifies the pull amount.
    ///      Keeps heavy locals out of the caller to avoid stack-too-deep.
    function _pullViaPermit2(
        PayerData calldata payerData,
        address payer,
        address payee,
        bytes32 witnessHash,
        string memory witnessType
    ) private returns (uint256 received) {
        IERC20 tkn = IERC20(payerData.permit.permitted.token);
        uint256 beforeBal = tkn.balanceOf(payee);

        IMinimalPermit2.SignatureTransferDetails memory details =
            IMinimalPermit2.SignatureTransferDetails({to: payee, requestedAmount: payerData.permit.permitted.amount});

        // Execute pull
        permit2.permitWitnessTransferFrom(
            payerData.permit, details, payer, witnessHash, witnessType, payerData.signature
        );

        // For safety: ensures token behaved as expected (e.g. no transfer fees or deflationary logic).
        // Some non‑standard ERC‑20s may not actually transfer the full amount.
        received = tkn.balanceOf(payee) - beforeBal;
        if (received != payerData.permit.permitted.amount) revert InvalidAmount();
    }
}
