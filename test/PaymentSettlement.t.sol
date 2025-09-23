/**
 * Copyright 2025 Circle Internet Group, Inc.  All rights reserved.
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

import {PaymentSettlement} from "../src/PaymentSettlement.sol";
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

/* ─────────────────────────────────────────────────────────────────────────────
                               PaymentSettlement test-suite
   ────────────────────────────────────────────────────────────────────────────*/
contract PaymentSettlementTest is Test {
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
    PaymentSettlement internal payment;
    TestERC20 internal usdc;

    /* --------------------------------------------------------------------- */
    function setUp() public {
        permit2 = new DummyPermit2();
        address[] memory attesters = new address[](1);
        attesters[0] = attester;

        payment = new PaymentSettlement();
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

    /* --------------------------------------------------------------------- */
    /*                         Happy-path test cases                          */
    /* --------------------------------------------------------------------- */
    function testPayment_basic() public {
        uint256 value = 100 ether;
        uint256 fee = 10 ether;
        bytes32 n = "basic";

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            nonce: n,
            beneficiary: feeSink,
            maxFee: fee,
            requirePayeeSign: false,
            attester: attester
        });

        PaymentSettlement.PayerData memory pd =
            PaymentSettlement.PayerData({permit: _permit(value + fee), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, "", fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(address(payment)), 0);
    }

    /* --------------------------------------------------------------------- */
    /*                       Negative / revert scenarios                      */
    /* --------------------------------------------------------------------- */

    function testPayment_revertNotYetValid() public {
        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1 ether,
            validAfter: block.timestamp + 1000,
            validBefore: block.timestamp + 2000,
            nonce: "future",
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: false,
            attester: attester
        });

        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.NotYetValid.selector);
        payment.execute(intent, pd, "", 0);
    }

    function testPayment_revertExpired() public {
        vm.warp(2); // ensure block.timestamp > 1
        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1 ether,
            validAfter: 0,
            validBefore: 1,
            nonce: "exp",
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: false,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.ExpiredIntent.selector);
        payment.execute(intent, pd, "", 0);
    }

    function testNonceReuseReverts() public {
        bytes32 n = "dup";

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            nonce: n,
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: false,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, "", 0);

        vm.prank(attester);
        vm.expectRevert(); // any revert – nonce must be marked used
        payment.execute(intent, pd, "", 0);
    }

    /* --------------------------------------------------------------------- */
    /*                     Pause / attester / rescuer flows                   */
    /* --------------------------------------------------------------------- */
    function testPauseBlocksPayment() public {
        vm.prank(pauser);
        payment.pause();

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1,
            validAfter: 0,
            validBefore: block.timestamp + 10,
            nonce: "pause",
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: false,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1), signature: ""});

        vm.prank(attester);
        vm.expectRevert(); // EnforcedPause
        payment.execute(intent, pd, "", 0);
    }

    function testAddRemoveAttester() public {
        address newAttester = address(0xABCD);

        vm.startPrank(config);
        payment.addAttester(newAttester);
        vm.stopPrank();

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1,
            validAfter: 0,
            validBefore: block.timestamp + 10,
            nonce: "att",
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: false,
            attester: newAttester // match new msg.sender
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1), signature: ""});

        vm.prank(newAttester);
        payment.execute(intent, pd, "", 0); // succeeds

        vm.startPrank(config);
        payment.removeAttester(newAttester);
        vm.stopPrank();

        intent.nonce = "att2";

        vm.prank(newAttester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlement.InvalidAttester.selector, newAttester));
        payment.execute(intent, pd, "", 0);
    }

    function testRescueERC20() public {
        usdc.mint(address(payment), 5 ether);
        vm.prank(rescuer);
        payment.rescueERC20(usdc, feeSink, 5 ether);
        assertEq(usdc.balanceOf(feeSink), 5 ether);
    }

    function testPaymentWithPayeeSignature() public {
        // Set domain params (must match PaymentSettlement values)
        string memory name = "PaymentSettlement";
        string memory version = "1";
        address verifyingContract = address(payment);
        uint256 value = 100 ether;
        uint256 fee = 5 ether;
        bytes32 n = "payeeSig";

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: n,
            beneficiary: feeSink,
            maxFee: fee,
            requirePayeeSign: true,
            attester: attester
        });

        bytes32 typeHash = payment.PAYEE_PAYMENT_INTENT_TYPEHASH();
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                address(usdc), // token
                payer,
                payee,
                value,
                intent.validAfter,
                intent.validBefore,
                n,
                attester
            )
        );
        bytes32 digest = _computeTypedDataHash(name, version, verifyingContract, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        PaymentSettlement.PayerData memory pd =
            PaymentSettlement.PayerData({permit: _permit(value + fee), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, sig, fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
    }

    function testPayeeSigInvalidSignature() public {
        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1 ether,
            validAfter: 0,
            validBefore: block.timestamp + 10,
            nonce: "badSig",
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: true,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1 ether), signature: ""});

        // Fake signature
        bytes memory sig = hex"deadbeef";

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.InvalidSignature.selector);
        payment.execute(intent, pd, sig, 0);
    }

    function testVerifySig_InvalidLengthSignature() public {
        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1 ether,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            nonce: "badLen",
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: true,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1 ether), signature: ""});

        // Signature with invalid length (≠ 65 bytes)
        bytes memory badSig = hex"123456";

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.InvalidSignature.selector);
        payment.execute(intent, pd, badSig, 0);
    }

    function testInitialize_revertsIfZeroOwner() public {
        permit2 = new DummyPermit2();
        payment = new PaymentSettlement(); // constructor is empty ⇒ no revert

        // expect revert **on initialize()** when owner_ == address(0)
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlement.InvalidOwner.selector, address(0)));
        payment.initialize(IMinimalPermit2(address(permit2)), address(0), rescuer, pauser, config, new address[](0));
    }

    function testInitialize_attesterArrayTriggersLoop() public {
        address[] memory initialAttesters = new address[](1);
        initialAttesters[0] = attester;

        payment = new PaymentSettlement();
        payment.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, config, initialAttesters);

        // Confirm attester added
        vm.prank(attester);
        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1 ether,
            validAfter: 0,
            validBefore: block.timestamp + 10,
            nonce: "initAdd",
            beneficiary: address(0),
            maxFee: 0,
            requirePayeeSign: false,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1 ether), signature: ""});
        payment.execute(intent, pd, "", 0);
    }

    function testRenounceOwnershipReverts() public {
        vm.prank(address(this)); // set to actual owner
        vm.expectRevert(PaymentSettlement.RenounceOwnershipDisabled.selector);
        payment.renounceOwnership();
    }

    function testPayeeSig_revertsIfMissingAndSenderNotPayee() public {
        uint256 value = 100 ether;
        uint256 fee = 2 ether;
        bytes32 n = "missingSigFail";

        address notPayee = address(0xBEEF);
        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: notPayee,
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: n,
            beneficiary: feeSink,
            maxFee: fee,
            requirePayeeSign: true,
            attester: attester
        });

        PaymentSettlement.PayerData memory pd =
            PaymentSettlement.PayerData({permit: _permit(value + fee), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.InvalidSignature.selector);
        payment.execute(intent, pd, "", fee);
    }

    function testPayeeSig_contractWallet1271() public {
        // Deploy minimal 1271 wallet
        address contractWallet = address(new Mock1271Wallet());
        vm.label(contractWallet, "Mock1271");

        // Prepare payment intent
        uint256 value = 123 ether;
        uint256 fee = 7 ether;
        bytes32 nonce = "1271sig";

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: contractWallet,
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: nonce,
            beneficiary: feeSink,
            maxFee: fee,
            requirePayeeSign: true,
            attester: attester
        });

        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(0)); // will be ignored

        PaymentSettlement.PayerData memory pd =
            PaymentSettlement.PayerData({permit: _permit(value + fee), signature: ""});

        // Register attester
        vm.prank(config);
        payment.addAttester(attester);

        vm.prank(attester);
        payment.execute(intent, pd, sig, fee);

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

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 100,
            nonce: nonce,
            beneficiary: feeSink,
            maxFee: fee,
            requirePayeeSign: false,
            attester: attester
        });

        // Deliberately wrong permit amount
        PaymentSettlement.PayerData memory pd =
            PaymentSettlement.PayerData({permit: _permit(value + fee + 1), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.InvalidAmount.selector);
        payment.execute(intent, pd, "", fee); // fee ≤ maxFee, but permit amount mismatched
    }

    function testHelpers_domain_and_nonce() public {
        // domainSeparator is pure-view – just ensure non-zero
        bytes32 ds = payment._domainSeparator();
        assertTrue(ds != bytes32(0));

        // nonce should be unused, then used after a dummy payment
        bytes32 n = "nonceView";
        assertFalse(payment.isNonceUsed(n));

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1 ether,
            validAfter: 0,
            validBefore: block.timestamp + 10,
            nonce: n,
            beneficiary: feeSink,
            maxFee: 0,
            requirePayeeSign: false,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(1 ether), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, "", 0);

        assertTrue(payment.isNonceUsed(n));
    }

    function testPayment_revertFeeNoBeneficiary() public {
        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: 1 ether,
            validAfter: 0,
            validBefore: block.timestamp + 10,
            nonce: "feeNoSink",
            beneficiary: address(0), // ← invalid
            maxFee: 1 ether,
            requirePayeeSign: false,
            attester: attester
        });
        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(2 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.InvalidBeneficiary.selector);
        payment.execute(intent, pd, "", 1 ether);
    }

    function testInitialize_zeroAttesters() public {
        PaymentSettlement fresh = new PaymentSettlement();
        address[] memory none = new address[](0);
        fresh.initialize(IMinimalPermit2(address(permit2)), address(this), rescuer, pauser, config, none);
        assertFalse(fresh.isAttester(attester));
    }

    function testInitialize_revertInvalidPermit2() public {
        payment = new PaymentSettlement();
        vm.expectRevert(PaymentSettlement.InvalidPermit2.selector);
        payment.initialize(IMinimalPermit2(address(0)), address(this), rescuer, pauser, config, new address[](0));
    }

    function testCancel_revertPermitAmountMismatch() public {
        uint256 fee = 5 ether;
        bytes32 n = "cancelMismatch";

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: address(0),
            value: 0,
            validAfter: 0,
            validBefore: 0,
            nonce: n,
            beneficiary: feeSink,
            maxFee: fee,
            requirePayeeSign: false,
            attester: attester
        });

        PaymentSettlement.PayerData memory cd =
            PaymentSettlement.PayerData({permit: _permit(fee + 1 ether), signature: ""});

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.InvalidAmount.selector);
        payment.cancel(intent, cd, fee); // fee ≤ maxFee, but permit amount mismatched
    }

    function testCancel_feeAndBeneficiaryMatrix() public {
        // Case 1: fee = 0, beneficiary = zero address → allowed
        {
            PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
                from: payer,
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: "cancel-f0-b0",
                beneficiary: address(0),
                maxFee: 0,
                requirePayeeSign: false,
                attester: attester
            });

            PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(0), signature: ""});

            vm.prank(attester);
            payment.cancel(intent, pd, 0);
        }

        // Case 2: fee = 0, beneficiary = non-zero address → allowed
        {
            PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
                from: payer,
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: "cancel-f0-b1",
                beneficiary: feeSink,
                maxFee: 0,
                requirePayeeSign: false,
                attester: attester
            });

            PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(0), signature: ""});

            vm.prank(attester);
            payment.cancel(intent, pd, 0);
        }

        // Case 3: fee > 0, beneficiary = zero address → should revert
        {
            PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
                from: payer,
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: "cancel-f1-b0",
                beneficiary: address(0),
                maxFee: 5 ether,
                requirePayeeSign: false,
                attester: attester
            });

            PaymentSettlement.PayerData memory pd =
                PaymentSettlement.PayerData({permit: _permit(5 ether), signature: ""});

            vm.prank(attester);
            vm.expectRevert(PaymentSettlement.InvalidBeneficiary.selector);
            payment.cancel(intent, pd, 5 ether); // fee > 0 triggers InvalidBeneficiary
        }

        // Case 4: fee > 0, beneficiary = valid address → allowed
        {
            uint256 fee = 5 ether;
            uint256 before = usdc.balanceOf(feeSink);

            PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
                from: payer,
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: "cancel-f1-b1",
                beneficiary: feeSink,
                maxFee: fee,
                requirePayeeSign: false,
                attester: attester
            });

            PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(fee), signature: ""});

            vm.prank(attester);
            payment.cancel(intent, pd, fee);

            assertEq(usdc.balanceOf(feeSink), before + fee);
        }
    }

    function testExecute_revertFeeExceedsMax() public {
        uint256 value = 50 ether;
        uint256 maxFee = 5 ether;
        uint256 fee = 6 ether;

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: "feeTooHigh",
            beneficiary: feeSink,
            maxFee: maxFee,
            requirePayeeSign: false,
            attester: attester
        });

        PaymentSettlement.PayerData memory pd =
            PaymentSettlement.PayerData({permit: _permit(value + maxFee), signature: ""});

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlement.FeeExceedsMax.selector, fee, maxFee));
        payment.execute(intent, pd, "", fee);
    }

    function testExecute_feeBelowMaxSucceeds() public {
        uint256 value = 40 ether;
        uint256 maxFee = 8 ether;
        uint256 fee = 3 ether;

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: payee,
            value: value,
            validAfter: 0,
            validBefore: block.timestamp + 1 days,
            nonce: "feeOK",
            beneficiary: feeSink,
            maxFee: maxFee,
            requirePayeeSign: false,
            attester: attester
        });

        PaymentSettlement.PayerData memory pd =
            PaymentSettlement.PayerData({permit: _permit(value + maxFee), signature: ""});

        vm.prank(attester);
        payment.execute(intent, pd, "", fee);

        assertEq(usdc.balanceOf(payee), value);
        assertEq(usdc.balanceOf(feeSink), fee);
    }

    function testCancel_revertFeeExceedsMax() public {
        uint256 maxFee = 4 ether;
        uint256 fee = 5 ether;

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: address(0),
            value: 0,
            validAfter: 0,
            validBefore: 0,
            nonce: "cancelHighFee",
            beneficiary: feeSink,
            maxFee: maxFee,
            requirePayeeSign: false,
            attester: attester
        });

        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({permit: _permit(maxFee), signature: ""});

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(PaymentSettlement.FeeExceedsMax.selector, fee, maxFee));
        payment.cancel(intent, pd, fee);
    }

    function testCancel_revertPermitAmountNotEqualToMaxFee() public {
        uint256 maxFee = 5 ether;
        uint256 fee = 5 ether;
        uint256 wrongPermitAmount = 4 ether; // Not equal to maxFee
        bytes32 nonce = "cancelBadPermitAmount";

        PaymentSettlement.PaymentIntent memory intent = PaymentSettlement.PaymentIntent({
            from: payer,
            to: address(0),
            value: 0,
            validAfter: 0,
            validBefore: 0,
            nonce: nonce,
            beneficiary: feeSink,
            maxFee: maxFee,
            requirePayeeSign: false,
            attester: attester
        });

        PaymentSettlement.PayerData memory pd = PaymentSettlement.PayerData({
            permit: _permit(wrongPermitAmount), // should equal maxFee
            signature: ""
        });

        vm.prank(attester);
        vm.expectRevert(PaymentSettlement.InvalidAmount.selector);
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
        // fresh instance to exercise initialize()
        PaymentSettlement fresh = new PaymentSettlement();

        // prepare duplicates: [attester, attester, attester]
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

        // sanity: attester is active
        assertTrue(fresh.isAttester(attester));
    }

    function testAttesterAddRemove_spuriousEventsGuarded() public {
        address x = address(0xA11CE);
        bytes32 added = keccak256("AttesterAdded(address)");
        bytes32 removed = keccak256("AttesterRemoved(address)");

        vm.startPrank(config);
        vm.recordLogs();
        payment.addAttester(x); // should emit once
        payment.addAttester(x); // no-op, no emit
        payment.removeAttester(x); // should emit once
        payment.removeAttester(x); // no-op, no emit
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        uint256 addCount = _countEvent(logs, added, x);
        uint256 removeCount = _countEvent(logs, removed, x);

        assertEq(addCount, 1, "addAttester must emit at most once per address");
        assertEq(removeCount, 1, "removeAttester must emit at most once per address");

        assertFalse(payment.isAttester(x));
    }
}
