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
// solhint-disable-next-line one-contract-per-file
pragma solidity 0.8.24;

import {BatchPayment} from "../src/BatchPayment.sol";
import {IMinimalPermit2} from "../src/interfaces/IMinimalPermit2.sol";

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/src/Test.sol";
import {Vm} from "forge-std/src/Vm.sol";

/// @dev Standard ERC20 fixture with a test-only mint entry point and an opt-in recipient blocklist.
contract BatchPaymentTestToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Mock USD Coin", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Refuses a recipient the way a blocklisting token does: nothing moves and `false` comes back,
    ///      which is the refusal `execute` records as a skip rather than reverting on.
    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) return false;
        return super.transfer(to, amount);
    }
}

/// @dev ERC20 fixture that moves the funds and then returns false for one nominated recipient.
contract BatchPaymentMovingRefusalToken is ERC20 {
    address public refuseFor;

    constructor() ERC20("Moving Refusal", "MRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRefuseFor(address to) external {
        refuseFor = to;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount);
        return to != refuseFor;
    }
}

/// @dev ERC20 fixture that takes one extra unit from the sender when paying a nominated address.
contract BatchPaymentOverDebitingToken is ERC20 {
    address public overDebitFor;

    constructor() ERC20("Over Debiting", "ODT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setOverDebitFor(address to) external {
        overDebitFor = to;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount);
        if (to == overDebitFor) _burn(_msgSender(), 1);
        return true;
    }
}

/// @dev Malicious token that calls back into `BatchPayment` once, mid-transfer, inside the payment loop.
/// @dev Reachable only with a duped or colluding payer: the settlement token is whatever the payer signed
///      into the Permit2 permit, so an attester can only relay a token the payer already named.
contract BatchPaymentReenteringToken is ERC20 {
    address public target;
    bytes public reentrantCalldata;
    bool public armed;

    /// @dev Whether the nested call was attempted, and whether it got through.
    bool public reentryAttempted;
    bool public reentrySucceeded;

    /// @dev What the nested call returned or reverted with, so a test can assert WHICH guard fired -
    ///      `onlyAttester` would reject it too, since this contract re-enters as itself.
    bytes public reentryReturnData;

    constructor() ERC20("Reentering", "REE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata reentrantCalldata_) external {
        target = target_;
        reentrantCalldata = reentrantCalldata_;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false; // One shot, so the payment loop cannot recurse forever.
            reentryAttempted = true;
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory ret) = target.call(reentrantCalldata);
            reentrySucceeded = ok;
            reentryReturnData = ret;
        }
        return super.transfer(to, amount);
    }
}

/// @dev Permit2 stub: forwards the requested transfer, verifying no signature, witness, nonce or deadline.
contract BatchPaymentDummyPermit2 is IMinimalPermit2 {
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("Permit2"),
                block.chainid,
                address(this)
            )
        );
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes32,
        string calldata,
        bytes calldata
    ) external override {
        IERC20(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount);
    }
}

abstract contract BatchPaymentTestFixture is Test {
    bytes32 internal constant PAYMENT_TYPEHASH = keccak256("Payment(address to,uint256 value)");
    bytes32 internal constant BATCH_PAYMENT_INTENT_TYPEHASH = keccak256(
        "BatchPaymentIntent(address from,Payment[] payments,uint256 totalValue,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,address attester)Payment(address to,uint256 value)"
    );
    uint160 internal constant RECIPIENT_BASE = uint160(0xC0FFEE0000);
    uint256 internal constant PAYER_PK = 0xA11CE;

    BatchPayment internal bpc;
    BatchPaymentDummyPermit2 internal permit2;
    BatchPaymentTestToken internal usdc;

    address internal payer;
    address internal attester = makeAddr("attester");
    address internal beneficiary = makeAddr("beneficiary");
    address internal rescuer = makeAddr("rescuer");
    address internal pauser = makeAddr("pauser");
    address internal configurator = makeAddr("configurator");

    function setUp() public virtual {
        payer = vm.addr(PAYER_PK);
        permit2 = new BatchPaymentDummyPermit2();
        usdc = new BatchPaymentTestToken();

        bpc = new BatchPayment();
        address[] memory attesters = new address[](1);
        attesters[0] = attester;
        bpc.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, configurator, attesters);

        usdc.mint(payer, 1_000_000_000e6);
        vm.prank(payer);
        usdc.approve(address(permit2), type(uint256).max);
        vm.warp(1_800_000_000);
    }

    function _buildPayments(uint256 rowCount, uint256 valuePerRow, uint256 seed)
        internal
        pure
        returns (BatchPayment.Payment[] memory payments)
    {
        payments = new BatchPayment.Payment[](rowCount);
        for (uint256 i; i < rowCount; ++i) {
            payments[i] = BatchPayment.Payment({to: _recipient(seed + i), value: valuePerRow});
        }
    }

    function _recipient(uint256 index) internal pure returns (address) {
        return address(RECIPIENT_BASE + uint160(index));
    }

    function _sumValues(BatchPayment.Payment[] memory payments) internal pure returns (uint256 total) {
        for (uint256 i; i < payments.length; ++i) {
            total += payments[i].value;
        }
    }

    function _nonce(uint256 seed) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp + seed));
    }

    function _intent(uint256 totalValue, uint256 maxFee)
        internal
        view
        returns (BatchPayment.BatchPaymentIntent memory)
    {
        return BatchPayment.BatchPaymentIntent({
            from: payer,
            beneficiary: beneficiary,
            totalValue: totalValue,
            maxFee: maxFee,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            attester: attester,
            nonce: _nonce(0)
        });
    }

    function _hashPayments(BatchPayment.Payment[] memory payments) internal pure returns (bytes32) {
        bytes32[] memory rowHashes = new bytes32[](payments.length);
        for (uint256 i; i < payments.length; ++i) {
            rowHashes[i] = keccak256(abi.encode(PAYMENT_TYPEHASH, payments[i].to, payments[i].value));
        }
        return keccak256(abi.encodePacked(rowHashes));
    }

    function _payerData(
        BatchPayment.BatchPaymentIntent memory intent,
        BatchPayment.Payment[] memory,
        uint256 nonce,
        uint256
    ) internal view returns (BatchPayment.PayerData memory data) {
        data.permit.permitted =
            IMinimalPermit2.TokenPermissions({token: address(usdc), amount: intent.totalValue + intent.maxFee});
        data.permit.nonce = nonce;
        data.permit.deadline = block.timestamp + 1 hours;
    }

    function _countEvent(Vm.Log[] memory logs, bytes32 sig, address indexedArg) internal pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig && logs[i].topics[1] == bytes32(uint256(uint160(indexedArg)))) ++count;
        }
    }

    /// @dev Reads the settlement event's non-indexed fields. Reverts when none was recorded, so
    ///      forgetting `vm.recordLogs()` cannot yield zero values that satisfy every assertion.
    function _decodeOutcome() internal returns (uint256 distributed, uint256 fee, bytes memory skippedRows) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(bpc)) continue;
            found = true;
            (,,,, distributed, fee,, skippedRows) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256, bytes32, bytes));
        }
        assertTrue(found, "no BatchPaymentExecuted log recorded - was vm.recordLogs() called?");
    }

    /// @dev Counts set bits the slow, obvious way, so the reference decoders are checked against something
    ///      that shares none of their arithmetic.
    function _popcountOracle(bytes memory bitmap) internal pure returns (uint256 count) {
        for (uint256 b; b < bitmap.length; ++b) {
            for (uint256 bit; bit < 8; ++bit) {
                if ((uint8(bitmap[b]) >> bit) & 1 != 0) ++count;
            }
        }
    }

    // Reference decoders for the LSB-first `skippedRows` bitmap.
    function _isRowSkipped(bytes memory skippedRows, uint256 index) internal pure returns (bool) {
        uint256 byteIndex = index >> 3;
        if (byteIndex >= skippedRows.length) return false;
        return (uint8(skippedRows[byteIndex]) >> (index & 7)) & 1 != 0;
    }

    function _skippedRowCount(bytes memory skippedRows) internal pure returns (uint256 count) {
        uint256 len = skippedRows.length;
        for (uint256 b; b < len; ++b) {
            uint8 word = uint8(skippedRows[b]);
            for (; word != 0; ++count) {
                word &= word - 1;
            }
        }
    }

    function _skippedRowIndices(bytes memory skippedRows) internal pure returns (uint256[] memory indices) {
        indices = new uint256[](_skippedRowCount(skippedRows));
        uint256 found;
        uint256 len = skippedRows.length;
        for (uint256 b; b < len; ++b) {
            uint8 word = uint8(skippedRows[b]);
            if (word == 0) continue;
            for (uint256 bit; bit < 8; ++bit) {
                if ((word >> bit) & 1 != 0) {
                    indices[found] = (b << 3) + bit;
                    ++found;
                }
            }
        }
    }
}

