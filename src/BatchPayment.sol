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

/// @title BatchPayment
/// @notice Circle Payments Network onchain batch payment contract, settling bulk payouts
///         (single payer, partial settlement).
/// @dev Settlement is partial: a refused row is skipped and recorded in `skippedRows` while its
///      neighbours settle, so a successful transaction does not mean every row was paid. `execute`'s
///      unsigned `requireAllRows` flag makes a single call all-or-nothing instead.
/// @dev Replay is guarded per transaction, not per row: the same rows re-signed under a fresh nonce are
///      paid again, so row-level not-paying-twice is an offchain guarantee.
contract BatchPayment is Ownable2Step, Initializable, Pausable, ReentrancyGuardTransient, Rescuable, Configurable {
    using SafeERC20 for IERC20;

    /// @dev One payment row, identified only by its position in the signed array - the index
    ///      `skippedRows` reports against
    struct Payment {
        address to;
        uint256 value;
    }

    /// @dev EIP-712 structured data representing an offchain-signed batch payment intent
    /// @dev `payments` are signed but carried in calldata instead; the settlement token is signed in
    ///      Permit2's `TokenPermissions`. Field order must match `BATCH_PAYMENT_INTENT_TYPEHASH` with
    ///      the absent `payments` field skipped - `_hashIntent` splices `paymentsHash` back in.
    struct BatchPaymentIntent {
        address from;
        uint256 totalValue;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        address beneficiary;
        uint256 maxFee;
        address attester;
    }

    /// @dev Data structure containing the Permit2 permit and the payer's signature
    struct PayerData {
        IMinimalPermit2.PermitTransferFrom permit;
        bytes signature;
    }

    /// @notice EIP-712 typehash for one payment row
    bytes32 public constant PAYMENT_TYPEHASH = keccak256("Payment(address to,uint256 value)");

    /// @notice EIP-712 typehash for the payer-signed batch payment intent
    bytes32 public constant BATCH_PAYMENT_INTENT_TYPEHASH = keccak256(
        "BatchPaymentIntent(address from,Payment[] payments,uint256 totalValue,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,address attester)Payment(address to,uint256 value)"
    );

    /// @notice EIP-712 witness type string handed to Permit2
    string public constant _WITNESS_BATCH_PAYMENT_TYPE_STR = "BatchPaymentIntent witness)"
        "BatchPaymentIntent(address from,Payment[] payments,uint256 totalValue,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,address attester)"
        "Payment(address to,uint256 value)" "TokenPermissions(address token,uint256 amount)";

    /// @dev Mapping of authorized attesters
    mapping(address => bool) private _attesters;

    /// @dev Used intent nonces, making a transaction single-use. Keyed globally with no per-payer
    ///      namespace, so uniqueness across payers depends on how the value is composed offchain.
    mapping(bytes32 => bool) private _nonceUsed;

    /// @dev Skipped-row bitmap of each completed transaction. Written only when non-empty.
    mapping(bytes32 => bytes) private _skippedRowsByNonce;

    /// @dev EIP-712 hash of the ordered payment rows reserved under each nonce.
    mapping(bytes32 => bytes32) private _paymentsHashByNonce;

    /// @dev Uniswap Permit2 contract
    IMinimalPermit2 public permit2;

    /// @notice Emitted when a new attester is added
    event AttesterAdded(address indexed attester);

    /// @notice Emitted when an attester is removed
    event AttesterRemoved(address indexed attester);

    /// @notice Emitted once per settled transaction
    /// @dev `distributed` is the amount debited for successful rows. `skippedRows` is one bit per row,
    ///      LSB-first within each byte, empty when none were skipped; bits past the last row are zero
    ///      padding. The same bitmap is returned by `batchPaymentResult` for this nonce.
    event BatchPaymentExecuted(
        bytes32 indexed nonce,
        address indexed attester,
        address indexed payer,
        address token,
        address beneficiary,
        uint256 rowCount,
        uint256 totalValue,
        uint256 distributed,
        uint256 fee,
        bytes32 paymentsHash,
        bytes skippedRows
    );

    /// @notice Thrown when an intent has expired
    error ExpiredIntent();

    /// @notice Thrown when an intent is not yet valid
    error NotYetValid();

    /// @notice Thrown when an attester is invalid
    error InvalidAttester(address sender);

    /// @notice Thrown when an owner is invalid
    error InvalidOwner(address owner);

    /// @notice Thrown when a Permit2 contract is invalid
    error InvalidPermit2();

    /// @notice Thrown when a beneficiary is invalid
    error InvalidBeneficiary();

    /// @notice Thrown when the intent nonce has already been spent
    error AlreadyUsed(bytes32 nonce);

    /// @notice Thrown when a payment row targets the zero address
    /// @dev Only the zero address is refused; every other target is a signed instruction the payer chose,
    ///      including this contract, the settlement token and Permit2.
    error InvalidRecipient(uint256 index);

    /// @notice Thrown when the token refuses a row and the caller asked for all-or-nothing
    error RowRefused(uint256 index);

    /// @notice Thrown when the charged fee exceeds the ceiling the payer signed
    error FeeExceedsMax(uint256 fee, uint256 maxFee);

    /// @notice Thrown when this contract's balance after a row is not what that row should have left
    error RowDebitMismatch(uint256 index, uint256 expected, uint256 actual);

    /// @notice Thrown when the fee transfer did not move exactly the charged fee out of this contract
    /// @dev Attributed to the fee leg rather than to row 0, so a token that mis-debits while paying the
    ///      beneficiary names the leg that caused it.
    error FeeDebitMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when this contract's token balance did not return to its pre-settlement value
    /// @dev Backstops the residual leg; the fee leg surfaces as `FeeDebitMismatch` and the row legs as
    ///      `RowDebitMismatch`.
    error AccountingMismatch(uint256 expected, uint256 actual);

    /// @notice Thrown when the permit authorizes an amount other than `totalValue + maxFee`
    error PermitAmountMismatch();

    /// @notice Thrown when the amount actually received from Permit2 is not the amount requested
    /// @dev Guards against fee-on-transfer and rebasing settlement tokens.
    error InvalidAmount();

    /// @notice Thrown when the payment rows do not sum to the signed `totalValue`
    error TotalValueMismatch(uint256 summedRows, uint256 totalValue);

    /// @notice Thrown when renouncing ownership is disabled
    error RenounceOwnershipDisabled();

    /// @notice Initializes ownership to the deployer
    /// @dev Call `initialize` once after deployment to set roles and the attester set
    // slither-disable-next-line dead-code
    constructor() Ownable(_msgSender()) {}

    /// @notice Modifier to check if the caller is an attester
    /// @dev Reverts if the caller is not an attester
    modifier onlyAttester() {
        if (!_attesters[_msgSender()]) revert InvalidAttester(_msgSender());
        _;
    }

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
        for (uint256 i; i < len; ++i) {
            address a = attesters_[i];
            if (!_attesters[a]) {
                _attesters[a] = true;
                emit AttesterAdded(a);
            }
        }
    }

    /// @notice Settles one transaction's worth of payment rows
    /// @dev A refused row is skipped; a structural defect or a token reporting a debit it did not make
    ///      reverts everything. A reverted transaction leaves the nonce usable.
    /// @dev The fee is forwarded before the first row is attempted, which is what makes it independent of
    ///      the outcome: an all-skipped transaction still pays it and still succeeds.
    /// @dev An empty `payments` array is valid when `intent.totalValue` is zero: execution succeeds without
    ///      attempting a row transfer, still charges any nonzero `fee`, records the empty outcome, and spends
    ///      the intent nonce. `requireAllRows` does not make an empty batch revert.
    /// @dev `fee` and `requireAllRows` are not fields of `BatchPaymentIntent`, so neither is covered by
    ///      the payer's signature; the attester picks both per call, and `requireAllRows` can only revert.
    /// @dev The nonce and row hash are reserved before the first external call; the bitmap is written
    ///      only once the rows have settled.
    /// @param intent Payer-signed per-transaction parameters, including `maxFee` - the fee ceiling
    /// @param payments Ordered payment rows; bound into the payer's signature via `paymentsHash`
    /// @param payerData Permit2 permit plus the payer's witness signature
    /// @param fee Fee to charge for this transaction. Must not exceed the signed `intent.maxFee`
    /// @param requireAllRows When set, a row the token refuses reverts the whole transaction
    // slither-disable-next-line reentrancy-eth,reentrancy-benign,timestamp
    function execute(
        BatchPaymentIntent calldata intent,
        Payment[] calldata payments,
        PayerData calldata payerData,
        uint256 fee,
        bool requireAllRows
    ) external nonReentrant whenNotPaused onlyAttester {
        if (_msgSender() != intent.attester) revert InvalidAttester(_msgSender());

        if (_nonceUsed[intent.nonce]) revert AlreadyUsed(intent.nonce);

        if (block.timestamp < intent.validAfter) revert NotYetValid();
        if (block.timestamp > intent.validBefore) revert ExpiredIntent();

        if (fee > intent.maxFee) revert FeeExceedsMax(fee, intent.maxFee);

        address token = payerData.permit.permitted.token;
        // Block-scoped so the figure does not stay live through the row loop.
        {
            uint256 permitted = intent.totalValue + intent.maxFee;
            if (payerData.permit.permitted.amount != permitted) revert PermitAmountMismatch();
        }

        bytes32 paymentsHash = _validateAndHashPayments(payments, intent.totalValue);

        _nonceUsed[intent.nonce] = true;
        _paymentsHashByNonce[intent.nonce] = paymentsHash;
        uint256 balanceBefore = _pullViaPermit2(payerData, intent, token, fee, paymentsHash);

        if (fee != 0) {
            if (intent.beneficiary == address(0)) revert InvalidBeneficiary();
            IERC20(token).safeTransfer(intent.beneficiary, fee);
            _assertFeeDebited(token, balanceBefore + intent.totalValue);
        }

        // The loop opens holding the principal on top of the pre-settlement balance: the pull was
        // exact and the fee has just left.
        (uint256 distributed, bytes memory skippedRows) =
            _distribute(payments, token, balanceBefore + intent.totalValue, requireAllRows);

        _returnResidual(token, intent.from, intent.totalValue - distributed, balanceBefore);

        _recordOutcome(intent, token, payments.length, distributed, fee, paymentsHash, skippedRows);
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

    /// @notice Whether an intent nonce is reserved or spent
    /// @param nonce The nonce to check
    /// @return True if a transaction is executing or has executed under this nonce
    function isNonceUsed(bytes32 nonce) public view returns (bool) {
        return _nonceUsed[nonce];
    }

    /// @notice The signed row set and settlement outcome recorded for one transaction.
    /// @param nonce `intent.nonce` of the transaction to look up
    /// @param payments Ordered payment rows to check against the row hash recorded under `nonce`
    /// @return executed True once a transaction is executing or has completed under this nonce
    /// @return paymentsMatch True when `payments` matches the ordered rows executed under this nonce.
    ///         `skippedRows` is positional against those recorded rows, so its bits are misattributed
    ///         whenever this is false.
    /// @return storedPaymentsHash Hash of the ordered rows executed under this nonce; zero when unused
    /// @return skippedRows Bitmap of rows the settlement token refused, LSB-first, returned whether or
    ///         not `payments` match. Empty when no row was skipped, when the nonce was never used, and
    ///         while a transaction is still executing - it is written only after the rows settle.
    function batchPaymentResult(bytes32 nonce, Payment[] calldata payments)
        external
        view
        returns (bool executed, bool paymentsMatch, bytes32 storedPaymentsHash, bytes memory skippedRows)
    {
        executed = _nonceUsed[nonce];
        storedPaymentsHash = _paymentsHashByNonce[nonce];
        paymentsMatch = executed && storedPaymentsHash == _hashPayments(payments);
        skippedRows = _skippedRowsByNonce[nonce];
    }

    /// @notice Disabled by design - ownership must always be assigned.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /// @notice Returns the EIP-712 array hash of a payment row set
    /// @param payments Ordered payment rows
    /// @return The array hash committed to by the payer and echoed in `BatchPaymentExecuted`
    function hashPayments(Payment[] calldata payments) external pure returns (bytes32) {
        return _hashPayments(payments);
    }

    /// @dev Stores the skipped-row bitmap, then emits the settlement event
    /// @dev Called last, so a revert stores no outcome and the earlier nonce reservation unwinds
    /// @dev Kept out of `execute`: with the event's arguments live in that frame, the non-via-IR
    ///      pipeline runs out of stack
    /// @param intent Payer-signed per-transaction parameters
    /// @param token Settlement token
    /// @param rowCount Number of payment rows attempted
    /// @param distributed Aggregate principal debited for successful rows
    /// @param fee Fee actually charged, already forwarded to the beneficiary
    /// @param paymentsHash Hash of the rows committed to by the payer
    /// @param skippedRows Bitmap of skipped rows, LSB-first; empty when none were skipped
    function _recordOutcome(
        BatchPaymentIntent calldata intent,
        address token,
        uint256 rowCount,
        uint256 distributed,
        uint256 fee,
        bytes32 paymentsHash,
        bytes memory skippedRows
    ) private {
        if (skippedRows.length != 0) _skippedRowsByNonce[intent.nonce] = skippedRows;

        emit BatchPaymentExecuted(
            intent.nonce,
            _msgSender(),
            intent.from,
            token,
            intent.beneficiary,
            rowCount,
            intent.totalValue,
            distributed,
            fee,
            paymentsHash,
            skippedRows
        );
    }

    /// @dev Transfers the principal of rows that did not settle, then asserts this contract kept none of
    ///      the funds it pulled
    /// @dev Asserted against the token's own balance rather than local sums, which would be a tautology
    /// @param token Settlement token
    /// @param payer Recipient of the residual - the single payer that funded the transaction
    /// @param refunded Principal of rows that did not settle
    /// @param balanceBefore This contract's token balance before the pull
    function _returnResidual(address token, address payer, uint256 refunded, uint256 balanceBefore) private {
        if (refunded != 0) IERC20(token).safeTransfer(payer, refunded);

        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter != balanceBefore) revert AccountingMismatch(balanceBefore, balanceAfter);
    }

    /// @dev Validates the rows, hashes them for EIP-712, and sums them against `totalValue` in one pass,
    ///      so every malformed-batch revert lands before any money moves. The sum covers all rows, so an
    ///      overstated `totalValue` cannot be quietly refunded to the payer.
    /// @param payments Ordered payment rows
    /// @param totalValue Signed total the rows must sum to
    /// @return paymentsHash EIP-712 array hash of the row set
    function _validateAndHashPayments(Payment[] calldata payments, uint256 totalValue)
        private
        pure
        returns (bytes32 paymentsHash)
    {
        uint256 rowCount = payments.length;
        bytes32[] memory rowHashes = new bytes32[](rowCount);
        // slither-disable-next-line uninitialized-local
        uint256 summedRows;

        for (uint256 i; i < rowCount; ++i) {
            Payment calldata row = payments[i];
            uint256 value = row.value;
            address to = row.to;
            rowHashes[i] = keccak256(abi.encode(PAYMENT_TYPEHASH, to, value));

            if (to == address(0)) revert InvalidRecipient(i);
            summedRows += value;
        }

        // Also establishes `distributed <= totalValue` for the caller's residual subtraction.
        if (summedRows != totalValue) revert TotalValueMismatch(summedRows, totalValue);

        paymentsHash = _hashRowHashes(rowHashes);
    }

    /// @dev Attempts every row in signed order, recording a refused one in the returned bitmap.
    /// @param payments Ordered payment rows
    /// @param token Settlement token
    /// @param expectedSelf Balance this contract must hold as the loop opens - its pre-settlement balance
    ///        plus the principal
    /// @param requireAllRows When set, a refused row reverts rather than being recorded as skipped
    /// @return distributed Total principal debited for successful rows
    /// @return skippedRows Bitmap of skipped rows, LSB-first, one bit per row; empty when none skipped
    function _distribute(Payment[] calldata payments, address token, uint256 expectedSelf, bool requireAllRows)
        private
        returns (uint256 distributed, bytes memory skippedRows)
    {
        uint256 rowCount = payments.length;
        for (uint256 i; i < rowCount; ++i) {
            Payment calldata row = payments[i];
            address to = row.to;

            bool ok = IERC20(token).trySafeTransfer(to, row.value);

            if (ok) {
                unchecked {
                    // Cannot underflow: the rows sum to the principal, which the opening balance includes.
                    expectedSelf -= row.value;
                }
                _assertRowDebited(token, i, expectedSelf);
                distributed += row.value;
            } else {
                if (requireAllRows) revert RowRefused(i);

                _assertRowDebited(token, i, expectedSelf);
                skippedRows = _markSkipped(skippedRows, rowCount, i);
            }
        }
    }

    /// @dev Verifies the fee transfer moved exactly the charged fee, leaving the principal untouched.
    ///      Kept in its own frame because `execute` has no stack room for the two locals.
    /// @param token Settlement token
    /// @param expectedSelf Balance this contract should hold once the fee has left - its pre-settlement
    ///        balance plus the whole principal
    function _assertFeeDebited(address token, uint256 expectedSelf) private view {
        uint256 actualSelf = IERC20(token).balanceOf(address(this));
        if (actualSelf != expectedSelf) revert FeeDebitMismatch(expectedSelf, actualSelf);
    }

    /// @dev Verifies this contract's balance is exactly `expectedSelf`, so a settled row debited it by
    ///      the row value and a refused row debited it by nothing.
    /// @dev This is what rejects a NONZERO row naming this contract: the transfer reports success but
    ///      moves nothing, so the balance stays too high and the row reverts as `RowDebitMismatch`.
    ///      A zero-value self-transfer owes nothing, so the same check passes; whether it settles or is
    ///      recorded as skipped is the token's call, since `trySafeTransfer`'s result is what the bitmap
    ///      records and tokens differ on whether a zero-value self-transfer succeeds.
    /// @param token Settlement token
    /// @param index Index of the row, so a mismatch is attributed rather than surfacing at the end
    /// @param expectedSelf Balance this contract should hold once this row has been attempted
    function _assertRowDebited(address token, uint256 index, uint256 expectedSelf) private view {
        // slither-disable-next-line calls-loop
        uint256 actualSelf = IERC20(token).balanceOf(address(this));
        if (actualSelf != expectedSelf) revert RowDebitMismatch(index, expectedSelf, actualSelf);
    }

    /// @dev Sets bit `index`, allocating the bitmap on the first skipped row
    /// @param bitmap Bitmap so far, empty until a row is skipped
    /// @param rowCount Number of rows the bitmap must cover
    /// @param index Index of the row to mark
    /// @return The bitmap, which the caller must take back since the first call allocates
    function _markSkipped(bytes memory bitmap, uint256 rowCount, uint256 index) private pure returns (bytes memory) {
        if (bitmap.length == 0) bitmap = new bytes((rowCount + 7) / 8);
        bitmap[index >> 3] |= bytes1(uint8(1) << uint8(index & 7));
        return bitmap;
    }

    /// @dev Pulls principal and fee together under one signature, asserting exactly `pullAmount` arrived
    /// @dev The destination is built here from `address(this)` because Permit2 does not bind it; were the
    ///      details caller-supplied, an attester could redirect the whole pull.
    /// @param payerData Permit2 permit and the payer's witness signature
    /// @param intent Payer-signed per-transaction parameters
    /// @param token Settlement token
    /// @param fee Fee being charged, already bounded by `intent.maxFee`
    /// @param paymentsHash EIP-712 array hash of the payment rows
    /// @return balanceBefore This contract's token balance before the pull
    function _pullViaPermit2(
        PayerData calldata payerData,
        BatchPaymentIntent calldata intent,
        address token,
        uint256 fee,
        bytes32 paymentsHash
    ) private returns (uint256 balanceBefore) {
        uint256 pullAmount = intent.totalValue + fee;

        IERC20 erc20 = IERC20(token);
        balanceBefore = erc20.balanceOf(address(this));

        permit2.permitWitnessTransferFrom(
            payerData.permit,
            IMinimalPermit2.SignatureTransferDetails({to: address(this), requestedAmount: pullAmount}),
            intent.from,
            _hashIntent(intent, paymentsHash),
            _WITNESS_BATCH_PAYMENT_TYPE_STR,
            payerData.signature
        );

        uint256 received = erc20.balanceOf(address(this)) - balanceBefore;
        if (received != pullAmount) revert InvalidAmount();
    }

    /// @dev Computes the EIP-712 struct hash of the payer-signed intent
    /// @dev Encoding order must match `BATCH_PAYMENT_INTENT_TYPEHASH` exactly, `paymentsHash` standing
    ///      in for the signed `payments` array.
    /// @param intent Payer-signed per-transaction parameters
    /// @param paymentsHash EIP-712 array hash of the payment rows
    /// @return The struct hash
    function _hashIntent(BatchPaymentIntent calldata intent, bytes32 paymentsHash) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                BATCH_PAYMENT_INTENT_TYPEHASH,
                intent.from,
                paymentsHash,
                intent.totalValue,
                intent.validAfter,
                intent.validBefore,
                intent.nonce,
                intent.beneficiary,
                intent.maxFee,
                intent.attester
            )
        );
    }

    /// @dev Computes the EIP-712 hash of a dynamic array of `Payment` structs
    /// @param payments Ordered payment rows
    /// @return The array hash
    function _hashPayments(Payment[] calldata payments) private pure returns (bytes32) {
        uint256 rowCount = payments.length;
        bytes32[] memory rowHashes = new bytes32[](rowCount);
        for (uint256 i; i < rowCount; ++i) {
            rowHashes[i] = keccak256(abi.encode(PAYMENT_TYPEHASH, payments[i].to, payments[i].value));
        }
        return _hashRowHashes(rowHashes);
    }

    /// @dev Hashes a `bytes32[]` in place; `abi.encodePacked` would allocate and copy a second buffer
    /// @param rowHashes Member struct hashes, in signed order
    /// @return arrayHash keccak256 over the concatenated members, identical to the encoded form
    function _hashRowHashes(bytes32[] memory rowHashes) private pure returns (bytes32 arrayHash) {
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            arrayHash := keccak256(add(rowHashes, 0x20), mul(mload(rowHashes), 0x20))
        }
    }
}
