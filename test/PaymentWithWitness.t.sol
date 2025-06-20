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

import {PaymentWithWitness} from "./../src/PaymentWithWitness.sol";
import {IERC20} from "./../src/interfaces/IERC20.sol";
import {IPaymentWithWitness} from "./../src/interfaces/IPaymentWithWitness.sol";
import {Authorizable} from "./../src/utils/Authorizable.sol";

import {Ownable} from "./../src/utils/Ownable.sol";
import {Rescuable} from "./../src/utils/Rescuable.sol";
import {TestERC20} from "./utils/TestERC20.sol";
import {Test} from "forge-std/src/Test.sol";

contract PaymentWithWitnessTest is Test {
    PaymentWithWitness public paymentContract;
    TestERC20 public token;
    address public owner;
    uint256 public payerPk;
    address public payer;
    uint256 public payeePk;
    address public payee;
    address public witnessAuthorizer;
    uint256 public witnessPk;
    address public witness;
    address public spender;
    address public rescuer;

    event WitnessAdded(address indexed witness);
    event WitnessRemoved(address indexed witness);
    event NonceUsed(bytes32 indexed nonce);
    event NonceCancelled(address indexed witness, bytes32 nonce);
    event Payment(
        address indexed witness, address indexed from, address indexed to, bytes32 nonce, address token, uint256 value
    );
    event TokensRescued(address indexed sender, address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        owner = address(this);
        payerPk = 0x1;
        payer = vm.addr(payerPk);
        payeePk = 0x2;
        payee = vm.addr(payeePk);
        witnessAuthorizer = address(0x3);
        witnessPk = 0x4;
        witness = vm.addr(witnessPk);
        spender = address(0x5);
        rescuer = address(0x6);

        token = new TestERC20("USDC", "TEST");
        paymentContract = new PaymentWithWitness();
        token.transfer(payer, 5000 ether);
        paymentContract.updateRescuer(rescuer);
        paymentContract.updateWitnessAuthorizer(witnessAuthorizer);
        vm.prank(witnessAuthorizer);
        paymentContract.addWitness(witness);
    }

    function testCancelNonceNotWitness() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.NotWitness.selector);
        paymentContract.cancelNonce(
            IPaymentWithWitness.WitnessData({witness: address(0x0), signature: new bytes(0)}), bytes32("0")
        );
    }

    function testCancelNonce() public {
        bytes32 cancelNonce = bytes32("cancelNonce");
        bytes32 structHash =
            keccak256(abi.encode(keccak256("CancelNonce(address witness,bytes32 nonce)"), witness, cancelNonce));
        bytes32 typedDataHash = _computeTypedDataHash("PaymentWithWitness", "1", address(paymentContract), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(witnessPk, typedDataHash);

        assertFalse(paymentContract.nonceState(cancelNonce));

        vm.expectEmit(true, false, false, true);
        emit NonceCancelled(witness, cancelNonce);

        vm.prank(spender);
        paymentContract.cancelNonce(
            IPaymentWithWitness.WitnessData({witness: witness, signature: abi.encodePacked(r, s, v)}), cancelNonce
        );

        vm.expectRevert(IPaymentWithWitness.UsedNonce.selector);
        paymentContract.cancelNonce(
            IPaymentWithWitness.WitnessData({witness: witness, signature: abi.encodePacked(r, s, v)}), cancelNonce
        );

        assertTrue(paymentContract.nonceState(cancelNonce));
    }

    function testPaymentTransferFrom() public {
        bytes32 paymentNonce = bytes32("paymentNonce");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Payment(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness)"
                ),
                address(token),
                payer,
                payee,
                100 ether,
                0,
                block.timestamp + 100,
                paymentNonce,
                witness
            )
        );

        vm.warp(1); // ensure block.timestamp > validAfter=0
        // Approve the contract
        vm.prank(payer);
        token.approve(address(paymentContract), 100 ether);

        vm.expectEmit(true, true, true, true);
        emit Payment(witness, payer, payee, paymentNonce, address(token), 100 ether);
        // Now call transferFrom
        vm.prank(spender);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: 0,
                validBefore: block.timestamp + 100,
                nonce: paymentNonce
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: _composeSignature(structHash, witnessPk)})
        );
    }

    function testPayment3009() public {
        bytes32 paymentNonce = bytes32("paymentNonce2");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Payment(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness)"
                ),
                address(token),
                payer,
                payee,
                200 ether,
                0,
                block.timestamp + 1000,
                paymentNonce,
                witness
            )
        );

        bytes32 transfer3009Nonce = bytes32("transfer3009Nonce");
        bytes32 receiveWithAuthStructHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                payer,
                address(paymentContract),
                200 ether,
                0,
                block.timestamp + 1000,
                transfer3009Nonce
            )
        );
        (uint8 vi, bytes32 ri, bytes32 si) =
            vm.sign(payerPk, _computeTypedDataHash("USDC", "2", address(token), receiveWithAuthStructHash));

        vm.expectEmit(true, true, true, true);
        emit Payment(witness, payer, payee, paymentNonce, address(token), 200 ether);

        vm.warp(1); // ensure block.timestamp > validAfter=0

        vm.prank(spender);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 200 ether,
                validAfter: 0,
                validBefore: block.timestamp + 1000,
                nonce: paymentNonce
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: _composeSignature(structHash, witnessPk)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: transfer3009Nonce, signature: abi.encodePacked(ri, si, vi)})
        );
    }

    function testPayment3009NotWitness() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.NotWitness.selector);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(0),
                from: address(0),
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32("")
            }),
            IPaymentWithWitness.WitnessData({witness: address(0), signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPayment3009InvalidTokenAddress() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.InvalidTokenAddress.selector);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(0),
                from: address(0),
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32("Nonce")
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPayment3009InvalidPayer() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.InvalidPayer.selector);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: address(0),
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32("Nonce")
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPayment3009InvalidPayee() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.InvalidPayee.selector);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32("Nonce")
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPayment3009InvalidAmount() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.InvalidAmount.selector);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32("Nonce")
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPayment3009NotYetValid() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.NotYetValid.selector);
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: block.timestamp + 9999,
                validBefore: 0,
                nonce: bytes32("Nonce")
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPayment3009Expired() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.Expired.selector);
        vm.warp(1); // ensure block.timestamp > validAfter=0
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32("Nonce")
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPayment3009InvalidSignature() public {
        vm.prank(spender);
        vm.expectRevert(IPaymentWithWitness.InvalidSignature.selector);
        vm.warp(1); // ensure block.timestamp > validAfter=0
        paymentContract.payment(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: 0,
                validBefore: block.timestamp + 1000,
                nonce: bytes32("Nonce")
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: new bytes(0)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: bytes32(""), signature: new bytes(0)})
        );
    }

    function testPaymentWithPayeeTransferFrom() public {
        bytes32 paymentNonce = bytes32("paymentNonce3");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PaymentWithPayee(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness)"
                ),
                address(token),
                payer,
                payee,
                100 ether,
                0,
                block.timestamp + 100,
                paymentNonce,
                witness
            )
        );

        bytes32 payeeStructHash = keccak256(
            abi.encode(
                keccak256(
                    "PaymentWithPayee(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                ),
                address(token),
                payer,
                payee,
                100 ether,
                0,
                block.timestamp + 100,
                paymentNonce
            )
        );

        vm.warp(1); // ensure block.timestamp > validAfter=0
        // Approve the contract
        vm.prank(payer);
        token.approve(address(paymentContract), 100 ether);

        vm.expectEmit(true, true, true, true);
        emit Payment(witness, payer, payee, paymentNonce, address(token), 100 ether);
        // Now call transferFrom
        vm.prank(spender);
        paymentContract.paymentWithPayee(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: 0,
                validBefore: block.timestamp + 100,
                nonce: paymentNonce
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: _composeSignature(structHash, witnessPk)}),
            _composeSignature(payeeStructHash, payeePk)
        );
    }

    function testPaymentWithPayee3009() public {
        bytes32 paymentNonce = bytes32("paymentNonce4");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PaymentWithPayee(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness)"
                ),
                address(token),
                payer,
                payee,
                200 ether,
                0,
                block.timestamp + 1000,
                paymentNonce,
                witness
            )
        );

        bytes32 payeeStructHash = keccak256(
            abi.encode(
                keccak256(
                    "PaymentWithPayee(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                ),
                address(token),
                payer,
                payee,
                200 ether,
                0,
                block.timestamp + 1000,
                paymentNonce
            )
        );

        bytes32 transfer3009Nonce = bytes32("transfer3009Nonce");
        bytes32 receiveWithAuthStructHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                payer,
                address(paymentContract),
                200 ether,
                0,
                block.timestamp + 1000,
                transfer3009Nonce
            )
        );
        (uint8 vi, bytes32 ri, bytes32 si) =
            vm.sign(payerPk, _computeTypedDataHash("USDC", "2", address(token), receiveWithAuthStructHash));

        vm.expectEmit(true, true, true, true);
        emit Payment(witness, payer, payee, paymentNonce, address(token), 200 ether);

        vm.warp(1); // ensure block.timestamp > validAfter=0

        vm.prank(spender);
        paymentContract.paymentWithPayee(
            IPaymentWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 200 ether,
                validAfter: 0,
                validBefore: block.timestamp + 1000,
                nonce: paymentNonce
            }),
            IPaymentWithWitness.WitnessData({witness: witness, signature: _composeSignature(structHash, witnessPk)}),
            IPaymentWithWitness.ReceiveWithAuthData({nonce: transfer3009Nonce, signature: abi.encodePacked(ri, si, vi)}),
            _composeSignature(payeeStructHash, payeePk)
        );
    }

    function testRescueTokensSuccess() public {
        uint256 amount = 100 * 10 ** 18;
        address to = address(0x5);

        // Send tokens to the paymentContract contract
        token.transfer(address(paymentContract), amount);

        vm.expectEmit(true, true, true, true);
        emit TokensRescued(address(token), rescuer, to, amount);

        vm.prank(rescuer);
        paymentContract.rescueERC20(IERC20(address(token)), to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(paymentContract)), 0);
    }

    function testRescueTokensFailInvalidRescueTokenAddress() public {
        vm.expectRevert(Rescuable.InvalidRescueTokenAddress.selector);
        vm.prank(rescuer);
        paymentContract.rescueERC20(IERC20(address(0)), address(0x5), 100);
    }

    function testRescueTokensFailInvalidRescueToAddress() public {
        vm.expectRevert(Rescuable.InvalidRescueToAddress.selector);
        vm.prank(rescuer);
        paymentContract.rescueERC20(IERC20(address(token)), address(0), 100);
    }

    function testRescueTokensFailInvalidRescueAmount() public {
        vm.expectRevert(Rescuable.InvalidRescueAmount.selector);
        vm.prank(rescuer);
        paymentContract.rescueERC20(IERC20(address(token)), address(0x5), 0);
    }

    function testRescueTokensFailRescueAmountExceedsBalance() public {
        uint256 amount = 100 * 10 ** 18;
        address to = address(0x5);

        vm.prank(rescuer);
        vm.expectRevert(Rescuable.RescueAmountExceedsBalance.selector);
        paymentContract.rescueERC20(IERC20(address(token)), to, amount);
    }

    function testWitness() public {
        address newWitness = address(0x7);

        vm.prank(owner);
        assertFalse(paymentContract.isWitness(newWitness));

        vm.expectRevert(
            abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, keccak256("WITNESS_AUTHORIZER_ROLE"), owner)
        );
        paymentContract.addWitness(newWitness);

        vm.prank(witnessAuthorizer);
        vm.expectRevert(IPaymentWithWitness.InvalidWitness.selector);
        paymentContract.addWitness(address(0));

        vm.prank(witnessAuthorizer);
        vm.expectEmit(true, false, false, true);
        emit WitnessAdded(newWitness);
        paymentContract.addWitness(newWitness);

        vm.prank(owner);
        assertTrue(paymentContract.isWitness(newWitness));

        vm.expectRevert(
            abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, keccak256("WITNESS_AUTHORIZER_ROLE"), owner)
        );
        paymentContract.removeWitness(newWitness);

        vm.prank(witnessAuthorizer);
        vm.expectRevert(IPaymentWithWitness.NotWitness.selector);
        paymentContract.removeWitness(address(0));

        vm.prank(witnessAuthorizer);
        vm.expectEmit(true, false, false, true);
        emit WitnessRemoved(newWitness);
        paymentContract.removeWitness(newWitness);

        vm.prank(owner);
        assertFalse(paymentContract.isWitness(newWitness));
    }

    function testWitnessAuthorizer() public {
        assertEq(paymentContract.witnessAuthorizer(), address(witnessAuthorizer));

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove witnessAuthorizer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        paymentContract.removeWitnessAuthorizer();

        // Then remove it
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerRemoved(keccak256("WITNESS_AUTHORIZER_ROLE"));
        paymentContract.removeWitnessAuthorizer();
        assertEq(paymentContract.witnessAuthorizer(), address(0));

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove witnessAuthorizer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        paymentContract.updateWitnessAuthorizer(witnessAuthorizer);

        // First set a witnessAuthorizer
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerChanged(witnessAuthorizer, keccak256("WITNESS_AUTHORIZER_ROLE"));
        paymentContract.updateWitnessAuthorizer(witnessAuthorizer);
        assertEq(paymentContract.witnessAuthorizer(), witnessAuthorizer);
    }

    function testRescuer() public {
        assertEq(paymentContract.rescuer(), rescuer);

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove rescuer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        paymentContract.removeRescuer();

        // Then remove it
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerRemoved(keccak256("RESCUER_ROLE"));
        paymentContract.removeRescuer();
        assertEq(paymentContract.rescuer(), address(0));

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove rescuer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        paymentContract.updateRescuer(rescuer);

        // First set a rescuer
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerChanged(rescuer, keccak256("RESCUER_ROLE"));
        paymentContract.updateRescuer(rescuer);
        assertEq(paymentContract.rescuer(), rescuer);
    }

    function testDirectTransferNotAllowed() public {
        vm.expectRevert(PaymentWithWitness.DirectTransferNotAllowed.selector);
        payable(address(paymentContract)).transfer(1 ether);
    }

    function testFallbackNotAllowed() public {
        (bool success,) =
            address(paymentContract).call{value: 1 ether}(abi.encodeWithSignature("nonexistentFunction()"));
        assertFalse(success);
    }

    function _computeTypedDataHash(
        string memory name,
        string memory version,
        address contractAddress,
        bytes32 structHash
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                contractAddress
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _composeSignature(bytes32 dataHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 typedDataHash = _computeTypedDataHash("PaymentWithWitness", "1", address(paymentContract), dataHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, typedDataHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}