contract BatchPaymentTest is BatchPaymentTestFixture {
    function testWitnessStringCoupling() public view {
        string memory prefix = "BatchPaymentIntent witness)";
        string memory core =
            "BatchPaymentIntent(address from,Payment[] payments,uint256 totalValue,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,address attester)Payment(address to,uint256 value)";
        string memory suffix = "TokenPermissions(address token,uint256 amount)";

        // Ensure BATCH_PAYMENT_INTENT_TYPEHASH strictly mirrors the core string
        assertEq(bpc.BATCH_PAYMENT_INTENT_TYPEHASH(), keccak256(bytes(core)), "Typehash decoupled from core string");

        // Ensure _WITNESS_BATCH_PAYMENT_TYPE_STR perfectly wraps the exact same core string
        string memory expectedWitnessStr = string.concat(prefix, core, suffix);
        assertEq(bpc._WITNESS_BATCH_PAYMENT_TYPE_STR(), expectedWitnessStr, "Witness string decoupled from core string");
    }

    function testExecuteBatchPayment_rejectsNonceReuseAcrossPayers() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        bytes32 sharedNonce = _nonce(7);

        BatchPayment.BatchPaymentIntent memory firstIntent = _intent(10e6, 0);
        firstIntent.nonce = sharedNonce;
        BatchPayment.PayerData memory firstData = _payerData(firstIntent, payments, 0, PAYER_PK);

        vm.prank(attester);
        bpc.execute(firstIntent, payments, firstData, firstIntent.maxFee, false);

        uint256 otherPayerPk = 0xB0B;
        address otherPayer = vm.addr(otherPayerPk);
        usdc.mint(otherPayer, 1_000_000_000e6);
        vm.prank(otherPayer);
        usdc.approve(address(permit2), type(uint256).max);

        BatchPayment.BatchPaymentIntent memory secondIntent = firstIntent;
        secondIntent.from = otherPayer;
        BatchPayment.PayerData memory secondData = _payerData(secondIntent, payments, 1, otherPayerPk);

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.AlreadyUsed.selector, sharedNonce));
        bpc.execute(secondIntent, payments, secondData, secondIntent.maxFee, false);
    }

    function testExecuteBatchPayment_distributesRowsAndFee() public {
        BatchPayment.Payment[] memory payments = _buildPayments(3, 100e6, 0);
        uint256 totalValue = _sumValues(payments);
        BatchPayment.BatchPaymentIntent memory intent = _intent(totalValue, 10e6);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        for (uint256 i; i < payments.length; ++i) {
            assertEq(usdc.balanceOf(payments[i].to), 100e6);
        }
        assertEq(usdc.balanceOf(beneficiary), 10e6);
        assertEq(payerBefore - usdc.balanceOf(payer), totalValue + intent.maxFee);
        assertEq(usdc.balanceOf(address(bpc)), 0);
    }

    function testExecuteBatchPayment_duplicateRecipientsAccumulate() public {
        BatchPayment.Payment[] memory payments = _buildPayments(3, 10e6, 0);
        payments[2].to = payments[0].to;
        BatchPayment.BatchPaymentIntent memory intent = _intent(30e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        assertEq(usdc.balanceOf(payments[0].to), 20e6);
        assertEq(usdc.balanceOf(payments[1].to), 10e6);
    }

    function testExecuteBatchPayment_rejectsInvalidRecipientBeforePull() public {
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        payments[1].to = address(0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.mockCallRevert(address(permit2), bytes(""), bytes("pulled"));

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.InvalidRecipient.selector, 1));
        bpc.execute(intent, payments, data, intent.maxFee, false);

        assertEq(usdc.balanceOf(payer), payerBefore);
        assertFalse(bpc.isNonceUsed(intent.nonce));
    }

    function testExecuteBatchPayment_replayIsRejected() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        vm.startPrank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.AlreadyUsed.selector, intent.nonce));
        bpc.execute(intent, payments, data, intent.maxFee, false);
        vm.stopPrank();
    }

    function testBatchPaymentResult_recordsFullSettlement() public {
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        (bool executed, bool paymentsMatch, bytes32 storedHash, bytes memory skippedRows) =
            bpc.batchPaymentResult(intent.nonce, payments);
        assertTrue(executed);
        assertTrue(paymentsMatch);
        assertEq(storedHash, _hashPayments(payments));
        assertEq(skippedRows.length, 0);
    }

    function testInitialize_rejectsInvalidPermit2AndIsOneShot() public {
        BatchPayment fresh = new BatchPayment();
        address[] memory attesters = new address[](1);
        attesters[0] = attester;

        vm.expectRevert(BatchPayment.InvalidPermit2.selector);
        fresh.initialize(IMinimalPermit2(address(0)), address(this), rescuer, pauser, configurator, attesters);

        fresh.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, configurator, attesters);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, configurator, attesters);
    }

    function testExecuteBatchPayment_rejectsUnauthorizedCallers() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.InvalidAttester.selector, stranger));
        bpc.execute(intent, payments, data, 0, false);
    }

    function testExecuteBatchPayment_rejectsRegisteredAttesterMismatchingIntent() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        intent.attester = makeAddr("otherAttester");
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.AttesterMismatch.selector, attester, intent.attester));
        bpc.execute(intent, payments, data, 0, false);
    }

    function testInitialize_rejectsInvalidOwner() public {
        BatchPayment fresh = new BatchPayment();
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.InvalidOwner.selector, address(0)));
        fresh.initialize(IMinimalPermit2(address(permit2)), address(0), rescuer, pauser, configurator, new address[](0));
    }

    function testExecute_acceptsZeroNonce() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        intent.nonce = bytes32(0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        vm.prank(attester);
        bpc.execute(intent, payments, data, 0, false);

        assertTrue(bpc.isNonceUsed(bytes32(0)));
        assertEq(usdc.balanceOf(payments[0].to), 10e6);
    }

    function testExecuteBatchPayment_rejectsValidationFailures() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 1e6);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        data = _payerData(intent, payments, 1, PAYER_PK);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(attester);
        vm.expectRevert(BatchPayment.ExpiredIntent.selector);
        bpc.execute(intent, payments, data, 0, false);

        vm.warp(1_800_000_000);
        intent = _intent(10e6, 1e6);
        data = _payerData(intent, payments, 2, PAYER_PK);
        intent.validAfter = block.timestamp + 1;
        vm.prank(attester);
        vm.expectRevert(BatchPayment.NotYetValid.selector);
        bpc.execute(intent, payments, data, 0, false);

        intent = _intent(10e6, 1e6);
        data = _payerData(intent, payments, 3, PAYER_PK);
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.FeeExceedsMax.selector, 2e6, 1e6));
        bpc.execute(intent, payments, data, 2e6, false);

        data.permit.permitted.amount -= 1;
        vm.prank(attester);
        vm.expectRevert(BatchPayment.PermitAmountMismatch.selector);
        bpc.execute(intent, payments, data, 0, false);
    }

    function testExecuteBatchPayment_settlesAZeroRowIntentAndSpendsTheNonce() public {
        BatchPayment.Payment[] memory empty = new BatchPayment.Payment[](0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(0, 1e6);
        BatchPayment.PayerData memory data = _payerData(intent, empty, 4, PAYER_PK);
        uint256 payerBefore = usdc.balanceOf(payer);

        // A row-less intent is one the payer signed, so it settles: the fee is charged and the nonce spent.
        vm.prank(attester);
        bpc.execute(intent, empty, data, 1e6, false);

        assertTrue(bpc.isNonceUsed(intent.nonce));
        assertEq(usdc.balanceOf(beneficiary), 1e6);
        assertEq(usdc.balanceOf(payer), payerBefore - 1e6);
        assertEq(usdc.balanceOf(address(bpc)), 0);

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.AlreadyUsed.selector, intent.nonce));
        bpc.execute(intent, empty, data, 1e6, false);
    }

    function testExecuteBatchPayment_rejectsMismatchedTotalValue() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(9e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 5, PAYER_PK);

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.TotalValueMismatch.selector, 10e6, 9e6));
        bpc.execute(intent, payments, data, 0, false);
    }

    function testExecuteBatchPayment_feeLegOverDebitIsAttributedToTheFee() public {
        BatchPaymentOverDebitingToken token = new BatchPaymentOverDebitingToken();
        token.mint(payer, 1_000e6);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);
        token.setOverDebitFor(beneficiary);

        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 1e6);
        BatchPayment.PayerData memory data;
        data.permit.permitted = IMinimalPermit2.TokenPermissions({token: address(token), amount: 11e6});
        data.permit.nonce = 16;
        data.permit.deadline = block.timestamp + 1 hours;

        // The fee transfer takes one more than `fee`, so it is named on the fee leg, not on row 0.
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.FeeDebitMismatch.selector, 10e6, 10e6 - 1));
        bpc.execute(intent, payments, data, 1e6, false);
    }

    function testExecuteBatchPayment_rejectsOnlyTheZeroAddressRecipient() public {
        // The zero address is the one target refused outright, because it destroys the payer's funds.
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        payments[0].to = address(0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 10, PAYER_PK);

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.InvalidRecipient.selector, 0));
        bpc.execute(intent, payments, data, 0, false);

        // The settlement token and Permit2 are inside the payer's signature, so those rows settle.
        address[2] memory allowed = [address(usdc), address(permit2)];
        for (uint256 i; i < allowed.length; ++i) {
            payments = _buildPayments(1, 10e6, i);
            payments[0].to = allowed[i];
            intent = _intent(10e6, 0);
            intent.nonce = _nonce(i + 20);
            data = _payerData(intent, payments, i + 20, PAYER_PK);

            uint256 targetBefore = usdc.balanceOf(allowed[i]);
            vm.prank(attester);
            bpc.execute(intent, payments, data, 0, false);
            assertEq(usdc.balanceOf(allowed[i]), targetBefore + 10e6);
        }

        // A NONZERO row naming this contract moves nothing, so the per-row debit check catches it.
        payments = _buildPayments(1, 10e6, 0);
        payments[0].to = address(bpc);
        intent = _intent(10e6, 0);
        intent.nonce = _nonce(30);
        data = _payerData(intent, payments, 30, PAYER_PK);

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.RowDebitMismatch.selector, 0, 0, 10e6));
        bpc.execute(intent, payments, data, 0, false);

        // A zero-value one owes nothing, so the same check passes and this token settles it as paid.
        payments = _buildPayments(1, 0, 0);
        payments[0].to = address(bpc);
        intent = _intent(0, 0);
        intent.nonce = _nonce(31);
        data = _payerData(intent, payments, 31, PAYER_PK);

        vm.prank(attester);
        bpc.execute(intent, payments, data, 0, false);

        (,,, bytes memory skippedRows) = bpc.batchPaymentResult(intent.nonce, payments);
        assertEq(skippedRows.length, 0, "this token accepts the zero-value self-transfer, so no row is skipped");
    }

    function testExecuteBatchPayment_checksPauseAndBeneficiary() public {
        vm.prank(pauser);
        bpc.pause();

        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 1e6);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 6, PAYER_PK);
        vm.prank(attester);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        bpc.execute(intent, payments, data, 1e6, false);

        vm.prank(pauser);
        bpc.unpause();
        intent = _intent(10e6, 1e6);
        intent.beneficiary = address(0);
        data = _payerData(intent, payments, 7, PAYER_PK);
        vm.prank(attester);
        vm.expectRevert(BatchPayment.InvalidBeneficiary.selector);
        bpc.execute(intent, payments, data, 1e6, false);
    }

    function testAttesterManagementAndOwnershipGuards() public {
        address newAttester = makeAddr("newAttester");

        vm.prank(configurator);
        bpc.addAttester(newAttester);
        assertTrue(bpc.isAttester(newAttester));

        vm.prank(configurator);
        bpc.addAttester(newAttester);
        vm.prank(configurator);
        bpc.removeAttester(newAttester);
        assertFalse(bpc.isAttester(newAttester));
        vm.prank(configurator);
        bpc.removeAttester(newAttester);

        vm.expectRevert(BatchPayment.RenounceOwnershipDisabled.selector);
        bpc.renounceOwnership();
    }

    function testHashPayments_matchesIndependentValue() public view {
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        assertEq(bpc.hashPayments(payments), _hashPayments(payments));
    }

    function testBitmapHelpers_decodeRows() public pure {
        bytes memory bitmap = hex"8102";

        assertTrue(_isRowSkipped(bitmap, 0));
        assertTrue(_isRowSkipped(bitmap, 9));
        assertFalse(_isRowSkipped(bitmap, 8));
        assertFalse(_isRowSkipped(bitmap, 1));
        assertFalse(_isRowSkipped(bitmap, 16));

        uint256[] memory indices = _skippedRowIndices(bitmap);
        assertEq(indices.length, 3);
        assertEq(indices[0], 0);
        assertEq(indices[1], 7);
        assertEq(indices[2], 9);

        assertEq(_skippedRowCount(bitmap), 3);
        assertEq(_skippedRowCount(new bytes(0)), 0);
    }

    function testBatchPaymentResult_reportsUnusedAndMismatchedRows() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        (bool executed, bool paymentsMatch, bytes32 storedHash, bytes memory skippedRows) =
            bpc.batchPaymentResult(bytes32(uint256(123)), payments);
        assertFalse(executed);
        assertFalse(paymentsMatch);
        assertEq(storedHash, bytes32(0));
        assertEq(skippedRows.length, 0);

        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 9, PAYER_PK);
        vm.prank(attester);
        bpc.execute(intent, payments, data, 0, false);

        payments[0].value = 11e6;
        (executed, paymentsMatch,,) = bpc.batchPaymentResult(intent.nonce, payments);
        assertTrue(executed);
        assertFalse(paymentsMatch);
    }

    function testExecuteBatchPayment_skipsRefusedRowsAndDecodesBitmap() public {
        BatchPayment.Payment[] memory payments = _buildPayments(9, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(90e6, 1e6);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 10, PAYER_PK);
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, payments[1].to, uint256(10e6)),
            bytes("refused")
        );
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, payments[8].to, uint256(10e6)),
            bytes("refused")
        );

        vm.prank(attester);
        bpc.execute(intent, payments, data, 1e6, false);

        (,,, bytes memory skippedRows) = bpc.batchPaymentResult(intent.nonce, payments);

        assertTrue(_isRowSkipped(skippedRows, 1));
        assertTrue(_isRowSkipped(skippedRows, 8));
        assertEq(_skippedRowCount(skippedRows), 2);
        uint256[] memory indices = _skippedRowIndices(skippedRows);
        assertEq(indices[0], 1);
        assertEq(indices[1], 8);
    }

    function testExecuteBatchPayment_requireAllRowsRevertsOnRefusal() public {
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 11, PAYER_PK);
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, payments[0].to, uint256(10e6)),
            bytes("refused")
        );

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.RowRefused.selector, 0));
        bpc.execute(intent, payments, data, 0, true);
        assertFalse(bpc.isNonceUsed(intent.nonce));
    }

    function testExecuteBatchPayment_detectsPullAndRowDebitMismatches() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 12, PAYER_PK);

        vm.mockCall(
            address(usdc), abi.encodeWithSelector(IERC20.balanceOf.selector, address(bpc)), abi.encode(uint256(0))
        );
        vm.prank(attester);
        vm.expectRevert(BatchPayment.InvalidAmount.selector);
        bpc.execute(intent, payments, data, 0, false);

        vm.clearMockedCalls();
        intent = _intent(10e6, 0);
        data = _payerData(intent, payments, 13, PAYER_PK);
        vm.mockCall(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, payments[0].to, uint256(10e6)),
            abi.encode(true)
        );
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.RowDebitMismatch.selector, 0, 0, 10e6));
        bpc.execute(intent, payments, data, 0, false);
    }

    function testExecuteBatchPayment_detectsResidualAccountingMismatch() public {
        BatchPayment.Payment[] memory payments = _buildPayments(1, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(10e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 14, PAYER_PK);
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, payments[0].to, uint256(10e6)),
            bytes("refused")
        );
        vm.mockCall(
            address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, payer, uint256(10e6)), abi.encode(true)
        );

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.AccountingMismatch.selector, 0, 10e6));
        bpc.execute(intent, payments, data, 0, false);
    }

    function testExecuteBatchPayment_refusalThatMovedFundsRevertsInsteadOfSkipping() public {
        BatchPaymentMovingRefusalToken token = new BatchPaymentMovingRefusalToken();
        token.mint(payer, 1_000e6);
        vm.prank(payer);
        token.approve(address(permit2), type(uint256).max);

        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        token.setRefuseFor(payments[1].to);

        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 0);
        BatchPayment.PayerData memory data;
        data.permit.permitted = IMinimalPermit2.TokenPermissions({token: address(token), amount: 20e6});
        data.permit.nonce = 15;
        data.permit.deadline = block.timestamp + 1 hours;

        // Row 1 keeps nothing back, so it must revert rather than be recorded as a skip.
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(BatchPayment.RowDebitMismatch.selector, 1, 10e6, 0));
        bpc.execute(intent, payments, data, 0, false);
    }

    function testExecuteBatchPayment_allRowsSkippedStillPaysTheFeeAndSucceeds() public {
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 2e6);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 16, PAYER_PK);
        for (uint256 i; i < payments.length; ++i) {
            vm.mockCallRevert(
                address(usdc),
                abi.encodeWithSelector(IERC20.transfer.selector, payments[i].to, uint256(10e6)),
                bytes("refused")
            );
        }
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(attester);
        bpc.execute(intent, payments, data, 2e6, false);

        assertEq(usdc.balanceOf(beneficiary), 2e6);
        assertEq(payerBefore - usdc.balanceOf(payer), 2e6, "principal not fully refunded");
        assertEq(usdc.balanceOf(address(bpc)), 0);

        (,,, bytes memory skippedRows) = bpc.batchPaymentResult(intent.nonce, payments);
        assertEq(_skippedRowCount(skippedRows), 2);
    }

    function testExecuteBatchPayment_chargesLessThanMaxFeeAndLeavesHeadroomWithPayer() public {
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 5e6);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 17, PAYER_PK);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(attester);
        bpc.execute(intent, payments, data, 1e6, false);

        assertEq(usdc.balanceOf(beneficiary), 1e6);
        // Only totalValue + fee is pulled, so the 4e6 of unused fee headroom never leaves the payer.
        assertEq(payerBefore - usdc.balanceOf(payer), 21e6);
        assertEq(usdc.balanceOf(address(bpc)), 0);
    }

    function testExecuteBatchPayment_emitsSettlementEvent() public {
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 1e6);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 18, PAYER_PK);

        vm.expectEmit(true, true, true, true, address(bpc));
        emit BatchPayment.BatchPaymentExecuted(
            intent.nonce, attester, payer, address(usdc), beneficiary, 2, 20e6, 20e6, 1e6, _hashPayments(payments), ""
        );
        vm.prank(attester);
        bpc.execute(intent, payments, data, 1e6, false);
    }

    function testBatchPaymentResult_returnsBitmapWhenPaymentsDoNotMatch() public {
        BatchPayment.Payment[] memory payments = _buildPayments(9, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(90e6, 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 19, PAYER_PK);
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, payments[1].to, uint256(10e6)),
            bytes("refused")
        );
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, payments[8].to, uint256(10e6)),
            bytes("refused")
        );

        vm.prank(attester);
        bpc.execute(intent, payments, data, 0, false);

        payments[0].value = 11e6;
        (bool executed, bool paymentsMatch,, bytes memory skippedRows) = bpc.batchPaymentResult(intent.nonce, payments);

        assertTrue(executed);
        assertFalse(paymentsMatch);
        assertEq(skippedRows, hex"0201", "bitmap withheld when rows do not match");
    }

    function testAttesterManagement_guardsSpuriousEvents() public {
        address fresh = makeAddr("freshAttester");

        vm.recordLogs();
        vm.startPrank(configurator);
        bpc.addAttester(attester);
        bpc.removeAttester(fresh);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0, "re-add or absent-remove emitted");

        vm.recordLogs();
        vm.startPrank(configurator);
        bpc.addAttester(fresh);
        bpc.removeAttester(fresh);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "add then remove must emit exactly twice");
        assertEq(_countEvent(logs, BatchPayment.AttesterAdded.selector, fresh), 1);
        assertEq(_countEvent(logs, BatchPayment.AttesterRemoved.selector, fresh), 1);
        assertTrue(bpc.isAttester(attester));
        assertFalse(bpc.isAttester(fresh));
    }

    function testInitialize_emitsAttesterAddedOncePerUniqueAttester() public {
        BatchPayment freshContract = new BatchPayment();
        address[] memory attesters = new address[](3);
        attesters[0] = attester;
        attesters[1] = attester;
        attesters[2] = makeAddr("secondAttester");

        vm.recordLogs();
        freshContract.initialize(
            IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, configurator, attesters
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(
            _countEvent(logs, BatchPayment.AttesterAdded.selector, attester), 1, "duplicate attester emitted twice"
        );
        assertEq(_countEvent(logs, BatchPayment.AttesterAdded.selector, attesters[2]), 1);
        assertTrue(freshContract.isAttester(attesters[2]));
    }

    function testInitialize_emitsPermit2SetExactlyOnce() public {
        BatchPayment freshContract = new BatchPayment();
        address[] memory attesters = new address[](1);
        attesters[0] = attester;

        vm.recordLogs();
        freshContract.initialize(
            IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, configurator, attesters
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvent(logs, keccak256("Permit2Set(address)"), address(permit2)), 1);
    }

    function testInitialize_doesNotEmitPermit2SetWhenItReverts() public {
        BatchPayment freshContract = new BatchPayment();
        address[] memory attesters = new address[](1);
        attesters[0] = attester;

        vm.recordLogs();
        vm.expectRevert(BatchPayment.InvalidPermit2.selector);
        freshContract.initialize(IMinimalPermit2(address(0)), address(this), rescuer, pauser, configurator, attesters);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvent(logs, keccak256("Permit2Set(address)"), address(permit2)), 0);

        freshContract.initialize(
            IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, configurator, attesters
        );
        vm.recordLogs();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        freshContract.initialize(
            IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, configurator, attesters
        );
        logs = vm.getRecordedLogs();
        assertEq(_countEvent(logs, keccak256("Permit2Set(address)"), address(permit2)), 0);
    }

    function testExecuteBatchPayment_reentrancyIsBlocked() public {
        BatchPaymentReenteringToken evil = new BatchPaymentReenteringToken();
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 0);
        BatchPayment.PayerData memory data = _reenteringPayerData(evil, 20);

        evil.arm(address(bpc), abi.encodeCall(BatchPayment.execute, (intent, payments, data, intent.maxFee, false)));

        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        assertTrue(evil.reentryAttempted(), "the mock never actually re-entered");
        assertFalse(evil.reentrySucceeded(), "the reentrancy guard failed to block the nested call");
        // WHICH guard rejected it matters: `onlyAttester` would reject the nested call as well.
        assertEq(
            bytes4(evil.reentryReturnData()),
            bytes4(keccak256("ReentrancyGuardReentrantCall()")),
            "the nested call must be stopped by the reentrancy guard, not by the attester check"
        );
        assertEq(evil.balanceOf(address(bpc)), 0, "nothing may rest in the contract");
        assertEq(evil.balanceOf(payments[0].to), 10e6, "the outer settlement still completed");
    }

    function testBatchPaymentResult_readsReservedStateDuringTokenCallback() public {
        BatchPaymentReenteringToken evil = new BatchPaymentReenteringToken();
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 0);
        BatchPayment.PayerData memory data = _reenteringPayerData(evil, 21);

        evil.arm(address(bpc), abi.encodeCall(BatchPayment.batchPaymentResult, (intent.nonce, payments)));

        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        assertTrue(evil.reentryAttempted(), "the result callback was not attempted");
        assertTrue(evil.reentrySucceeded(), "the getter carries no guard, so a mid-flight read succeeds");

        // What a mid-flight reader must see: the nonce and row hash are already reserved, and the bitmap
        // is still empty because it is written only once every row has settled.
        (bool executed, bool paymentsMatch, bytes32 storedPaymentsHash, bytes memory skippedRows) =
            abi.decode(evil.reentryReturnData(), (bool, bool, bytes32, bytes));
        assertTrue(executed, "the nonce is reserved before the first external call");
        assertTrue(paymentsMatch, "the row hash is reserved alongside it");
        assertEq(storedPaymentsHash, _hashPayments(payments));
        assertEq(skippedRows.length, 0, "the bitmap is not observable while the transaction is executing");
    }

    function testIsNonceUsed_isReservedDuringTokenCallback() public {
        BatchPaymentReenteringToken evil = new BatchPaymentReenteringToken();
        BatchPayment.Payment[] memory payments = _buildPayments(2, 10e6, 0);
        BatchPayment.BatchPaymentIntent memory intent = _intent(20e6, 0);
        BatchPayment.PayerData memory data = _reenteringPayerData(evil, 22);

        evil.arm(address(bpc), abi.encodeCall(BatchPayment.isNonceUsed, (intent.nonce)));

        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        assertTrue(evil.reentryAttempted(), "the nonce callback was not attempted");
        assertTrue(evil.reentrySucceeded(), "the nonce reservation must be observable");
        assertTrue(abi.decode(evil.reentryReturnData(), (bool)), "the nonce was not reserved before interaction");
    }

    /// @dev Funds the payer with the hostile token and builds a permit naming it as the settlement token.
    function _reenteringPayerData(BatchPaymentReenteringToken evil, uint256 permitNonce)
        private
        returns (BatchPayment.PayerData memory data)
    {
        evil.mint(payer, 1_000e6);
        vm.prank(payer);
        evil.approve(address(permit2), type(uint256).max);

        data.permit.permitted = IMinimalPermit2.TokenPermissions({token: address(evil), amount: 20e6});
        data.permit.nonce = permitNonce;
        data.permit.deadline = block.timestamp + 1 hours;
    }

    function testFuzz_execute(uint8 rawRows, uint64 rawValue, uint64 rawFee) public {
        uint256 rows = uint256(rawRows) % 40 + 1;
        uint256 valuePerRow = uint256(rawValue) % 1_000e6 + 1;
        uint256 maxFee = uint256(rawFee) % 100e6;

        BatchPayment.Payment[] memory payments = _buildPayments(rows, valuePerRow, 0);
        uint256 totalValue = _sumValues(payments);
        BatchPayment.BatchPaymentIntent memory intent = _intent(totalValue, maxFee);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        for (uint256 i; i < rows; ++i) {
            assertEq(usdc.balanceOf(payments[i].to), valuePerRow);
        }
        // Whatever `maxFee` the fuzzer picks, including zero, the beneficiary receives exactly it.
        assertEq(usdc.balanceOf(beneficiary), maxFee);
        assertEq(payerBefore - usdc.balanceOf(payer), totalValue + maxFee);
        assertEq(usdc.balanceOf(address(bpc)), 0, "the contract never retains value");
    }

    function testFuzz_bitmapDecodersMatchAnIndependentPopcount(bytes memory bitmap) public pure {
        vm.assume(bitmap.length <= 256);

        uint256 expected = _popcountOracle(bitmap);
        assertEq(_skippedRowCount(bitmap), expected, "count");

        uint256[] memory indices = _skippedRowIndices(bitmap);
        assertEq(indices.length, expected, "the index list is exactly as long as the count");

        for (uint256 i; i < indices.length; ++i) {
            assertTrue(_isRowSkipped(bitmap, indices[i]), "a listed index must read as skipped");
            if (i != 0) assertTrue(indices[i] > indices[i - 1], "strictly ascending");
        }
    }

    function testFuzz_storedBitmapAlwaysMatchesTheEmittedOne(uint16 blockedMask) public {
        BatchPayment.Payment[] memory payments = _buildPayments(16, 1e6, 0);
        for (uint256 i; i < payments.length; ++i) {
            if ((blockedMask >> i) & 1 != 0) usdc.setBlocked(payments[i].to, true);
        }

        BatchPayment.BatchPaymentIntent memory intent = _intent(_sumValues(payments), 0);
        BatchPayment.PayerData memory data = _payerData(intent, payments, 0, PAYER_PK);

        vm.recordLogs();
        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        (,, bytes memory emitted) = _decodeOutcome();
        (bool executed, bool paymentsMatch, bytes32 storedPaymentsHash, bytes memory stored) =
            bpc.batchPaymentResult(intent.nonce, payments);

        assertTrue(executed, "a settlement that returned has completed");
        assertTrue(paymentsMatch);
        assertEq(storedPaymentsHash, _hashPayments(payments));
        assertEq(stored, emitted, "the read path must never diverge from the log");
        assertEq(stored.length, blockedMask == 0 ? 0 : 2, "empty on a full settlement, two bytes otherwise");
        if (blockedMask != 0) {
            assertEq(uint8(stored[0]), uint8(blockedMask & 0xFF), "byte 0 is rows 0-7, LSB-first");
            assertEq(uint8(stored[1]), uint8(blockedMask >> 8), "byte 1 is rows 8-15");
        }
    }
}

