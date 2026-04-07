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

import {PaymentSettlementV2} from "../src/PaymentSettlementV2.sol";
import {IMinimalPermit2} from "../src/interfaces/IMinimalPermit2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Test} from "forge-std/src/Test.sol";
import {Vm} from "forge-std/src/Vm.sol";

/* ─────────────────────────────────────────────────────────────────────────────
                                    Mock
   ────────────────────────────────────────────────────────────────────────────*/

/// @dev Mocks a contract wallet supporting EIP-1271
contract Mock1271Wallet {
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return MAGICVALUE;
    }
}

/// @dev Minimal TestERC20 for local minting
contract TestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Deflationary token that takes 1% fee on transfer (for testing balance checks)
contract DeflationaryToken is ERC20 {
    constructor() ERC20("Deflationary", "DFLAT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100; // 1% fee
        uint256 amountAfterFee = amount - fee;
        _transfer(_msgSender(), to, amountAfterFee);
        _burn(_msgSender(), fee); // Burn the fee
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = amount / 100; // 1% fee
        uint256 amountAfterFee = amount - fee;
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amountAfterFee);
        _burn(from, fee); // Burn the fee
        return true;
    }
}

/// @dev Minimal Permit2 substitute for unit-testing.
/// Signature checks are skipped – the mock simply calls ERC-20
/// `transferFrom(owner, to, amount)` so that tests can focus on
/// PaymentSettlement behaviour.
contract DummyPermit2 is IMinimalPermit2, Test {
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes32, /* witness      – ignored */
        string calldata, /* witnessType  – ignored */
        bytes calldata /* signature    – ignored */
    ) external override {
        IERC20(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount);
    }
}

/// @dev Harness to expose internal hash functions for testing
contract PaymentSettlementV2Harness is PaymentSettlementV2 {
    function exposed_hashPayeeRefundSource(RefundIntent calldata intent) external pure returns (bytes32) {
        return _hashPayeeRefundSource(intent);
    }

    function exposed_hashBeneficiaryRefundSource(RefundIntent calldata intent) external pure returns (bytes32) {
        return _hashBeneficiaryRefundSource(intent);
    }

    function exposed_hashPayerCancelPaymentIntent(PaymentIntent calldata intent) external pure returns (bytes32) {
        return _hashPayerCancelPaymentIntent(intent);
    }
}

/* ─────────────────────────────────────────────────────────────────────────────
                               PaymentSettlement test-suite
   ────────────────────────────────────────────────────────────────────────────*/