/// @dev The only entry point the invariant fuzzer drives: one randomized settlement per call. Extends the
///      fixture for its intent helpers; `setUp` never runs here, the constructor wires live instances instead.
contract BatchPaymentInvariantHandler is BatchPaymentTestFixture {
    /// @dev Pinned before every settlement so neither the validity window nor the permit deadline expires.
    uint256 private constant FIXED_TIMESTAMP = 1_800_000_000;

    /// @dev Upper bounds, chosen so a call can never fail for want of funds.
    uint256 private constant MAX_ROWS = 10;
    uint256 private constant MAX_VALUE_PER_ROW = 1_000e6;
    uint256 private constant MAX_FEE = 1_000e6;

    /// @dev Monotonic, so recipients never repeat across calls and each closing balance names one row.
    uint256 private recipientCursor;

    uint256 private nonceCursor;

    uint256 public ghostSettlements;

    uint256 public ghostRows;

    uint256 public ghostSettled;

    /// @dev Read off the bitmap, not from `rows - settled`, so the bitmap is really cross-checked.
    uint256 public ghostSkipped;

    uint256 public ghostFullSettlements;

    uint256 public ghostAllSkipped;

    uint256 public ghostDistributed;

    uint256 public ghostFees;

    uint256 public ghostPayerDebit;

    /// @dev Must stay zero: rows where the bitmap disagreed with what the token actually did.
    uint256 public ghostBitmapMismatches;

    /// @dev Must stay zero: settlements where `batchPaymentResult` disagreed with the emitted bitmap.
    uint256 public ghostResultMismatches;

    bytes public lastSkippedRows;

    uint256 public lastRowCount;

    constructor(BatchPayment bpc_, BatchPaymentDummyPermit2 permit2_, BatchPaymentTestToken usdc_) {
        bpc = bpc_;
        permit2 = permit2_;
        usdc = usdc_;
        payer = vm.addr(PAYER_PK);
    }

    function settle(uint256 rowSeed, uint256 valueSeed, uint256 feeSeed, uint256 blockedSeed) external {
        vm.warp(FIXED_TIMESTAMP);

        uint256 rows = bound(rowSeed, 1, MAX_ROWS);
        uint256 valuePerRow = bound(valueSeed, 1, MAX_VALUE_PER_ROW);
        uint256 maxFee = bound(feeSeed, 0, MAX_FEE);

        BatchPayment.Payment[] memory payments = _buildPayments(rows, valuePerRow, recipientCursor);
        recipientCursor += rows;

        // Block a subset of this call's recipients. The first two calls of every run pin the extremes -
        // block none, block all - and the rest fuzz.
        uint256 mode = ghostSettlements < 2 ? ghostSettlements : blockedSeed % 3;
        for (uint256 i; i < rows; ++i) {
            if (mode == 1 || (mode == 2 && (blockedSeed >> (i + 2)) & 1 != 0)) usdc.setBlocked(payments[i].to, true);
        }

        BatchPayment.BatchPaymentIntent memory intent = _intent(_sumValues(payments), maxFee);
        intent.nonce = _nonce(nonceCursor);
        BatchPayment.PayerData memory data = _payerData(intent, payments, nonceCursor, PAYER_PK);
        ++nonceCursor;

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 beneficiaryBefore = usdc.balanceOf(beneficiary);

        vm.recordLogs();
        vm.prank(attester);
        bpc.execute(intent, payments, data, intent.maxFee, false);

        _record(intent.nonce, payments, rows, payerBefore, beneficiaryBefore);
    }

    /// @dev Folds one settlement's outcome into the ghost accounting.
    function _record(
        bytes32 nonce,
        BatchPayment.Payment[] memory payments,
        uint256 rows,
        uint256 payerBefore,
        uint256 beneficiaryBefore
    ) private {
        (,, bytes memory skippedRows) = _decodeOutcome();

        uint256 distributed;
        uint256 settled;
        for (uint256 i; i < rows; ++i) {
            // Fresh recipient, so any nonzero balance is this row and this row alone.
            uint256 credited = usdc.balanceOf(payments[i].to);
            bool paid = credited != 0;
            if (paid) {
                distributed += credited;
                ++settled;
            }
            if (_isRowSkipped(skippedRows, i) == paid) ++ghostBitmapMismatches;
        }

        if (_resultDiverged(nonce, payments, skippedRows)) ++ghostResultMismatches;

        ++ghostSettlements;
        ghostRows += rows;
        ghostSettled += settled;
        ghostSkipped += _skippedRowCount(skippedRows);
        ghostDistributed += distributed;

        if (settled == rows) ++ghostFullSettlements;
        if (settled == 0) ++ghostAllSkipped;
        ghostFees += usdc.balanceOf(beneficiary) - beneficiaryBefore;
        ghostPayerDebit += payerBefore - usdc.balanceOf(payer);

        lastSkippedRows = skippedRows;
        lastRowCount = rows;
    }

    /// @dev True when the nonce-keyed read path disagrees with the bitmap the event carried.
    /// @dev A helper, not inline code, so its locals cannot tip `_record` into "stack too deep".
    function _resultDiverged(bytes32 nonce, BatchPayment.Payment[] memory payments, bytes memory emitted)
        private
        view
        returns (bool)
    {
        (bool executed, bool paymentsMatch, bytes32 storedPaymentsHash, bytes memory stored) =
            bpc.batchPaymentResult(nonce, payments);
        return !executed || !paymentsMatch || storedPaymentsHash != _hashPayments(payments)
            || keccak256(stored) != keccak256(emitted);
    }
}