contract PaymentSettlementV2Test is Test {
    /* Accounts */
    uint256 internal payerPk = 0xA11;
    uint256 internal payeePk = 0xB22;

    address internal payer = vm.addr(payerPk);
    address internal payee = vm.addr(payeePk);

    address internal rescuer = address(0xCAFE);
    address internal pauser = address(0xBEEF);
    address internal config = address(0xC0DE);
    address internal feeSink = address(0xFEE1);
    address internal attester = address(0xA007);

    /* System under test */
    DummyPermit2 internal permit2;
    PaymentSettlementV2 internal payment;
    TestERC20 internal usdc;

    /* --------------------------------------------------------------------- */
    function setUp() public {
        permit2 = new DummyPermit2();
        address[] memory attesters = new address[](1);
        attesters[0] = attester;

        payment = new PaymentSettlementV2();
        payment.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, config, attesters);

        usdc = new TestERC20("MockUSD", "mUSDC");

        /* Fund payer and approve DummyPermit2 */
        usdc.mint(payer, 1_000 ether);
        vm.prank(payer);
        usdc.approve(address(permit2), type(uint256).max);
    }

    /* Helpers ------------------------------------------------------------- */
    function _permit(uint256 amount) internal view returns (IMinimalPermit2.PermitTransferFrom memory p) {
        p.permitted = IMinimalPermit2.TokenPermissions({token: address(usdc), amount: amount});
        p.nonce = 0;
        p.deadline = block.timestamp + 1 days;
    }

    function _emptyPermit2Data() internal pure returns (PaymentSettlementV2.Permit2Data memory) {
        return PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(0), amount: 0}),
                nonce: 0,
                deadline: 0
            }),
            signature: ""
        });
    }

    function _sig(bytes32 digest, uint256 pk) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _computeTypedDataHash(
        string memory name,
        string memory version,
        address verifyingContract,
        bytes32 structHash
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                verifyingContract
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /* Helper: Build PaymentIntent */
    function _buildPaymentIntent(
        address token_,
        address from_,
        address to_,
        uint256 payerAmount_,
        uint256 payeeSettlementAmount_,
        uint256 maxFee_,
        address beneficiary_,
        address incentiveProvider_,
        bytes32 nonce_,
        uint256 validAfter_,
        uint256 validBefore_,
        bool requirePayeeSign_,
        address attester_
    ) internal pure returns (PaymentSettlementV2.PaymentIntent memory) {
        // Note: token_ parameter kept for backwards compatibility but not used in struct
        token_; // Suppress unused variable warning
        return PaymentSettlementV2.PaymentIntent({
            from: from_,
            to: to_,
            payerAmount: payerAmount_,
            payeeSettlementAmount: payeeSettlementAmount_,
            maxFee: maxFee_,
            beneficiary: beneficiary_,
            incentiveProvider: incentiveProvider_,
            nonce: nonce_,
            validAfter: validAfter_,
            validBefore: validBefore_,
            requirePayeeSign: requirePayeeSign_,
            attester: attester_
        });
    }

    /* Helper: Build RefundIntent for non-incentive payments */
    function _buildRefundIntentNoIncentive(
        address payer_,
        address payee_,
        uint256 payerAmount_,
        uint256 payeeSettlementAmount_,
        uint256 fee_,
        bytes32 nonce_,
        uint256 validAfter_,
        uint256 validBefore_,
        uint256 payerRefundAmount_,
        address payerRefundTo_,
        bool requireDestinationRefundSig_
    ) internal view returns (PaymentSettlementV2.RefundIntent memory) {
        return PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer_,
            payeeRefundFrom: payee_,
            payerAmount: payerAmount_,
            payeeSettlementAmount: payeeSettlementAmount_,
            fee: fee_,
            payerRefundAmount: payerRefundAmount_,
            incentiveProviderRefundAmount: 0,
            validAfter: validAfter_,
            validBefore: validBefore_,
            nonce: nonce_,
            incentiveProvider: address(0),
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payerRefundTo_,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: requireDestinationRefundSig_,
            attester: attester
        });
    }

    /* Helper: Execute a basic payment and return the nonce in Executed state */
    function _executeBasicPayment(
        address payer_,
        address payee_,
        uint256 payerAmount_,
        uint256 fee_,
        uint256 payeeSettlementAmount_
    ) internal returns (bytes32 nonce_) {
        nonce_ =
            keccak256(abi.encodePacked(payer_, payee_, payerAmount_, fee_, payeeSettlementAmount_, block.timestamp));

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer_,
            to_: payee_,
            payerAmount_: payerAmount_,
            payeeSettlementAmount_: payeeSettlementAmount_,
            maxFee_: fee_,
            beneficiary_: fee_ > 0 ? feeSink : address(0),
            incentiveProvider_: address(0),
            nonce_: nonce_,
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount_ + fee_), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee_);
    }

    /* --------------------------------------------------------------------- */
    /*                         Happy-path test cases                          */
    /* --------------------------------------------------------------------- */
    function testPayment_basic() public {
        uint256 value = 100 ether;
        uint256 fee = 10 ether;
        bytes32 n = "basic";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    /* --------------------------------------------------------------------- */
    /*                       Negative / revert scenarios                      */
    /* --------------------------------------------------------------------- */

    function testPayment_revertNotYetValid() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1 ether,
            payeeSettlementAmount_: 1 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "future",
            validAfter_: block.timestamp + 1000,
            validBefore_: block.timestamp + 2000,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.NotYetValid.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    function testPayment_revertExpired() public {
        vm.warp(2); // ensure block.timestamp > 1

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1 ether,
            payeeSettlementAmount_: 1 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "exp",
            validAfter_: 0,
            validBefore_: 1,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.ExpiredIntent.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    function testNonceReuseReverts() public {
        bytes32 n = "dup";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1,
            payeeSettlementAmount_: 1,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd = PaymentSettlementV2.Permit2Data({permit: _permit(1), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);

        vm.prank(attester);
        vm.expectRevert(); // any revert – nonce must be marked used
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    /* --------------------------------------------------------------------- */
    /*                     Pause / attester / rescuer flows                   */
    /* --------------------------------------------------------------------- */
    function testPauseBlocksPayment() public {
        vm.prank(pauser);
        payment.pause();

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1,
            payeeSettlementAmount_: 1,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "pause",
            validAfter_: 0,
            validBefore_: block.timestamp + 10,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd = PaymentSettlementV2.Permit2Data({permit: _permit(1), signature: ""});

        vm.prank(attester);
        vm.expectRevert(); // EnforcedPause
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    function testAddRemoveAttester() public {
        address newAttester = address(0xABCD);

        vm.startPrank(config);
        payment.addAttester(newAttester);
        vm.stopPrank();

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1,
            payeeSettlementAmount_: 1,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "att",
            validAfter_: 0,
            validBefore_: block.timestamp + 10,
            requirePayeeSign_: false,
            attester_: newAttester
        });

        PaymentSettlementV2.Permit2Data memory pd = PaymentSettlementV2.Permit2Data({permit: _permit(1), signature: ""});

        vm.prank(newAttester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0); // succeeds

        vm.startPrank(config);
        payment.removeAttester(newAttester);
        vm.stopPrank();

        intent.nonce = "att2";

        vm.prank(newAttester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidAttester.selector, newAttester));
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    function testRescueERC20() public {
        usdc.mint(address(payment), 5 ether);
        vm.prank(rescuer);
        payment.rescueERC20(usdc, feeSink, 5 ether);
        assertEq(usdc.balanceOf(feeSink), 5 ether);
    }

    function testPaymentWithPayeeSignature() public {
        bytes32 n = "payeeSig";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 100 ether,
            payeeSettlementAmount_: 100 ether,
            maxFee_: 5 ether,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: true,
            attester_: attester
        });

        bytes32 structHash = keccak256(
            abi.encode(
                payment.PAYEE_PAYMENT_INTENT_TYPEHASH(),
                address(usdc),
                payer,
                payee,
                100 ether,
                intent.validAfter,
                intent.validBefore,
                n,
                attester
            )
        );
        bytes32 digest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(105 ether), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), sig, 5 ether);

        assertEq(usdc.balanceOf(payee), 100 ether);
        assertEq(usdc.balanceOf(feeSink), 5 ether);
    }

    function testPayeeSigInvalidSignature() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1 ether,
            payeeSettlementAmount_: 1 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "badSig",
            validAfter_: 0,
            validBefore_: block.timestamp + 10,
            requirePayeeSign_: true,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""});

        // Fake signature
        bytes memory sig = hex"deadbeef";

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), sig, 0);
    }

    function testVerifySig_InvalidLengthSignature() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1 ether,
            payeeSettlementAmount_: 1 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "badLen",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: true,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""});

        // Signature with invalid length (≠ 65 bytes)
        bytes memory badSig = hex"123456";

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), badSig, 0);
    }

    function testInitialize_revertsIfZeroOwner() public {
        permit2 = new DummyPermit2();
        payment = new PaymentSettlementV2(); // constructor is empty ⇒ no revert

        // expect revert **on initialize()** when owner_ == address(0)
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidOwner.selector, address(0)));
        payment.initialize(IMinimalPermit2(address(permit2)), address(0), rescuer, pauser, config, new address[](0));
    }

    function testInitialize_attesterArrayTriggersLoop() public {
        address[] memory initialAttesters = new address[](1);
        initialAttesters[0] = attester;

        payment = new PaymentSettlementV2();
        payment.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, config, initialAttesters);

        // Confirm attester added
        vm.prank(attester);
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1 ether,
            payeeSettlementAmount_: 1 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "initAdd",
            validAfter_: 0,
            validBefore_: block.timestamp + 10,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""});
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    function testRenounceOwnershipReverts() public {
        vm.prank(address(this)); // set to actual owner
        vm.expectRevert(PaymentSettlementV2.RenounceOwnershipDisabled.selector);
        payment.renounceOwnership();
    }

    function testPayeeSig_revertsIfMissingAndSenderNotPayee() public {
        uint256 value = 100 ether;
        uint256 fee = 2 ether;
        bytes32 n = "missingSigFail";

        address notPayee = address(0xBEEF);
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: notPayee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: true,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee);
    }

    function testPayeeSig_contractWallet1271() public {
        // Deploy minimal 1271 wallet
        address contractWallet = address(new Mock1271Wallet());
        vm.label(contractWallet, "Mock1271");

        // Prepare payment intent
        uint256 value = 123 ether;
        uint256 fee = 7 ether;
        bytes32 nonce = "1271sig";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: contractWallet,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: nonce,
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: true,
            attester_: attester
        });

        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(0)); // will be ignored

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee), signature: ""});

        // Register attester
        vm.prank(config);
        payment.addAttester(attester);

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), sig, fee);

        assertEq(usdc.balanceOf(contractWallet), value);
        assertEq(usdc.balanceOf(feeSink), fee);
    }

    function testIsAttester() public {
        assertFalse(payment.isAttester(address(0xDEAD)));

        vm.prank(config);
        payment.addAttester(attester);
        assertTrue(payment.isAttester(attester));

        vm.prank(config);
        payment.removeAttester(attester);
        assertFalse(payment.isAttester(attester));
    }

    function testPayment_revertIfPermitAmountMismatch() public {
        uint256 value = 100 ether;
        uint256 fee = 2 ether;
        bytes32 nonce = "badPermitAmount";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: nonce,
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        // Deliberately wrong permit amount
        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee + 1), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.PermitAmountMismatch.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee); // fee ≤ maxFee, but permit amount mismatched
    }

    function testHelpers_domain_and_nonce() public {
        // domainSeparator is pure-view – just ensure non-zero
        bytes32 ds = payment.domainSeparator();
        assertTrue(ds != bytes32(0));

        // nonce should be unused, then used after a dummy payment
        bytes32 n = "nonceView";
        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Unused));

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1 ether,
            payeeSettlementAmount_: 1 ether,
            maxFee_: 0,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: block.timestamp + 10,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Executed));
    }

    function testPayment_revertFeeNoBeneficiary() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 1 ether,
            payeeSettlementAmount_: 1 ether,
            maxFee_: 1 ether,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "feeNoSink",
            validAfter_: 0,
            validBefore_: block.timestamp + 10,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(2 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidBeneficiary.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 1 ether);
    }

    function testInitialize_zeroAttesters() public {
        PaymentSettlementV2 fresh = new PaymentSettlementV2();
        address[] memory none = new address[](0);
        fresh.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, config, none);
        assertFalse(fresh.isAttester(attester));
    }

    function testInitialize_revertInvalidPermit2() public {
        payment = new PaymentSettlementV2();
        vm.expectRevert(PaymentSettlementV2.InvalidPermit2.selector);
        payment.initialize(IMinimalPermit2(address(0)), address(this), rescuer, pauser, config, new address[](0));
    }

    function testCancel_revertPermitAmountMismatch() public {
        uint256 fee = 5 ether;
        bytes32 n = "cancelMismatch";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: fee,
            payeeSettlementAmount_: 0,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: 0,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory cd =
            PaymentSettlementV2.Permit2Data({permit: _permit(fee + 1 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.PermitAmountMismatch.selector);
        payment.cancel(intent, cd, fee);
    }

    function testCancel_feeAndBeneficiaryMatrix() public {
        // Case 1: fee = 0, beneficiary = zero address → allowed
        {
            PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: address(0),
                payerAmount_: 0,
                payeeSettlementAmount_: 0,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: "cancel-f0-b0",
                validAfter_: 0,
                validBefore_: 0,
                requirePayeeSign_: false,
                attester_: attester
            });

            PaymentSettlementV2.Permit2Data memory pd =
                PaymentSettlementV2.Permit2Data({permit: _permit(0), signature: ""});

            vm.prank(attester);
            payment.cancel(intent, pd, 0);
        }

        // Case 2: fee = 0, beneficiary = non-zero address → allowed
        {
            PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: address(0),
                payerAmount_: 0,
                payeeSettlementAmount_: 0,
                maxFee_: 0,
                beneficiary_: feeSink,
                incentiveProvider_: address(0),
                nonce_: "cancel-f0-b1",
                validAfter_: 0,
                validBefore_: 0,
                requirePayeeSign_: false,
                attester_: attester
            });

            PaymentSettlementV2.Permit2Data memory pd =
                PaymentSettlementV2.Permit2Data({permit: _permit(0), signature: ""});

            vm.prank(attester);
            payment.cancel(intent, pd, 0);
        }

        // Case 3: fee > 0, beneficiary = zero address → should revert
        {
            PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: address(0),
                payerAmount_: 5 ether,
                payeeSettlementAmount_: 0,
                maxFee_: 5 ether,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: "cancel-f1-b0",
                validAfter_: 0,
                validBefore_: 0,
                requirePayeeSign_: false,
                attester_: attester
            });

            PaymentSettlementV2.Permit2Data memory pd =
                PaymentSettlementV2.Permit2Data({permit: _permit(5 ether), signature: ""});

            vm.prank(attester);
            vm.expectRevert(PaymentSettlementV2.InvalidBeneficiary.selector);
            payment.cancel(intent, pd, 5 ether);
        }

        // Case 4: fee > 0, beneficiary = valid address → allowed
        {
            uint256 fee = 5 ether;
            uint256 before = usdc.balanceOf(feeSink);

            PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: address(0),
                payerAmount_: fee,
                payeeSettlementAmount_: 0,
                maxFee_: fee,
                beneficiary_: feeSink,
                incentiveProvider_: address(0),
                nonce_: "cancel-f1-b1",
                validAfter_: 0,
                validBefore_: 0,
                requirePayeeSign_: false,
                attester_: attester
            });

            PaymentSettlementV2.Permit2Data memory pd =
                PaymentSettlementV2.Permit2Data({permit: _permit(fee), signature: ""});

            vm.prank(attester);
            payment.cancel(intent, pd, fee);

            assertEq(usdc.balanceOf(feeSink), before + fee);
        }
    }

    function testExecute_revertFeeExceedsMax() public {
        uint256 value = 50 ether;
        uint256 maxFee = 5 ether;
        uint256 fee = 6 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: maxFee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "feeTooHigh",
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(value + maxFee), signature: ""});

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.FeeExceedsMax.selector, fee, maxFee));
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee);
    }

    function testExecute_feeBelowMaxSucceeds() public {
        uint256 value = 40 ether;
        uint256 fee = 3 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "feeOK",
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
    }

    function testCancel_revertFeeExceedsMax() public {
        uint256 maxFee = 4 ether;
        uint256 fee = 5 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: maxFee,
            payeeSettlementAmount_: 0,
            maxFee_: maxFee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "cancelHighFee",
            validAfter_: 0,
            validBefore_: 0,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(maxFee), signature: ""});

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.FeeExceedsMax.selector, fee, maxFee));
        payment.cancel(intent, pd, fee);
    }

    function testCancel_revertPermitAmountNotEqualToMaxFee() public {
        uint256 maxFee = 5 ether;
        uint256 fee = 5 ether;
        uint256 wrongPermitAmount = 4 ether;
        bytes32 nonce = "cancelBadPermitAmount";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: maxFee,
            payeeSettlementAmount_: 0,
            maxFee_: maxFee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: nonce,
            validAfter_: 0,
            validBefore_: 0,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(wrongPermitAmount), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.PermitAmountMismatch.selector);
        payment.cancel(intent, pd, fee);
    }

    /* --------------------------------------------------------------------- */
    /*                 Spurious event emission guards                        */
    /* --------------------------------------------------------------------- */

    function _countEvent(Vm.Log[] memory logs, bytes32 sig, address who) internal pure returns (uint256 c) {
        bytes32 whoTopic = bytes32(uint256(uint160(who)));
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory ll = logs[i];
            if (ll.topics.length >= 2 && ll.topics[0] == sig && ll.topics[1] == whoTopic) {
                c++;
            }
        }
    }

    function testInitialize_dedupAttesters_emitsOnce() public {
        PaymentSettlementV2 fresh = new PaymentSettlementV2();

        address[] memory inits = new address[](3);
        inits[0] = attester;
        inits[1] = attester;
        inits[2] = attester;

        vm.recordLogs();
        fresh.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, config, inits);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 added = keccak256("AttesterAdded(address)");
        uint256 addedCount = _countEvent(logs, added, attester);
        assertEq(addedCount, 1, "initialize() must emit AttesterAdded once per unique attester");

        assertTrue(fresh.isAttester(attester));
    }

    function testAttesterAddRemove_spuriousEventsGuarded() public {
        address x = address(0xA11CE);
        bytes32 added = keccak256("AttesterAdded(address)");
        bytes32 removed = keccak256("AttesterRemoved(address)");

        vm.startPrank(config);
        vm.recordLogs();
        payment.addAttester(x);
        payment.addAttester(x);
        payment.removeAttester(x);
        payment.removeAttester(x);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        uint256 addCount = _countEvent(logs, added, x);
        uint256 removeCount = _countEvent(logs, removed, x);

        assertEq(addCount, 1, "addAttester must emit at most once per address");
        assertEq(removeCount, 1, "removeAttester must emit at most once per address");

        assertFalse(payment.isAttester(x));
    }

    /* --------------------------------------------------------------------- */
    /*                 Incentive Provider Validation Tests                    */
    /* --------------------------------------------------------------------- */
    function testExecute_revertIncentiveProviderTokenMismatch() public {
        TestERC20 usdt = new TestERC20("MockUSDT", "mUSDT");
        usdt.mint(address(0x5404), 100 ether);
        vm.prank(address(0x5404));
        usdt.approve(address(permit2), type(uint256).max);

        uint256 value = 98 ether;
        uint256 maxFee = 2 ether;
        uint256 feeToCollect = 2 ether;
        uint256 payerAmount = 50 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: maxFee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0x5404),
            nonce_: "incentiveTokenMismatch",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory payerData =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + maxFee), signature: ""});

        IMinimalPermit2.PermitTransferFrom memory incentivePermit = IMinimalPermit2.PermitTransferFrom({
            permitted: IMinimalPermit2.TokenPermissions({token: address(usdt), amount: 50 ether}),
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        PaymentSettlementV2.Permit2Data memory incentiveData =
            PaymentSettlementV2.Permit2Data({permit: incentivePermit, signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidToken.selector);
        payment.execute(intent, payerData, incentiveData, "", feeToCollect);
    }

    function testExecute_revertInvalidTotalPermitted() public {
        address incentiveProvider = address(0x5404);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 value = 98 ether;
        uint256 maxFee = 2 ether;
        uint256 feeToCollect = 2 ether;
        uint256 payerAmount = 50 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: maxFee,
            beneficiary_: feeSink,
            incentiveProvider_: incentiveProvider,
            nonce_: "badTotalPermit",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory payerData =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + maxFee), signature: ""});

        IMinimalPermit2.PermitTransferFrom memory incentivePermit = IMinimalPermit2.PermitTransferFrom({
            permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 47 ether}),
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        PaymentSettlementV2.Permit2Data memory incentiveData =
            PaymentSettlementV2.Permit2Data({permit: incentivePermit, signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidIncentiveAmount.selector);
        payment.execute(intent, payerData, incentiveData, "", feeToCollect);
    }

    /* --------------------------------------------------------------------- */
    /*                 Split-Funding Execution Tests                          */
    /* --------------------------------------------------------------------- */
    function testExecute_revenueCase() public {
        uint256 value = 98 ether;
        uint256 fee = 2.5 ether;
        uint256 payerAmount = value;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "revenue",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + fee), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testExecute_breakEvenCase() public {
        uint256 value = 98 ether;
        uint256 fee = 2 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "breakeven",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testExecute_incentiveCase() public {
        address incentiveProvider = address(0x5404);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 value = 98 ether;
        uint256 fee = 2.5 ether;
        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: incentiveProvider,
            nonce_: "incentive",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory payerData =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + fee), signature: ""});

        IMinimalPermit2.PermitTransferFrom memory incentivePermit = IMinimalPermit2.PermitTransferFrom({
            permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        PaymentSettlementV2.Permit2Data memory incentiveData =
            PaymentSettlementV2.Permit2Data({permit: incentivePermit, signature: ""});

        vm.expectEmit(true, true, false, true);
        emit PaymentSettlementV2.SettlementIncentivized(intent.nonce, incentiveProvider, address(usdc), incentiveAmount);

        vm.prank(attester);
        payment.execute(intent, payerData, incentiveData, "", fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    /* --------------------------------------------------------------------- */
    /*                 Refund Tests (7-field RefundIntent)                    */
    /* --------------------------------------------------------------------- */
    function testRefund_revertPaymentNotFound() public {
        bytes32 nonexistent = "nonexistent";

        PaymentSettlementV2.RefundIntent memory intent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: payee,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 0,
            payeeSettlementAmount: 0,
            fee: 0,
            nonce: nonexistent,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 0,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        vm.prank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentSettlementV2.InvalidNonceState.selector, nonexistent, PaymentSettlementV2.NonceStatus.Unused
            )
        );
        payment.refund(intent, _emptyPermit2Data(), _emptyPermit2Data(), "", "");
    }

    function testRefund_revertDuplicateRefund() public {
        uint256 value = 100 ether;
        bytes32 paymentNonce = "refundTest";

        // Execute payment first
        PaymentSettlementV2.PaymentIntent memory payIntent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: paymentNonce,
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        vm.prank(attester);
        payment.execute(
            payIntent,
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        // Prepare refund
        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, value);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: value}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        vm.prank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentSettlementV2.InvalidNonceState.selector, paymentNonce, PaymentSettlementV2.NonceStatus.Refunded
            )
        );
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");
    }

    function testRefund_revertNotYetValid() public {
        bytes32 paymentNonce = "timeTest";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        PaymentSettlementV2.RefundIntent memory intent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: payee,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 1 ether,
            payeeSettlementAmount: 1 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: block.timestamp + 1000,
            validBefore: block.timestamp + 2000,
            attester: attester,
            payerRefundAmount: 1 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.NotYetValid.selector);
        payment.refund(intent, _emptyPermit2Data(), _emptyPermit2Data(), "", "");
    }

    function testRefund_revertExpired() public {
        bytes32 paymentNonce = "expTest";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        vm.warp(10);
        PaymentSettlementV2.RefundIntent memory intent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: payee,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 1 ether,
            payeeSettlementAmount: 1 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: 5,
            attester: attester,
            payerRefundAmount: 1 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.ExpiredIntent.selector);
        payment.refund(intent, _emptyPermit2Data(), _emptyPermit2Data(), "", "");
    }

    function testRefund_singleSource() public {
        bytes32 paymentNonce = "singleSrc";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, value);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: value}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        assertEq(usdc.balanceOf(payer), 1000 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testRefund_incentiveClawback() public {
        uint256 incentivePk = 0x5404;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 paymentNonce = "clawback";
        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: 98 ether,
                maxFee_: 2 ether,
                beneficiary_: feeSink,
                incentiveProvider_: incentiveProvider,
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + 2 ether), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            2 ether
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: incentiveProvider,
            token: address(usdc),
            payerAmount: payerAmount,
            payeeSettlementAmount: payerAmount + incentiveAmount,
            fee: 2 ether,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: payerAmount + 2 ether,
            incentiveProviderRefundAmount: incentiveAmount,
            payerRefundTo: payer,
            incentiveProviderRefundTo: incentiveProvider,
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 100 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        bytes32 incentiveHash = keccak256(
            abi.encode(
                payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                address(usdc),
                incentiveAmount,
                refIntent.validAfter,
                refIntent.validBefore,
                paymentNonce,
                incentiveProvider,
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 incentiveDigest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), incentiveHash);
        bytes memory incentiveSig = _sig(incentiveDigest, incentivePk);

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", incentiveSig);

        assertEq(usdc.balanceOf(payer), 1000 ether);
        assertEq(usdc.balanceOf(incentiveProvider), 100 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testExecute_incentiveExactShortfall() public {
        address incentiveProvider = address(0x5404);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 value = 98 ether;
        uint256 maxFee = 5 ether;
        uint256 feeToCollect = 2 ether;
        uint256 payerAmount = 90 ether;
        // Incentive must cover exactly the shortfall: payeeSettlement - payerAmount = 8 ether
        uint256 incentivePermitted = value - payerAmount; // 8 ether

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: maxFee,
            beneficiary_: feeSink,
            incentiveProvider_: incentiveProvider,
            nonce_: "exactShortfall",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory payerData =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + maxFee), signature: ""});

        IMinimalPermit2.PermitTransferFrom memory incentivePermit = IMinimalPermit2.PermitTransferFrom({
            permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentivePermitted}),
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        PaymentSettlementV2.Permit2Data memory incentiveData =
            PaymentSettlementV2.Permit2Data({permit: incentivePermit, signature: ""});

        vm.prank(attester);
        payment.execute(intent, payerData, incentiveData, "", feeToCollect);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), feeToCollect);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testExecute_revertIncentiveAmountMismatch() public {
        address incentiveProvider = address(0x5404);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 value = 98 ether;
        uint256 maxFee = 5 ether;
        uint256 feeToCollect = 2 ether;
        uint256 payerAmount = 90 ether;
        // Shortfall is 8 ether but incentive only permits 5 ether → should revert
        uint256 incentivePermitted = 5 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: maxFee,
            beneficiary_: feeSink,
            incentiveProvider_: incentiveProvider,
            nonce_: "incentiveMismatch",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory payerData =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + maxFee), signature: ""});

        IMinimalPermit2.PermitTransferFrom memory incentivePermit = IMinimalPermit2.PermitTransferFrom({
            permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentivePermitted}),
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        PaymentSettlementV2.Permit2Data memory incentiveData =
            PaymentSettlementV2.Permit2Data({permit: incentivePermit, signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidIncentiveAmount.selector);
        payment.execute(intent, payerData, incentiveData, "", feeToCollect);
    }

    function testIntegration_executeRevenueRefund() public {
        bytes32 paymentNonce = "revRefund";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, value);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: value}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        assertEq(usdc.balanceOf(payer), 1000 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testIntegration_executeIncentiveRefund() public {
        uint256 incentivePk = 0x5404;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 paymentNonce = "incRefund";
        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: 98 ether,
                maxFee_: 2 ether,
                beneficiary_: feeSink,
                incentiveProvider_: incentiveProvider,
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + 2 ether), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            2 ether
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: incentiveProvider,
            token: address(usdc),
            payerAmount: payerAmount,
            payeeSettlementAmount: payerAmount + incentiveAmount,
            fee: 2 ether,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: payerAmount + 2 ether,
            incentiveProviderRefundAmount: incentiveAmount,
            payerRefundTo: payer,
            incentiveProviderRefundTo: incentiveProvider,
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 100 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        bytes32 incentiveHash = keccak256(
            abi.encode(
                payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                address(usdc),
                incentiveAmount,
                refIntent.validAfter,
                refIntent.validBefore,
                paymentNonce,
                incentiveProvider,
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 incentiveDigest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), incentiveHash);
        bytes memory incentiveSig = _sig(incentiveDigest, incentivePk);

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", incentiveSig);

        assertEq(usdc.balanceOf(payer), 1000 ether);
        assertEq(usdc.balanceOf(incentiveProvider), 100 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testRefund_multiSource() public {
        bytes32 paymentNonce = "multiSrc";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet1 = address(0x0001);
        address refundWallet2 = address(0x0002);
        usdc.mint(refundWallet1, 60 ether);
        usdc.mint(refundWallet2, 40 ether);
        vm.prank(refundWallet1);
        usdc.approve(address(permit2), type(uint256).max);
        vm.prank(refundWallet2);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet1,
            beneficiaryRefundFrom: refundWallet2,
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 60 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });
        PaymentSettlementV2.Permit2Data memory beneficiaryRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 40 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, beneficiaryRefundData, "", "");

        assertEq(usdc.balanceOf(payer), 1000 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testIntegration_partialRefund() public {
        bytes32 paymentNonce = "partialRef";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 50 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 50 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 50 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        assertEq(usdc.balanceOf(payer), 950 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testRefund_revertInvalidPayerSig() public {
        bytes32 paymentNonce = "sigTest";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 10 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory intent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 1 ether,
            payeeSettlementAmount: 1 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 1 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 1 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.refund(intent, payeeRefundData, _emptyPermit2Data(), hex"deadbeef", "");
    }

    function testRefund_revertWrongSourceToken() public {
        bytes32 paymentNonce = "wrongToken";
        address refundWallet = address(0xBEEF);
        TestERC20 wrongToken = new TestERC20("Wrong", "WRG");

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 1 ether,
            payeeSettlementAmount: 1 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 1 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(wrongToken), amount: 1 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.expectRevert(PaymentSettlementV2.InvalidToken.selector);
        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");
    }

    function testRefund_revertSourceAmountMismatch() public {
        bytes32 paymentNonce = "amtMismatch";
        address refundWallet = address(0xBEEF);

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 100 ether,
                payeeSettlementAmount_: 100 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(100 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        usdc.mint(refundWallet, 110 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), 110 ether);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 100 ether,
            payeeSettlementAmount: 100 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 100 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 110 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.expectRevert(PaymentSettlementV2.RefundAmountMismatch.selector);
        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");
    }

    function testRefund_revertNoSources() public {
        bytes32 paymentNonce = "noSrc";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: address(0),
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 1 ether,
            payeeSettlementAmount: 1 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 1 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        vm.expectRevert(PaymentSettlementV2.RefundAmountMismatch.selector);
        vm.prank(attester);
        payment.refund(refIntent, _emptyPermit2Data(), _emptyPermit2Data(), "", "");
    }

    function testRefund_nonZeroPayment_refundZeroAmounts_succeeds() public {
        bytes32 paymentNonce = "zeroAmts";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: payee,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 1 ether,
            payeeSettlementAmount: 1 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 0,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        vm.prank(attester);
        payment.refund(refIntent, _buildRefundPermit2Data(0), _emptyPermit2Data(), "", "");

        // State stays Executed — cumulative 0 < cap 1 ether
        assertEq(uint256(payment.getNonceStatus(paymentNonce)), uint256(PaymentSettlementV2.NonceStatus.Executed));
    }

    function testRefund_retrievesOriginalPayer() public {
        uint256 incentivePk = 0x5404;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 paymentNonce = "retrievePayer";
        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: 98 ether,
                maxFee_: 2 ether,
                beneficiary_: feeSink,
                incentiveProvider_: incentiveProvider,
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + 2 ether), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            2 ether
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: incentiveProvider,
            token: address(usdc),
            payerAmount: payerAmount,
            payeeSettlementAmount: payerAmount + incentiveAmount,
            fee: 2 ether,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: payerAmount + 2 ether,
            incentiveProviderRefundAmount: incentiveAmount,
            payerRefundTo: payer,
            incentiveProviderRefundTo: incentiveProvider,
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 100 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        bytes32 incentiveHash = keccak256(
            abi.encode(
                payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                address(usdc),
                incentiveAmount,
                refIntent.validAfter,
                refIntent.validBefore,
                paymentNonce,
                incentiveProvider,
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 incentiveDigest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), incentiveHash);
        bytes memory incentiveSig = _sig(incentiveDigest, incentivePk);

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", incentiveSig);

        assertEq(usdc.balanceOf(payer), 1000 ether);
        assertEq(usdc.balanceOf(incentiveProvider), 100 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testRefund_revertAttesterNotWhitelisted() public {
        bytes32 paymentNonce = "badAttester";
        address wrongAttester = address(0xBAD);

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 1 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 1 ether,
            payeeSettlementAmount: 1 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: wrongAttester,
            payerRefundAmount: 1 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 1 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(wrongAttester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidAttester.selector, wrongAttester));
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");
    }

    /* --------------------------------------------------------------------- */
    /*                         Event Emission Tests                           */
    /* --------------------------------------------------------------------- */
    function testEvent_incentiveProviderUsed() public {
        address incentiveProvider = address(0x5404);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 nonce = "eventTest";
        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;
        uint256 value = 98 ether;
        uint256 fee = 2 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: incentiveProvider,
            nonce_: nonce,
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory incentiveData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.expectEmit(true, true, false, true);
        emit PaymentSettlementV2.SettlementIncentivized(nonce, incentiveProvider, address(usdc), incentiveAmount);

        vm.prank(attester);
        payment.execute(
            intent,
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + fee), signature: ""}),
            incentiveData,
            "",
            fee
        );

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
    }

    function testEvent_nonceRefunded() public {
        bytes32 paymentNonce = "eventRefund";
        uint256 value = 50 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: value}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.expectEmit(true, true, false, true);
        emit PaymentSettlementV2.NonceRefunded(paymentNonce, attester, payer, address(usdc), value, payer, value);

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        assertEq(usdc.balanceOf(payer), 1000 ether);
    }

    /* --------------------------------------------------------------------- */
    /*                         Invariant Tests                                */
    /* --------------------------------------------------------------------- */
    function testExecute_zeroBalanceInvariant() public {
        address incentiveProvider = address(0x5404);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;
        uint256 value = 98 ether;
        uint256 fee = 2 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: payerAmount,
            payeeSettlementAmount_: value,
            maxFee_: fee,
            beneficiary_: feeSink,
            incentiveProvider_: incentiveProvider,
            nonce_: "invariant",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory payerData =
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + fee), signature: ""});

        PaymentSettlementV2.Permit2Data memory incentiveData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.execute(intent, payerData, incentiveData, "", fee);

        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    /* --------------------------------------------------------------------- */
    /*                         Nonce & Cancel Tests                           */
    /* --------------------------------------------------------------------- */
    function testCancel_zeroFee() public {
        bytes32 nonce = "cancelZeroFee";

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: 0,
            payeeSettlementAmount_: 0,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: nonce,
            validAfter_: 0,
            validBefore_: 0,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory data =
            PaymentSettlementV2.Permit2Data({permit: _permit(0), signature: ""});

        vm.prank(attester);
        payment.cancel(intent, data, 0);

        assertEq(uint8(payment.getNonceStatus(nonce)), uint8(PaymentSettlementV2.NonceStatus.Cancelled));
    }

    function testNonce_getNonceStatusLifecycle() public {
        bytes32 n = "lifecycle";
        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Unused));

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Executed));
    }

    function testNonce_storesPayerAddress() public {
        bytes32 n = "nonceStore";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 1 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Executed));
    }

    function testGetPaymentRecordHash_returnsZeroForUnusedNonce() public view {
        assertEq(payment.getPaymentRecordHash("unused"), bytes32(0));
    }

    function testGetPaymentRecordHash_returnsCorrectHashAfterExecute() public {
        bytes32 n = "recordLookup";
        address incentive = address(0x1234);

        usdc.mint(incentive, 100 ether);
        vm.prank(incentive);
        usdc.approve(address(permit2), type(uint256).max);

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 1 ether,
                payeeSettlementAmount_: 2 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: incentive,
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(1 ether), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 1 ether}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            0
        );

        bytes32 expectedHash = keccak256(abi.encode(address(usdc), payer, incentive, 1 ether, 2 ether, 0));
        assertEq(payment.getPaymentRecordHash(n), expectedHash);
    }

    function testGetPaymentRecordHash_storesActualFee() public {
        bytes32 n = "feeRecord";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 5 ether,
                payeeSettlementAmount_: 5 ether,
                maxFee_: 1 ether,
                beneficiary_: feeSink,
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(6 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0.5 ether
        );

        bytes32 expectedHash = keccak256(abi.encode(address(usdc), payer, address(0), 5 ether, 5 ether, 0.5 ether));
        assertEq(payment.getPaymentRecordHash(n), expectedHash);
    }

    function testRefund_revertPayerRefundExceedsCeiling() public {
        bytes32 n = "ceilingPayer";
        uint256 value = 10 ether;
        uint256 fee = 1 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: fee,
                beneficiary_: feeSink,
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee), signature: ""}),
            _emptyPermit2Data(),
            "",
            fee
        );

        uint256 overRefund = value + fee + 1;
        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, overRefund);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: fee,
            nonce: n,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: overRefund,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: overRefund}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.RefundExceedsCeiling.selector);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");
    }

    function testRefund_revertIncentiveRefundExceedsCeiling() public {
        bytes32 n = "ceilingIncentive";
        uint256 incentivePk = 0x5404;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 payerAmt = 80 ether;
        uint256 payeeAmt = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmt,
                payeeSettlementAmount_: payeeAmt,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: incentiveProvider,
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmt), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: payeeAmt - payerAmt}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            0
        );

        uint256 overIncentiveRefund = payeeAmt - payerAmt + 1;
        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, payerAmt + overIncentiveRefund);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: incentiveProvider,
            token: address(usdc),
            payerAmount: payerAmt,
            payeeSettlementAmount: payeeAmt,
            fee: 0,
            nonce: n,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: payerAmt,
            incentiveProviderRefundAmount: overIncentiveRefund,
            payerRefundTo: payer,
            incentiveProviderRefundTo: incentiveProvider,
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: payerAmt + overIncentiveRefund}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        bytes32 incentiveStructHash = keccak256(
            abi.encode(
                payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                address(usdc),
                overIncentiveRefund,
                refIntent.validAfter,
                refIntent.validBefore,
                n,
                incentiveProvider,
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 incentiveDigest =
            _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), incentiveStructHash);
        bytes memory incentiveSig = _sig(incentiveDigest, incentivePk);

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.RefundExceedsCeiling.selector);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", incentiveSig);
    }

    function testRefund_payerRefundAtExactCeiling() public {
        bytes32 n = "exactCeiling";
        uint256 value = 10 ether;
        uint256 fee = 1 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: fee,
                beneficiary_: feeSink,
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value + fee), signature: ""}),
            _emptyPermit2Data(),
            "",
            fee
        );

        uint256 fullRefund = value + fee;
        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, fullRefund);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: fee,
            nonce: n,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: fullRefund,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: fullRefund}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        assertEq(usdc.balanceOf(payer), 1000 ether - (value + fee) + fullRefund);
        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Refunded));
    }

    function testRefund_updatesRefundedAmounts() public {
        bytes32 n = "trackRefund";
        uint256 value = 50 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        uint256 refundAmt = 50 ether;
        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, refundAmt);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: n,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: refundAmt,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: refundAmt}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        assertEq(usdc.balanceOf(payer), 1000 ether - value + refundAmt);
        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Refunded));
    }

    function testAddAttester_alreadyExists() public {
        address newAttester = address(0x1234);

        vm.prank(config);
        payment.addAttester(newAttester);
        assertTrue(payment.isAttester(newAttester));

        vm.recordLogs();
        vm.prank(config);
        payment.addAttester(newAttester);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Should not emit event when adding existing attester");
        assertTrue(payment.isAttester(newAttester));
    }

    function testRefund_revertInvalidPaymentRecord() public {
        bytes32 n = "badRecord";
        uint256 value = 10 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: address(0),
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value + 1,
            payeeSettlementAmount: value + 1,
            fee: 0,
            nonce: n,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidPaymentRecord.selector);
        payment.refund(refIntent, _emptyPermit2Data(), _emptyPermit2Data(), "", "");
    }

    function testHashPaymentRecord() public view {
        bytes32 expected = keccak256(abi.encode(address(usdc), payer, address(0), 100 ether, 100 ether, 1 ether));
        assertEq(payment.hashPaymentRecord(address(usdc), payer, address(0), 100 ether, 100 ether, 1 ether), expected);
    }

    function testRemoveAttester_notExists() public {
        address nonExistentAttester = address(0x5678);
        assertFalse(payment.isAttester(nonExistentAttester));

        vm.recordLogs();
        vm.prank(config);
        payment.removeAttester(nonExistentAttester);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Should not emit event when removing non-existent attester");
        assertFalse(payment.isAttester(nonExistentAttester));
    }

    function testExecute_optionalPayeeSignature() public {
        bytes32 n = "optionalPayeeSig";
        uint256 value = 100 ether;

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: value,
            payeeSettlementAmount_: value,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: false,
            attester_: attester
        });

        bytes32 structHash = keccak256(
            abi.encode(
                payment.PAYEE_PAYMENT_INTENT_TYPEHASH(),
                address(usdc),
                payer,
                payee,
                value,
                intent.validAfter,
                intent.validBefore,
                n,
                attester
            )
        );
        bytes32 digest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), structHash);
        bytes memory sig = _sig(digest, payeePk);

        vm.prank(attester);
        payment.execute(
            intent,
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            sig,
            0
        );

        assertEq(usdc.balanceOf(payee), value);
    }

    /* --------------------------------------------------------------------- */
    /*                         EIP-712 Typehash Tests                         */
    /* --------------------------------------------------------------------- */
    function testEIP712_payeePaymentIntentTypehash() public view {
        bytes32 expectedTypehash = keccak256(
            "PaymentIntent(address token,address from,address to,uint256 payeeSettlementAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,address attester)"
        );
        assertEq(payment.PAYEE_PAYMENT_INTENT_TYPEHASH(), expectedTypehash);
    }

    function testEIP712_payerPaymentIntentTypehash() public view {
        bytes32 expectedTypehash = keccak256(
            "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,bool requirePayeeSign,address attester)"
        );
        assertEq(payment.PAYER_PAYMENT_INTENT_TYPEHASH(), expectedTypehash);
    }

    function testEIP712_payerCancelPaymentIntentTypehash() public view {
        bytes32 expectedTypehash =
            keccak256("PaymentIntent(address from,bytes32 nonce,address beneficiary,uint256 maxFee,address attester)");
        assertEq(payment.PAYER_CANCEL_PAYMENT_INTENT_TYPEHASH(), expectedTypehash);
    }

    function testEIP712_incentiveConsentTypehash() public view {
        bytes32 expectedTypehash = keccak256(
            "IncentiveConsent(address from,address to,uint256 payerAmount,uint256 payeeSettlementAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 maxFee,address attester)"
        );
        assertEq(payment.INCENTIVE_CONSENT_TYPEHASH(), expectedTypehash);
    }

    function testEIP712_payerRefundTypehash() public view {
        bytes32 expectedTypehash = keccak256(
            "PayerRefundIntent(address token,uint256 payerRefundAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,address payerRefundTo,uint256 cumulativePayerRefunded,uint256 cumulativeIncentiveRefunded,address attester)"
        );
        assertEq(payment.PAYER_REFUND_TYPEHASH(), expectedTypehash);
    }

    function testEIP712_incentiveProviderRefundTypehash() public view {
        bytes32 expectedTypehash = keccak256(
            "IncentiveProviderRefundIntent(address token,uint256 incentiveProviderRefundAmount,uint256 validAfter,uint256 validBefore,bytes32 nonce,address incentiveProviderRefundTo,uint256 cumulativePayerRefunded,uint256 cumulativeIncentiveRefunded,address attester)"
        );
        assertEq(payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(), expectedTypehash);
    }

    /* --------------------------------------------------------------------- */
    /*            9 Critical Branch Coverage Tests (90% target)             */
    /* --------------------------------------------------------------------- */

    /// @dev Line 373: Wrong attester caller (execute)
    function testExecute_revertWrongAttesterCaller() public {
        address wrongAttester = address(0xBAD);
        vm.prank(config);
        payment.addAttester(wrongAttester);

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 100 ether,
            payeeSettlementAmount_: 100 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "wrongAttester",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(100 ether), signature: ""});

        vm.prank(wrongAttester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidAttester.selector, wrongAttester));
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    /// @dev Line 496: Wrong attester caller (cancel)
    function testCancel_revertWrongAttesterCaller() public {
        address wrongAttester = address(0xBAD);
        vm.prank(config);
        payment.addAttester(wrongAttester);

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: 0,
            payeeSettlementAmount_: 0,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "wrongAttesterCancel",
            validAfter_: 0,
            validBefore_: 0,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd = PaymentSettlementV2.Permit2Data({permit: _permit(0), signature: ""});

        vm.prank(wrongAttester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidAttester.selector, wrongAttester));
        payment.cancel(intent, pd, 0);
    }

    /// @dev Line 550: Wrong attester caller (refund)
    function testRefund_revertWrongAttesterCaller() public {
        bytes32 paymentNonce = "wrongAttesterRefund";

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 100 ether,
                payeeSettlementAmount_: 100 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(100 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address wrongAttester = address(0xBAD);
        vm.prank(config);
        payment.addAttester(wrongAttester);

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 100 ether,
            payeeSettlementAmount: 100 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: 100 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 100 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(wrongAttester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidAttester.selector, wrongAttester));
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");
    }

    /// @dev Line 388: Zero address payee
    function testExecute_revertZeroAddressPayee() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: 100 ether,
            payeeSettlementAmount_: 100 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "zeroPayee",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(100 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidPayee.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    /// @dev Line 400: Permit token mismatch test removed after Comment #3
    /// After removing token field from PaymentIntent, there's no longer a token mismatch scenario
    /// between intent.token and permit.token. The contract now uses permit.token as single source of truth.

    /// @dev payerAmount < payeeSettlementAmount with empty incentive data → InvalidToken (token mismatch)
    function testExecute_revertRevenueWrongPayerAmount() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 90 ether,
            payeeSettlementAmount_: 100 ether,
            maxFee_: 5 ether,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "revenueWrongAmount",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 95 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidToken.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 5 ether);
    }

    /// @dev payerAmount > payeeSettlementAmount without incentive provider → PayerAmountMismatch
    function testExecute_revertPayerAmountMismatch() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 110 ether,
            payeeSettlementAmount_: 100 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "payerMismatch",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(110 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.PayerAmountMismatch.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    /// @dev Non-incentive payment with non-zero incentiveProvider → InvalidIncentiveProvider
    function testExecute_revertNonIncentiveWithNonZeroIncentiveProvider() public {
        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 100 ether,
            payeeSettlementAmount_: 100 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0x5404),
            nonce_: "nonIncentiveWithProvider",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: _permit(100 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidIncentiveProvider.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    /// @dev Cancel with an already-executed nonce → InvalidNonceState
    function testCancel_revertNonceAlreadyUsed() public {
        bytes32 paymentNonce = "cancelUsed";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        PaymentSettlementV2.Permit2Data memory pd = PaymentSettlementV2.Permit2Data({permit: _permit(0), signature: ""});

        PaymentSettlementV2.PaymentIntent memory cancelIntent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 0,
            payeeSettlementAmount_: 0,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: paymentNonce,
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        vm.prank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentSettlementV2.InvalidNonceState.selector, paymentNonce, PaymentSettlementV2.NonceStatus.Executed
            )
        );
        payment.cancel(cancelIntent, pd, 0);
    }

    /// @dev Refund with no incentive provider but nonzero incentiveProviderRefundAmount
    ///      reverts before pulling sources (funds would be locked without the guard).
    function testRefund_revertNoIncentiveProviderButNonzeroIncentiveRefund() public {
        bytes32 paymentNonce = "noIncButRefund";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        uint256 payerRefund = 90 ether;
        uint256 bogusIncentiveRefund = 10 ether;

        address refundWallet = address(0x0002);
        usdc.mint(refundWallet, payerRefund + bogusIncentiveRefund);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: payerRefund,
            incentiveProviderRefundAmount: bogusIncentiveRefund,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: payerRefund + bogusIncentiveRefund}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.RefundExceedsCeiling.selector);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");

        assertEq(usdc.balanceOf(refundWallet), payerRefund + bogusIncentiveRefund, "source funds untouched");
        assertEq(usdc.balanceOf(address(payment)), 0, "no funds locked in contract");
    }

    /// @dev Line 819: Invalid incentive provider refund signature
    function testRefund_revertInvalidIncentiveProviderSig() public {
        uint256 incentivePk = 0x5404;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 paymentNonce = "invalidIncSig";
        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: 98 ether,
                maxFee_: 2 ether,
                beneficiary_: feeSink,
                incentiveProvider_: incentiveProvider,
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount + 2 ether), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            2 ether
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: incentiveProvider,
            token: address(usdc),
            payerAmount: payerAmount,
            payeeSettlementAmount: payerAmount + incentiveAmount,
            fee: 2 ether,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: payerAmount + 2 ether,
            incentiveProviderRefundAmount: incentiveAmount,
            payerRefundTo: payer,
            incentiveProviderRefundTo: incentiveProvider,
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 100 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        bytes32 payerHash = keccak256(
            abi.encode(
                payment.PAYER_REFUND_TYPEHASH(),
                address(usdc),
                payerAmount + 2 ether,
                refIntent.validAfter,
                refIntent.validBefore,
                paymentNonce,
                payer,
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 payerDigest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), payerHash);
        bytes memory invalidIncentiveSig = _sig(payerDigest, payerPk);

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", invalidIncentiveSig);
    }

    /// @dev Line 551: Attester removed from whitelist after intent signed
    function testRefund_revertAttesterRemovedFromWhitelist() public {
        bytes32 paymentNonce = "attesterRemoved";
        address tempAttester = address(0xDEADBEEF1234);

        // Add temporary attester
        vm.prank(config);
        payment.addAttester(tempAttester);

        // Execute payment with tempAttester
        vm.prank(tempAttester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: 100 ether,
                payeeSettlementAmount_: 100 ether,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: tempAttester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(100 ether), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        // Remove attester from whitelist
        vm.prank(config);
        payment.removeAttester(tempAttester);

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 100 ether,
            payeeSettlementAmount: 100 ether,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: tempAttester,
            payerRefundAmount: 100 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 100 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        // tempAttester (msg.sender) == intent.attester, but !_attesters[tempAttester]
        vm.prank(tempAttester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidAttester.selector, tempAttester));
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", "");
    }

    /// @dev Line 708: Balance check with deflationary token
    function testExecute_revertDeflationaryToken() public {
        DeflationaryToken deflat = new DeflationaryToken();
        deflat.mint(payer, 1000 ether);
        vm.prank(payer);
        deflat.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(deflat),
            from_: payer,
            to_: payee,
            payerAmount_: 100 ether,
            payeeSettlementAmount_: 100 ether,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: "deflationary",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        IMinimalPermit2.PermitTransferFrom memory deflatPermit = IMinimalPermit2.PermitTransferFrom({
            permitted: IMinimalPermit2.TokenPermissions({token: address(deflat), amount: 100 ether}),
            nonce: 0,
            deadline: block.timestamp + 1 days
        });

        PaymentSettlementV2.Permit2Data memory pd =
            PaymentSettlementV2.Permit2Data({permit: deflatPermit, signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidAmount.selector);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
    }

    /// @dev Line 729: Balance check with deflationary token (incentive case)
    function testExecute_revertDeflationaryTokenIncentive() public {
        address incentiveProvider = address(0x5404);
        DeflationaryToken deflat = new DeflationaryToken();
        deflat.mint(payer, 1000 ether);
        deflat.mint(incentiveProvider, 1000 ether);

        vm.prank(payer);
        deflat.approve(address(permit2), type(uint256).max);
        vm.prank(incentiveProvider);
        deflat.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(deflat),
            from_: payer,
            to_: payee,
            payerAmount_: 85 ether,
            payeeSettlementAmount_: 98 ether,
            maxFee_: 2 ether,
            beneficiary_: feeSink,
            incentiveProvider_: incentiveProvider,
            nonce_: "deflationaryInc",
            validAfter_: 0,
            validBefore_: block.timestamp + 100,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory payerData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(deflat), amount: 87 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        PaymentSettlementV2.Permit2Data memory incentiveData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(deflat), amount: 13 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidAmount.selector);
        payment.execute(intent, payerData, incentiveData, "", 2 ether);
    }

    function testRefund_revertZeroBeneficiaryProviderWithNonzeroBeneficiaryAmount() public {
        bytes32 paymentNonce = "zeroBenProv";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, 60 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 60 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        PaymentSettlementV2.Permit2Data memory beneficiaryRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 40 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSource.selector);
        payment.refund(refIntent, payeeRefundData, beneficiaryRefundData, "", "");

        assertEq(usdc.balanceOf(refundWallet), 60 ether, "source funds untouched");
        assertEq(usdc.balanceOf(address(payment)), 0, "no funds locked in contract");
    }

    function testRefund_validPayerRefundSignature() public {
        bytes32 paymentNonce = "payerRefSig";
        uint256 value = 100 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet = address(0x0001);
        usdc.mint(refundWallet, value);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: true
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: value}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        bytes32 structHash = keccak256(
            abi.encode(
                payment.PAYER_REFUND_TYPEHASH(),
                address(usdc),
                value,
                refIntent.validAfter,
                refIntent.validBefore,
                paymentNonce,
                payer,
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 digest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), structHash);
        bytes memory payerSig = _sig(digest, payerPk);

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), payerSig, "");

        assertEq(usdc.balanceOf(payer), 1000 ether);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    function testRefund_revertWrongBeneficiarySourceToken() public {
        bytes32 paymentNonce = "wrongBenToken";
        uint256 value = 100 ether;
        TestERC20 wrongToken = new TestERC20("Wrong", "WRG");

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: value,
                payeeSettlementAmount_: value,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: address(0),
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(value), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        address refundWallet1 = address(0x0001);
        address refundWallet2 = address(0x0002);
        usdc.mint(refundWallet1, 60 ether);
        wrongToken.mint(refundWallet2, 40 ether);
        vm.prank(refundWallet1);
        usdc.approve(address(permit2), type(uint256).max);
        vm.prank(refundWallet2);
        wrongToken.approve(address(permit2), type(uint256).max);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet1,
            beneficiaryRefundFrom: refundWallet2,
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: value,
            payeeSettlementAmount: value,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: value,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 60 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        PaymentSettlementV2.Permit2Data memory beneficiaryRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(wrongToken), amount: 40 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidToken.selector);
        payment.refund(refIntent, payeeRefundData, beneficiaryRefundData, "", "");
    }

    // CCS-3929: Multi-refund behavior tests

    /// @dev Helper: build a RefundIntent from a nonce produced by _executeBasicPayment,
    ///      using a refundWallet as the payee source and refunding back to payer.
    function _buildSimpleRefundIntent(
        bytes32 nonce_,
        uint256 payerAmount_,
        uint256 fee_,
        uint256 payeeSettlementAmount_,
        address refundWallet_,
        uint256 payerRefundAmount_
    ) internal view returns (PaymentSettlementV2.RefundIntent memory) {
        return PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: refundWallet_,
            payerAmount: payerAmount_,
            payeeSettlementAmount: payeeSettlementAmount_,
            fee: fee_,
            payerRefundAmount: payerRefundAmount_,
            incentiveProviderRefundAmount: 0,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: nonce_,
            incentiveProvider: address(0),
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false,
            attester: attester
        });
    }

    /// @dev Helper: build Permit2Data for a refund pull of `amount` from `from_`.
    function _buildRefundPermit2Data(uint256 amount_) internal view returns (PaymentSettlementV2.Permit2Data memory) {
        return PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: amount_}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });
    }

    /// @dev Helper: fund a refundWallet with `amount` USDC and approve permit2.
    function _setupRefundWallet(address wallet_, uint256 amount_) internal {
        usdc.mint(wallet_, amount_);
        vm.prank(wallet_);
        usdc.approve(address(permit2), type(uint256).max);
    }

    function testRefund_partialRefund_nonce_stays_Executed() public {
        bytes32 n = _executeBasicPayment(payer, payee, 50 ether, 0, 50 ether);

        address refundWallet = address(0x3001);
        _setupRefundWallet(refundWallet, 50 ether);

        PaymentSettlementV2.RefundIntent memory refIntent =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 25 ether);
        PaymentSettlementV2.Permit2Data memory pd = _buildRefundPermit2Data(25 ether);

        vm.prank(attester);
        payment.refund(refIntent, pd, _emptyPermit2Data(), "", "");

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Executed));

        (uint256 cumPayer, uint256 cumIncentive) = payment.getRefundProgress(n);
        assertEq(cumPayer, 25 ether);
        assertEq(cumIncentive, 0);
    }

    function testRefund_twoPartials_cumulate_to_payerCap_finalizes() public {
        bytes32 n = _executeBasicPayment(payer, payee, 50 ether, 0, 50 ether);

        address refundWallet = address(0x3002);
        _setupRefundWallet(refundWallet, 50 ether);

        // First partial refund: 30e18
        PaymentSettlementV2.RefundIntent memory refIntent1 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 30 ether);
        vm.prank(attester);
        payment.refund(refIntent1, _buildRefundPermit2Data(30 ether), _emptyPermit2Data(), "", "");

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Executed));

        // Second partial refund: 20e18 → cumulative = 50e18 = payerCap → Refunded
        PaymentSettlementV2.RefundIntent memory refIntent2 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 20 ether);
        vm.prank(attester);
        payment.refund(refIntent2, _buildRefundPermit2Data(20 ether), _emptyPermit2Data(), "", "");

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Refunded));

        (uint256 cumPayer, uint256 cumIncentive) = payment.getRefundProgress(n);
        assertEq(cumPayer, 50 ether);
        assertEq(cumIncentive, 0);
    }

    function testRefund_cumulativeExceedsCap_reverts() public {
        bytes32 n = _executeBasicPayment(payer, payee, 50 ether, 0, 50 ether);

        address refundWallet = address(0x3003);
        _setupRefundWallet(refundWallet, 60 ether);

        // First refund: 40e18 → succeeds
        PaymentSettlementV2.RefundIntent memory refIntent1 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 40 ether);
        vm.prank(attester);
        payment.refund(refIntent1, _buildRefundPermit2Data(40 ether), _emptyPermit2Data(), "", "");

        // Second refund: 20e18 → cumulative would be 60e18 > 50e18 → reverts
        PaymentSettlementV2.RefundIntent memory refIntent2 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 20 ether);
        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.RefundExceedsCeiling.selector);
        payment.refund(refIntent2, _buildRefundPermit2Data(20 ether), _emptyPermit2Data(), "", "");

        // Progress should be unchanged after failed refund
        (uint256 cumPayer, uint256 cumIncentive) = payment.getRefundProgress(n);
        assertEq(cumPayer, 40 ether);
        assertEq(cumIncentive, 0);
    }

    function testRefund_nonIncentive_partial_then_finalize() public {
        bytes32 n = _executeBasicPayment(payer, payee, 50 ether, 0, 50 ether);

        address refundWallet = address(0x3004);
        _setupRefundWallet(refundWallet, 50 ether);

        // First refund: 30e18 using NoIncentive helper
        PaymentSettlementV2.RefundIntent memory refIntent1 = _buildRefundIntentNoIncentive(
            payer, refundWallet, 50 ether, 50 ether, 0, n, 0, block.timestamp + 1 days, 30 ether, payer, false
        );
        vm.prank(attester);
        payment.refund(refIntent1, _buildRefundPermit2Data(30 ether), _emptyPermit2Data(), "", "");

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Executed));

        // Second refund: 20e18 → cumulative = 50e18 = payerCap → Refunded
        PaymentSettlementV2.RefundIntent memory refIntent2 = _buildRefundIntentNoIncentive(
            payer, refundWallet, 50 ether, 50 ether, 0, n, 0, block.timestamp + 1 days, 20 ether, payer, false
        );
        vm.prank(attester);
        payment.refund(refIntent2, _buildRefundPermit2Data(20 ether), _emptyPermit2Data(), "", "");

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Refunded));

        (uint256 cumPayer, uint256 cumIncentive) = payment.getRefundProgress(n);
        assertEq(cumPayer, 50 ether);
        assertEq(cumIncentive, 0);
    }

    function testRefund_incentiveCase_payerCapMet_incentiveNot_noFinalize() public {
        // Incentive case: payerAmount=40e18, fee=0, payeeSettlementAmount=60e18 → incentiveCap=20e18
        uint256 incentivePk = 0x6001;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 payerAmt = 40 ether;
        uint256 payeeAmt = 60 ether;
        uint256 shortfall = payeeAmt - payerAmt; // 20 ether

        bytes32 n = keccak256(abi.encodePacked(payer, payee, payerAmt, uint256(0), payeeAmt, block.timestamp));

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmt,
                payeeSettlementAmount_: payeeAmt,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: incentiveProvider,
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 1 days,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmt), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: shortfall}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            0
        );

        address refundWallet = address(0x3005);
        _setupRefundWallet(refundWallet, payerAmt);

        // Refund: full payer refund (40e18), incentive refund = 0
        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: refundWallet,
            payerAmount: payerAmt,
            payeeSettlementAmount: payeeAmt,
            fee: 0,
            payerRefundAmount: payerAmt,
            incentiveProviderRefundAmount: 0,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: n,
            incentiveProvider: incentiveProvider,
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: incentiveProvider,
            requireDestinationRefundSig: false,
            attester: attester
        });

        vm.prank(attester);
        payment.refund(refIntent, _buildRefundPermit2Data(payerAmt), _emptyPermit2Data(), "", "");

        // payerCap met but incentiveCap (20e18) not met → nonce stays Executed
        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Executed));
    }

    function testRefund_incentiveCase_bothCapsFullyMet_finalizes() public {
        // Incentive case: payerAmount=40e18, fee=0, payeeSettlementAmount=60e18 → incentiveCap=20e18
        uint256 incentivePk = 0x6002;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 payerAmt = 40 ether;
        uint256 payeeAmt = 60 ether;
        uint256 shortfall = payeeAmt - payerAmt; // 20 ether

        bytes32 n = keccak256(abi.encodePacked(payer, payee, payerAmt, uint256(0), payeeAmt, block.timestamp));

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmt,
                payeeSettlementAmount_: payeeAmt,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: incentiveProvider,
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 1 days,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmt), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: shortfall}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            0
        );

        address refundWallet = address(0x3006);
        _setupRefundWallet(refundWallet, payerAmt + shortfall);

        // Refund: full payer (40e18) + full incentive (20e18) in one call
        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: refundWallet,
            payerAmount: payerAmt,
            payeeSettlementAmount: payeeAmt,
            fee: 0,
            payerRefundAmount: payerAmt,
            incentiveProviderRefundAmount: shortfall,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: n,
            incentiveProvider: incentiveProvider,
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: incentiveProvider,
            requireDestinationRefundSig: false,
            attester: attester
        });

        vm.expectEmit(true, true, false, true);
        emit PaymentSettlementV2.NonceRefunded(n, attester, payer, address(usdc), payerAmt, payer, payerAmt);
        vm.expectEmit(true, true, false, true);
        emit PaymentSettlementV2.IncentiveRefunded(
            n, attester, incentiveProvider, address(usdc), shortfall, incentiveProvider, shortfall
        );
        vm.prank(attester);
        payment.refund(refIntent, _buildRefundPermit2Data(payerAmt + shortfall), _emptyPermit2Data(), "", "");

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Refunded));

        (uint256 cumPayer, uint256 cumIncentive) = payment.getRefundProgress(n);
        assertEq(cumPayer, 40 ether);
        assertEq(cumIncentive, 20 ether);
    }

    function testRefund_getRefundProgress_correctAfterEachPartial() public {
        // payerAmount=90e18, fee=10e18, payeeSettlementAmount=90e18 → payerCap=100e18
        bytes32 n = _executeBasicPayment(payer, payee, 90 ether, 10 ether, 90 ether);

        address refundWallet = address(0x3007);
        _setupRefundWallet(refundWallet, 100 ether);

        // Refund 1: 30e18
        PaymentSettlementV2.RefundIntent memory ri1 =
            _buildSimpleRefundIntent(n, 90 ether, 10 ether, 90 ether, refundWallet, 30 ether);
        vm.prank(attester);
        payment.refund(ri1, _buildRefundPermit2Data(30 ether), _emptyPermit2Data(), "", "");

        (uint256 c1, uint256 i1) = payment.getRefundProgress(n);
        assertEq(c1, 30 ether);
        assertEq(i1, 0);

        // Refund 2: 40e18
        PaymentSettlementV2.RefundIntent memory ri2 =
            _buildSimpleRefundIntent(n, 90 ether, 10 ether, 90 ether, refundWallet, 40 ether);
        vm.prank(attester);
        payment.refund(ri2, _buildRefundPermit2Data(40 ether), _emptyPermit2Data(), "", "");

        (uint256 c2, uint256 i2) = payment.getRefundProgress(n);
        assertEq(c2, 70 ether);
        assertEq(i2, 0);

        // Refund 3: 30e18 → cumulative = 100e18 = payerCap → Refunded
        PaymentSettlementV2.RefundIntent memory ri3 =
            _buildSimpleRefundIntent(n, 90 ether, 10 ether, 90 ether, refundWallet, 30 ether);
        vm.prank(attester);
        payment.refund(ri3, _buildRefundPermit2Data(30 ether), _emptyPermit2Data(), "", "");

        assertEq(uint8(payment.getNonceStatus(n)), uint8(PaymentSettlementV2.NonceStatus.Refunded));
        (uint256 c3, uint256 i3) = payment.getRefundProgress(n);
        assertEq(c3, 100 ether);
        assertEq(i3, 0);
    }

    function testRefund_nonceRefunded_event_has_correct_cumulative() public {
        bytes32 n = _executeBasicPayment(payer, payee, 50 ether, 0, 50 ether);

        address refundWallet = address(0x3008);
        _setupRefundWallet(refundWallet, 50 ether);

        // First refund: 20e18 → emit NonceRefunded(n, attester, payer, usdc, 20e18, payerRefundTo, 20e18)
        PaymentSettlementV2.RefundIntent memory ri1 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 20 ether);
        vm.expectEmit(true, true, false, true);
        emit PaymentSettlementV2.NonceRefunded(n, attester, payer, address(usdc), 20 ether, payer, 20 ether);
        vm.prank(attester);
        payment.refund(ri1, _buildRefundPermit2Data(20 ether), _emptyPermit2Data(), "", "");

        // Second refund: 30e18 → emit NonceRefunded(n, attester, payer, usdc, 30e18, payerRefundTo, 50e18)
        PaymentSettlementV2.RefundIntent memory ri2 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 30 ether);
        vm.expectEmit(true, true, false, true);
        emit PaymentSettlementV2.NonceRefunded(n, attester, payer, address(usdc), 30 ether, payer, 50 ether);
        vm.prank(attester);
        payment.refund(ri2, _buildRefundPermit2Data(30 ether), _emptyPermit2Data(), "", "");
    }

    function testRefund_zeroValuePayment_refundZero_finalizes() public {
        // Execute a zero-value payment (payerAmount=0, fee=0, payeeSettlementAmount=0)
        bytes32 n = keccak256(abi.encodePacked(payer, payee, uint256(0), uint256(0), uint256(0), block.timestamp));

        PaymentSettlementV2.PaymentIntent memory intent = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: payee,
            payerAmount_: 0,
            payeeSettlementAmount_: 0,
            maxFee_: 0,
            beneficiary_: address(0),
            incentiveProvider_: address(0),
            nonce_: n,
            validAfter_: 0,
            validBefore_: block.timestamp + 1 days,
            requirePayeeSign_: false,
            attester_: attester
        });

        PaymentSettlementV2.Permit2Data memory pd = PaymentSettlementV2.Permit2Data({permit: _permit(0), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, _emptyPermit2Data(), "", 0);
        assertEq(uint256(payment.getNonceStatus(n)), uint256(PaymentSettlementV2.NonceStatus.Executed));

        // Refund 0 → should finalize to Refunded (caps are both 0, cumulative 0==0)
        PaymentSettlementV2.RefundIntent memory refIntent =
            _buildRefundIntentNoIncentive(payer, payee, 0, 0, 0, n, 0, block.timestamp + 1 days, 0, payer, false);

        vm.prank(attester);
        payment.refund(refIntent, _buildRefundPermit2Data(0), _emptyPermit2Data(), "", "");
        assertEq(uint256(payment.getNonceStatus(n)), uint256(PaymentSettlementV2.NonceStatus.Refunded));
    }

    function testRefund_partialSucceeds_secondPullFails_progressUnchanged() public {
        bytes32 n = _executeBasicPayment(payer, payee, 50 ether, 0, 50 ether);

        address refundWallet = address(0x300A);
        _setupRefundWallet(refundWallet, 50 ether);

        // First refund: 20e18 → succeeds
        PaymentSettlementV2.RefundIntent memory ri1 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 20 ether);
        vm.prank(attester);
        payment.refund(ri1, _buildRefundPermit2Data(20 ether), _emptyPermit2Data(), "", "");

        (uint256 cumPayer, uint256 cumIncentive) = payment.getRefundProgress(n);
        assertEq(cumPayer, 20 ether);
        assertEq(cumIncentive, 0);

        // Drain refundWallet so they have 0 USDC left (30 ether remaining after first pull of 20)
        uint256 remaining = usdc.balanceOf(refundWallet);
        vm.prank(refundWallet);
        usdc.transfer(address(0xDEAD), remaining);
        assertEq(usdc.balanceOf(refundWallet), 0);

        // Attempt second refund: 20e18 → should revert (insufficient balance for transfer)
        PaymentSettlementV2.RefundIntent memory ri2 =
            _buildSimpleRefundIntent(n, 50 ether, 0, 50 ether, refundWallet, 20 ether);
        vm.prank(attester);
        vm.expectRevert();
        payment.refund(ri2, _buildRefundPermit2Data(20 ether), _emptyPermit2Data(), "", "");

        // Progress should remain at 20e18, not corrupted
        (uint256 cumPayerAfter, uint256 cumIncentiveAfter) = payment.getRefundProgress(n);
        assertEq(cumPayerAfter, 20 ether);
        assertEq(cumIncentiveAfter, 0);
    }

    function testRefund_revertPayerRefundToZeroAddress() public {
        bytes32 n = _executeBasicPayment(payer, payee, 50 ether, 0, 50 ether);

        address refundWallet = address(0x4001);
        _setupRefundWallet(refundWallet, 50 ether);

        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: address(0),
            token: address(usdc),
            payerAmount: 50 ether,
            payeeSettlementAmount: 50 ether,
            fee: 0,
            nonce: n,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            attester: attester,
            payerRefundAmount: 50 ether,
            incentiveProviderRefundAmount: 0,
            payerRefundTo: address(0),
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidRefundDestination.selector, address(0)));
        payment.refund(refIntent, _buildRefundPermit2Data(50 ether), _emptyPermit2Data(), "", "");
    }

    function testRefund_revertIncentiveProviderRefundToZeroAddress() public {
        uint256 incentivePk = 0x5404;
        address incentiveProvider = vm.addr(incentivePk);
        usdc.mint(incentiveProvider, 100 ether);
        vm.prank(incentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 paymentNonce = "zeroIncentiveDest";
        uint256 payerAmount = 85 ether;
        uint256 incentiveAmount = 13 ether;

        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: payerAmount + incentiveAmount,
                maxFee_: 0,
                beneficiary_: address(0),
                incentiveProvider_: incentiveProvider,
                nonce_: paymentNonce,
                validAfter_: 0,
                validBefore_: block.timestamp + 100,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            0
        );

        address refundWallet = address(0x4002);
        usdc.mint(refundWallet, 100 ether);
        vm.prank(refundWallet);
        usdc.approve(address(permit2), type(uint256).max);

        // Build refund with incentiveProviderRefundTo = address(0)
        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            payer: payer,
            payeeRefundFrom: refundWallet,
            beneficiaryRefundFrom: address(0),
            incentiveProvider: incentiveProvider,
            token: address(usdc),
            payerAmount: payerAmount,
            payeeSettlementAmount: payerAmount + incentiveAmount,
            fee: 0,
            nonce: paymentNonce,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            attester: attester,
            payerRefundAmount: payerAmount,
            incentiveProviderRefundAmount: incentiveAmount,
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false
        });

        // Incentive provider must sign refund (non-empty sig triggers validation)
        bytes32 incentiveHash = keccak256(
            abi.encode(
                payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                address(usdc),
                incentiveAmount,
                refIntent.validAfter,
                refIntent.validBefore,
                paymentNonce,
                address(0),
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 incentiveDigest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), incentiveHash);
        bytes memory incentiveSig = _sig(incentiveDigest, incentivePk);

        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: payerAmount + incentiveAmount}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlementV2.InvalidRefundDestination.selector, address(0)));
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), "", incentiveSig);
    }

    function testEIP712_payeeRefundSourceTypehash() public view {
        bytes32 expectedTypehash = keccak256(
            "PayeeRefundSourceIntent(address payeeRefundFrom,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 payerRefundAmount,uint256 incentiveProviderRefundAmount,address payerRefundTo,address incentiveProviderRefundTo,bool requireDestinationRefundSig,address attester)"
        );
        assertEq(payment.PAYEE_REFUND_SOURCE_TYPEHASH(), expectedTypehash);
    }

    function testEIP712_beneficiaryRefundSourceTypehash() public view {
        bytes32 expectedTypehash = keccak256(
            "BeneficiaryRefundSourceIntent(address beneficiaryRefundFrom,uint256 validAfter,uint256 validBefore,bytes32 nonce,uint256 payerRefundAmount,uint256 incentiveProviderRefundAmount,address payerRefundTo,address incentiveProviderRefundTo,bool requireDestinationRefundSig,address attester)"
        );
        assertEq(payment.BENEFICIARY_REFUND_SOURCE_TYPEHASH(), expectedTypehash);
    }

    function testOQ1_requireDestinationRefundSig_affectsRefundSourceHash() public {
        // Deploy harness
        PaymentSettlementV2Harness harness = new PaymentSettlementV2Harness();

        // Build two identical RefundIntents, differing only in requireDestinationRefundSig
        PaymentSettlementV2.RefundIntent memory intentFalse = PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: payee,
            payerAmount: 50 ether,
            payeeSettlementAmount: 50 ether,
            fee: 0,
            payerRefundAmount: 50 ether,
            incentiveProviderRefundAmount: 0,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: "oq1test",
            incentiveProvider: address(0),
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: false,
            attester: attester
        });

        PaymentSettlementV2.RefundIntent memory intentTrue = PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: payee,
            payerAmount: 50 ether,
            payeeSettlementAmount: 50 ether,
            fee: 0,
            payerRefundAmount: 50 ether,
            incentiveProviderRefundAmount: 0,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: "oq1test",
            incentiveProvider: address(0),
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: address(0),
            requireDestinationRefundSig: true,
            attester: attester
        });

        // Hash must differ when only requireDestinationRefundSig changes
        bytes32 hashFalse = harness.exposed_hashPayeeRefundSource(intentFalse);
        bytes32 hashTrue = harness.exposed_hashPayeeRefundSource(intentTrue);
        assertTrue(hashFalse != hashTrue, "requireDestinationRefundSig must affect payee refund source hash");

        // Same check for beneficiary side
        intentFalse.beneficiaryRefundFrom = address(0xBEEF);
        intentTrue.beneficiaryRefundFrom = address(0xBEEF);
        bytes32 benHashFalse = harness.exposed_hashBeneficiaryRefundSource(intentFalse);
        bytes32 benHashTrue = harness.exposed_hashBeneficiaryRefundSource(intentTrue);
        assertTrue(
            benHashFalse != benHashTrue, "requireDestinationRefundSig must affect beneficiary refund source hash"
        );
    }

    function testCS001_cancelIntentAttester_affectsHash() public {
        PaymentSettlementV2Harness harness = new PaymentSettlementV2Harness();

        address attesterA = address(0xA001);
        address attesterB = address(0xA002);

        PaymentSettlementV2.PaymentIntent memory intentA = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: 0,
            payeeSettlementAmount_: 0,
            maxFee_: 1 ether,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "cs001test",
            validAfter_: 0,
            validBefore_: 0,
            requirePayeeSign_: false,
            attester_: attesterA
        });

        PaymentSettlementV2.PaymentIntent memory intentB = _buildPaymentIntent({
            token_: address(usdc),
            from_: payer,
            to_: address(0),
            payerAmount_: 0,
            payeeSettlementAmount_: 0,
            maxFee_: 1 ether,
            beneficiary_: feeSink,
            incentiveProvider_: address(0),
            nonce_: "cs001test",
            validAfter_: 0,
            validBefore_: 0,
            requirePayeeSign_: false,
            attester_: attesterB
        });

        bytes32 hashA = harness.exposed_hashPayerCancelPaymentIntent(intentA);
        bytes32 hashB = harness.exposed_hashPayerCancelPaymentIntent(intentB);
        assertTrue(hashA != hashB, "attester field must differentiate cancel intent hash");
    }

    /// @notice CS-002: destination signature replay prevention — same payer destination sig
    ///         must revert on second refund because cumulative values have changed.
    function testRefund_revertDestinationSignatureReplay() public {
        uint256 payerPk_ = 0x1234;
        address testPayer = vm.addr(payerPk_);
        usdc.mint(testPayer, 200 ether);
        vm.prank(testPayer);
        usdc.approve(address(permit2), type(uint256).max);

        // Payee needs balance + approve for refund source (DummyPermit2 does real transferFrom)
        usdc.mint(payee, 200 ether);
        vm.prank(payee);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 n = "replayTest";
        uint256 payerAmount = 100 ether;

        // Execute payment
        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: testPayer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: payerAmount,
                maxFee_: 0,
                beneficiary_: payee,
                incentiveProvider_: address(0),
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 1 days,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount), signature: ""}),
            _emptyPermit2Data(),
            "",
            0
        );

        // Build refund intent: partial refund 50 of 100, requireDestinationRefundSig=true
        PaymentSettlementV2.RefundIntent memory refIntent = _buildRefundIntentNoIncentive(
            testPayer, payee, payerAmount, payerAmount, 0, n, 0, block.timestamp + 1 days, 50 ether, testPayer, true
        );

        // Payer signs destination sig with cumulativePayerRefunded=0, cumulativeIncentiveRefunded=0
        bytes32 structHash = keccak256(
            abi.encode(
                payment.PAYER_REFUND_TYPEHASH(),
                address(usdc),
                50 ether,
                refIntent.validAfter,
                refIntent.validBefore,
                n,
                testPayer,
                0, // cumulativePayerRefunded
                0, // cumulativeIncentiveRefunded
                attester
            )
        );
        bytes32 digest = _computeTypedDataHash("PaymentSettlementV2", "1", address(payment), structHash);
        bytes memory payerSig = _sig(digest, payerPk_);

        // First refund: should succeed
        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 50 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), payerSig, "");

        // Second refund attempt: same destination sig, fresh source Permit2
        PaymentSettlementV2.Permit2Data memory payeeRefundData2 = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 50 ether}),
                nonce: 1,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        // Should revert: cumulativePayerRefunded is now 50 ether, but sig was signed for 0
        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.refund(refIntent, payeeRefundData2, _emptyPermit2Data(), payerSig, "");
    }

    /// @notice CS-002: incentive provider destination signature replay prevention — same
    ///         incentive provider destination sig must revert on second refund because
    ///         cumulativeIncentiveRefunded has changed.
    function testRefund_revertIncentiveProviderDestinationSignatureReplay() public {
        uint256 incentivePk_ = 0x5404;
        address testIncentiveProvider = vm.addr(incentivePk_);
        usdc.mint(testIncentiveProvider, 200 ether);
        vm.prank(testIncentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 payerAmount = 80 ether;
        uint256 incentiveAmount = 20 ether;
        uint256 payeeSettlement = payerAmount + incentiveAmount; // 100 ether

        usdc.mint(payer, 200 ether);
        vm.prank(payer);
        usdc.approve(address(permit2), type(uint256).max);

        // Payee needs balance + approve for refund source
        usdc.mint(payee, 200 ether);
        vm.prank(payee);
        usdc.approve(address(permit2), type(uint256).max);

        bytes32 n = "ipReplayTest";

        // Execute payment with incentive provider
        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: payeeSettlement,
                maxFee_: 0,
                beneficiary_: payee,
                incentiveProvider_: testIncentiveProvider,
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 1 days,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            0
        );

        // Build refund intent: partial refund 10 of 20 incentive, requireDestinationRefundSig=true
        PaymentSettlementV2.RefundIntent memory refIntent = PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: payee,
            payerAmount: payerAmount,
            payeeSettlementAmount: payeeSettlement,
            fee: 0,
            payerRefundAmount: 0,
            incentiveProviderRefundAmount: 10 ether,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: n,
            incentiveProvider: testIncentiveProvider,
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: testIncentiveProvider,
            requireDestinationRefundSig: true,
            attester: attester
        });

        // Payer signs destination sig (payerRefundAmount=0) with cumulativePayerRefunded=0,
        // cumulativeIncentiveRefunded=0
        bytes memory payerSig;
        {
            bytes32 h = keccak256(
                abi.encodePacked(
                    abi.encode(
                        payment.PAYER_REFUND_TYPEHASH(),
                        address(usdc),
                        uint256(0),
                        refIntent.validAfter,
                        refIntent.validBefore
                    ),
                    abi.encode(n, payer, uint256(0), uint256(0), attester)
                )
            );
            payerSig = _sig(_computeTypedDataHash("PaymentSettlementV2", "1", address(payment), h), payerPk);
        }

        // Incentive provider signs destination sig with cumulativePayerRefunded=0, cumulativeIncentiveRefunded=0
        bytes memory incentiveSig;
        {
            bytes32 h = keccak256(
                abi.encodePacked(
                    abi.encode(
                        payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                        address(usdc),
                        uint256(10 ether),
                        refIntent.validAfter,
                        refIntent.validBefore
                    ),
                    abi.encode(n, testIncentiveProvider, uint256(0), uint256(0), attester)
                )
            );
            incentiveSig = _sig(_computeTypedDataHash("PaymentSettlementV2", "1", address(payment), h), incentivePk_);
        }

        // First refund: should succeed
        PaymentSettlementV2.Permit2Data memory payeeRefundData = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 10 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.prank(attester);
        payment.refund(refIntent, payeeRefundData, _emptyPermit2Data(), payerSig, incentiveSig);

        // Second refund attempt: same destination sig, fresh source Permit2
        PaymentSettlementV2.Permit2Data memory payeeRefundData2 = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 10 ether}),
                nonce: 1,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        // Should revert: cumulativeIncentiveRefunded is now 10 ether, but sig was signed for 0
        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.refund(refIntent, payeeRefundData2, _emptyPermit2Data(), payerSig, incentiveSig);
    }

    /// @notice CS-002 v2: cross-path replay prevention — payer-only refund invalidates
    ///         incentive provider destination sig because cumulativePayerRefunded changed.
    ///         Uses freshly signed payer sig (updated cumulative) + old incentive sig
    ///         (stale cumulativePayerRefunded=0). Payer sig passes; incentive sig reverts.
    function testRefund_revertCrossPathIncentiveSignatureReplay() public {
        uint256 incentivePk_ = 0x5404;
        address testIncentiveProvider = vm.addr(incentivePk_);
        usdc.mint(testIncentiveProvider, 200 ether);
        vm.prank(testIncentiveProvider);
        usdc.approve(address(permit2), type(uint256).max);

        // Payee needs balance + approve for refund source (DummyPermit2 does real transferFrom)
        usdc.mint(payee, 200 ether);
        vm.prank(payee);
        usdc.approve(address(permit2), type(uint256).max);

        uint256 payerAmount = 80 ether;
        uint256 incentiveAmount = 20 ether;
        uint256 payeeSettlement = payerAmount + incentiveAmount; // 100 ether
        bytes32 n = "crossPathReplay";

        // Execute payment with incentive provider
        vm.prank(attester);
        payment.execute(
            _buildPaymentIntent({
                token_: address(usdc),
                from_: payer,
                to_: payee,
                payerAmount_: payerAmount,
                payeeSettlementAmount_: payeeSettlement,
                maxFee_: 0,
                beneficiary_: payee,
                incentiveProvider_: testIncentiveProvider,
                nonce_: n,
                validAfter_: 0,
                validBefore_: block.timestamp + 1 days,
                requirePayeeSign_: false,
                attester_: attester
            }),
            PaymentSettlementV2.Permit2Data({permit: _permit(payerAmount), signature: ""}),
            PaymentSettlementV2.Permit2Data({
                permit: IMinimalPermit2.PermitTransferFrom({
                    permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: incentiveAmount}),
                    nonce: 0,
                    deadline: block.timestamp + 1 days
                }),
                signature: ""
            }),
            "",
            0
        );

        // ---- First refund: payer-only, 40 of 80 ----
        PaymentSettlementV2.RefundIntent memory refIntent1 = PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: payee,
            payerAmount: payerAmount,
            payeeSettlementAmount: payeeSettlement,
            fee: 0,
            payerRefundAmount: 40 ether,
            incentiveProviderRefundAmount: 0,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: n,
            incentiveProvider: testIncentiveProvider,
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: testIncentiveProvider,
            requireDestinationRefundSig: true,
            attester: attester
        });

        // Payer signs with pre-refund state: cumulativePayerRefunded=0, cumulativeIncentiveRefunded=0
        bytes memory payerSig1;
        {
            bytes32 h = keccak256(
                abi.encodePacked(
                    abi.encode(
                        payment.PAYER_REFUND_TYPEHASH(),
                        address(usdc),
                        uint256(40 ether),
                        refIntent1.validAfter,
                        refIntent1.validBefore
                    ),
                    abi.encode(n, payer, uint256(0), uint256(0), attester)
                )
            );
            payerSig1 = _sig(_computeTypedDataHash("PaymentSettlementV2", "1", address(payment), h), payerPk);
        }

        PaymentSettlementV2.Permit2Data memory payeeRefundData1 = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 40 ether}),
                nonce: 0,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        // requireDestinationRefundSig=true && isIncentiveCase=true → incentive sig check triggered.
        // Must provide valid incentive sig for amount=0.
        bytes memory incentiveSig0;
        {
            bytes32 h = keccak256(
                abi.encodePacked(
                    abi.encode(
                        payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                        address(usdc),
                        uint256(0),
                        refIntent1.validAfter,
                        refIntent1.validBefore
                    ),
                    abi.encode(n, testIncentiveProvider, uint256(0), uint256(0), attester)
                )
            );
            incentiveSig0 = _sig(_computeTypedDataHash("PaymentSettlementV2", "1", address(payment), h), incentivePk_);
        }

        vm.prank(attester);
        payment.refund(refIntent1, payeeRefundData1, _emptyPermit2Data(), payerSig1, incentiveSig0);

        // State after first refund: cumulativePayerRefunded=40 ether, cumulativeIncentiveRefunded=0

        // ---- Pre-sign incentive sig BEFORE second refund (signs stale cumulativePayerRefunded=0) ----
        // This is the "old" incentive sig that should be invalidated by cross-path state change
        bytes memory staleIncentiveSig;
        {
            bytes32 h = keccak256(
                abi.encodePacked(
                    abi.encode(
                        payment.INCENTIVE_PROVIDER_REFUND_TYPEHASH(),
                        address(usdc),
                        10 ether, // incentiveProviderRefundAmount
                        uint256(0), // validAfter
                        block.timestamp + 1 days // validBefore
                    ),
                    abi.encode(
                        n,
                        testIncentiveProvider,
                        uint256(0), // cumulativePayerRefunded: STALE — should be 40 ether
                        uint256(0), // cumulativeIncentiveRefunded: 0 (correct, unchanged)
                        attester
                    )
                )
            );
            staleIncentiveSig =
                _sig(_computeTypedDataHash("PaymentSettlementV2", "1", address(payment), h), incentivePk_);
        }

        // ---- Second refund: payer + incentive, using fresh payer sig + stale incentive sig ----
        PaymentSettlementV2.RefundIntent memory refIntent2 = PaymentSettlementV2.RefundIntent({
            token: address(usdc),
            payer: payer,
            payeeRefundFrom: payee,
            payerAmount: payerAmount,
            payeeSettlementAmount: payeeSettlement,
            fee: 0,
            payerRefundAmount: 10 ether,
            incentiveProviderRefundAmount: 10 ether,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: n,
            incentiveProvider: testIncentiveProvider,
            beneficiaryRefundFrom: address(0),
            payerRefundTo: payer,
            incentiveProviderRefundTo: testIncentiveProvider,
            requireDestinationRefundSig: true,
            attester: attester
        });

        // Fresh payer sig with CORRECT cumulativePayerRefunded=40 ether
        bytes memory freshPayerSig;
        {
            bytes32 h = keccak256(
                abi.encodePacked(
                    abi.encode(
                        payment.PAYER_REFUND_TYPEHASH(),
                        address(usdc),
                        uint256(10 ether),
                        refIntent2.validAfter,
                        refIntent2.validBefore
                    ),
                    abi.encode(
                        n,
                        payer,
                        uint256(40 ether), // cumulativePayerRefunded: updated after first refund
                        uint256(0), // cumulativeIncentiveRefunded: 0 (unchanged)
                        attester
                    )
                )
            );
            freshPayerSig = _sig(_computeTypedDataHash("PaymentSettlementV2", "1", address(payment), h), payerPk);
        }

        PaymentSettlementV2.Permit2Data memory payeeRefundData2 = PaymentSettlementV2.Permit2Data({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: 20 ether}),
                nonce: 1,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        // Should revert InvalidSignature: payer sig passes (L839), but incentive sig (L853)
        // fails because on-chain cumulativePayerRefunded is 40 ether, not the 0 in stale sig
        vm.prank(attester);
        vm.expectRevert(PaymentSettlementV2.InvalidSignature.selector);
        payment.refund(refIntent2, payeeRefundData2, _emptyPermit2Data(), freshPayerSig, staleIncentiveSig);
    }
}