/// @dev Properties that must hold across any sequence of settlements, checked against the token's own
///      accounting rather than against the fields the contract reported.
contract BatchPaymentInvariantTest is BatchPaymentTestFixture {
    /// @dev Dust parked in the contract before the first settlement, so the run starts from a non-zero balance.
    uint256 internal constant PRE_EXISTING_DUST = 1_000;

    BatchPaymentInvariantHandler internal handler;

    /// @dev The contract's balance before any settlement ran; invariants compare against this, not zero.
    uint256 internal settlementBaseline;

    function setUp() public override {
        super.setUp();

        usdc.mint(address(bpc), PRE_EXISTING_DUST);
        settlementBaseline = usdc.balanceOf(address(bpc));

        handler = new BatchPaymentInvariantHandler(bpc, permit2, usdc);

        // Restrict the fuzzer to `settle`; `fail_on_revert` would otherwise trip on the inherited helpers.
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = BatchPaymentInvariantHandler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Lives here rather than in an `invariant_` function, which Foundry also evaluates against setUp state.
    function afterInvariant() public view {
        assertGt(handler.ghostSettlements(), 0, "no settlement was driven - target wiring is broken");
        assertGt(handler.ghostFullSettlements(), 0, "no fully-settled batch was explored");
        assertGt(handler.ghostAllSkipped(), 0, "no fully-skipped batch was explored");
    }

    function invariant_contractNeverRetainsValue() public view {
        assertEq(usdc.balanceOf(address(bpc)), settlementBaseline, "the contract retained value");
    }

    function invariant_principalAndFeesAreConserved() public view {
        assertEq(
            handler.ghostPayerDebit(),
            handler.ghostDistributed() + handler.ghostFees(),
            "payer debit does not equal what recipients and the beneficiary received"
        );
    }

    /// @dev The settled side comes from recipients' balances, the skipped side from the bitmap's popcount.
    function invariant_everyRowIsEitherSettledOrSkipped() public view {
        assertEq(
            handler.ghostRows(),
            handler.ghostSettled() + handler.ghostSkipped(),
            "rows attempted does not equal settled plus skipped"
        );
    }

    /// @dev Checked per row, per settlement, inside the handler against fresh recipients' closing balances.
    function invariant_bitmapAlwaysMatchesTheToken() public view {
        assertEq(handler.ghostBitmapMismatches(), 0, "skippedRows disagreed with the token");
    }

    function invariant_storedResultNeverDivergesFromTheLog() public view {
        assertEq(handler.ghostResultMismatches(), 0, "batchPaymentResult disagreed with BatchPaymentExecuted");
    }

    function invariant_anUnsettledNonceNeverReportsAResult() public view {
        BatchPayment.Payment[] memory payments = new BatchPayment.Payment[](0);
        (bool executed, bool paymentsMatch, bytes32 storedPaymentsHash, bytes memory skippedRows) =
            bpc.batchPaymentResult(keccak256("never-signed"), payments);
        assertFalse(executed, "a nonce no intent ever carried must not read as executed");
        assertFalse(paymentsMatch);
        assertEq(storedPaymentsHash, bytes32(0));
        assertEq(skippedRows.length, 0, "and must carry no bitmap");
    }

    /// @dev The bitmap `execute` produced must decode consistently: the index list matches the count, is
    ///      strictly ascending, and never names a row the batch did not have.
    function invariant_theLastBitmapDecodesConsistently() public view {
        bytes memory skippedRows = handler.lastSkippedRows();

        uint256 count = _skippedRowCount(skippedRows);
        uint256[] memory indices = _skippedRowIndices(skippedRows);

        assertEq(indices.length, count, "index list length must equal the skipped count");
        assertLe(count, handler.lastRowCount(), "more rows skipped than were attempted");

        for (uint256 i; i < indices.length; ++i) {
            assertTrue(_isRowSkipped(skippedRows, indices[i]), "a listed index must read as skipped");
            if (i != 0) assertGt(indices[i], indices[i - 1], "indices must be strictly ascending");
        }
    }
}
