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

import {Test} from "forge-std/Test.sol";
import {TestERC20} from "./utils/TestERC20.sol";
import {IERC20} from "./../src/interfaces/IERC20.sol";
import {IEIP3009} from "./../src/interfaces/IEIP3009.sol";
import {ITransferWithWitness} from "./../src/interfaces/ITransferWithWitness.sol";
import {TransferWithWitness} from "./../src/TransferWithWitness.sol";
import {Authorizable} from "./../src/utils/Authorizable.sol";
import {Rescuable} from "./../src/utils/Rescuable.sol";
import {Ownable} from "./../src/utils/Ownable.sol";

contract TransferWithWitnessTest is Test {
    TransferWithWitness public witnessContract;
    TestERC20 public token;
    address public owner;
    uint256 public payerPk;
    address public payer;
    address public payee;
    address public witnessAuthorizer;
    uint256 public witnessPk;
    address public witness;
    address public feePayer;
    address public rescuer;

    event WitnessAdded(address indexed witness);
    event WitnessRemoved(address indexed witness);
    event WitnessNonceUsed(bytes32 indexed witnessNonce);
    event WitnessNonceCancelled(address indexed witness, bytes32 witnessNonce);
    event WitnessTransfer(
        address indexed witness,
        address indexed from,
        address indexed to,
        bytes32 witnessNonce,
        bytes32 typehash,
        address token,
        uint256 value
    );
    event TokensRescued(address indexed sender, address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        owner = address(this);
        payerPk = 0x1;
        payer = vm.addr(payerPk);
        payee = address(0x2);
        witnessAuthorizer = address(0x3);
        witnessPk = 0x4;
        witness = vm.addr(witnessPk);
        feePayer = address(0x5);
        rescuer = address(0x6);

        token = new TestERC20("USDC", "TEST");
        witnessContract = new TransferWithWitness();
        token.transfer(payer, 5000 ether);
        witnessContract.updateRescuer(rescuer);
        witnessContract.updateWitnessAuthorizer(witnessAuthorizer);
        vm.prank(witnessAuthorizer);
        witnessContract.addWitness(witness);
    }

    function testCancelWitnessNonceNotWitness() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.NotWitness.selector);
        witnessContract.cancelWitnessNonce(
            ITransferWithWitness.WitnessData({
                witness: address(0x0),
                witnessNonce: bytes32(0),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testCancelWitnessNonce() public {
        bytes32 cancelNonce = bytes32("cancelNonce");
        bytes32 structHash = keccak256(
            abi.encode(keccak256("CancelWitnessNonce(address witness,bytes32 witnessNonce)"), witness, cancelNonce)
        );
        bytes32 typedDataHash = _computeTypedDataHash("TransferWithWitness", "1", address(witnessContract), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(witnessPk, typedDataHash);

        assertFalse(witnessContract.witnessNonceState(cancelNonce));

        vm.expectEmit(true, false, false, true);
        emit WitnessNonceCancelled(witness, cancelNonce);

        vm.prank(feePayer);
        witnessContract.cancelWitnessNonce(
            ITransferWithWitness.WitnessData({witness: witness, witnessNonce: cancelNonce, v: v, r: r, s: s})
        );

        vm.expectRevert(ITransferWithWitness.UsedNonce.selector);
        witnessContract.cancelWitnessNonce(
            ITransferWithWitness.WitnessData({witness: witness, witnessNonce: cancelNonce, v: v, r: r, s: s})
        );

        assertTrue(witnessContract.witnessNonceState(cancelNonce));
    }

    function testTransferFrom() public {
        bytes32 transferNonce = bytes32("transferNonce");
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "WitnessTransferFrom(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,address witness,bytes32 witnessNonce)"
                ),
                address(token),
                payer,
                payee,
                100 ether,
                0, // validAfter
                block.timestamp + 100, // validBefore
                witness,
                transferNonce
            )
        );
        bytes32 typedDataHash = _computeTypedDataHash("TransferWithWitness", "1", address(witnessContract), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(witnessPk, typedDataHash);

        vm.warp(1); // ensure block.timestamp > validAfter=0
        // Approve the contract
        vm.prank(payer);
        token.approve(address(witnessContract), 100 ether);

        vm.expectEmit(true, true, true, true);
        emit WitnessTransfer(
            witness,
            payer,
            payee,
            transferNonce,
            keccak256(
                "WitnessTransferFrom(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,address witness,bytes32 witnessNonce)"
            ),
            address(token),
            100 ether
        );

        // Now call transferFrom
        vm.prank(feePayer);
        witnessContract.transferFrom(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: 0,
                validBefore: block.timestamp + 100,
                nonce: bytes32(0),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({witness: witness, witnessNonce: transferNonce, v: v, r: r, s: s})
        );
    }

    function testTransferWithAuthorization() public {
        // sign typed data for the "witness"
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "WitnessTransferWithAuthorization(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness,bytes32 witnessNonce)"
                ),
                address(token),
                payer,
                payee,
                200 ether,
                0,
                block.timestamp + 1000,
                bytes32("authNonce"),
                witness,
                bytes32("transferWithAuthNonce")
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(witnessPk, _computeTypedDataHash("TransferWithWitness", "1", address(witnessContract), structHash));

        bytes32 intentStructHash = keccak256(
            abi.encode(
                token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                payer,
                address(witnessContract),
                200 ether,
                0,
                block.timestamp + 1000,
                bytes32("authNonce")
            )
        );
        (uint8 vi, bytes32 ri, bytes32 si) =
            vm.sign(payerPk, _computeTypedDataHash("USDC", "2", address(token), intentStructHash));

        vm.expectEmit(true, true, true, true);
        emit WitnessTransfer(
            witness,
            payer,
            payee,
            bytes32("transferWithAuthNonce"),
            keccak256(
                "WitnessTransferWithAuthorization(address token,address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address witness,bytes32 witnessNonce)"
            ),
            address(token),
            200 ether
        );

        vm.warp(1); // ensure block.timestamp > validAfter=0

        vm.prank(feePayer);
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 200 ether,
                validAfter: 0,
                validBefore: block.timestamp + 1000,
                nonce: bytes32("authNonce"),
                v: vi,
                r: ri,
                s: si
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("transferWithAuthNonce"),
                v: v,
                r: r,
                s: s
            })
        );
    }

    function testTransferWithAuthorizationNotWitness() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.NotWitness.selector);
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(0),
                from: address(0),
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: address(0),
                witnessNonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testTransferWithAuthorizationInvalidTokenAddress() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.InvalidTokenAddress.selector);
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(0),
                from: address(0),
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("Nonce"),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testTransferWithAuthorizationInvalidPayer() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.InvalidPayer.selector);
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: address(0),
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("Nonce"),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testTransferWithAuthorizationInvalidPayee() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.InvalidPayee.selector);
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: address(0),
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("Nonce"),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testTransferWithAuthorizationInvalidAmount() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.InvalidAmount.selector);
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 0,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("Nonce"),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testTransferWithAuthorizationNotYetValid() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.NotYetValid.selector);
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: block.timestamp + 9999,
                validBefore: 0,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("Nonce"),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testTransferWithAuthorizationExpired() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.Expired.selector);
        vm.warp(1); // ensure block.timestamp > validAfter=0
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: 0,
                validBefore: 0,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("Nonce"),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testTransferWithAuthorizationInvalidWitnessSignature() public {
        vm.prank(feePayer);
        vm.expectRevert(ITransferWithWitness.InvalidWitnessSignature.selector);
        vm.warp(1); // ensure block.timestamp > validAfter=0
        witnessContract.transferWithAuthorization(
            ITransferWithWitness.TransferIntent({
                token: address(token),
                from: payer,
                to: payee,
                value: 100 ether,
                validAfter: 0,
                validBefore: block.timestamp + 1000,
                nonce: bytes32(""),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            }),
            ITransferWithWitness.WitnessData({
                witness: witness,
                witnessNonce: bytes32("Nonce"),
                v: 0,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function testRescueTokensSuccess() public {
        uint256 amount = 100 * 10 ** 18;
        address to = address(0x5);

        // Send tokens to the witnessContract contract
        token.transfer(address(witnessContract), amount);

        vm.expectEmit(true, true, true, true);
        emit TokensRescued(address(token), rescuer, to, amount);

        vm.prank(rescuer);
        witnessContract.rescueERC20(IERC20(address(token)), to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(witnessContract)), 0);
    }

    function testRescueTokensFailInvalidRescueTokenAddress() public {
        vm.expectRevert(Rescuable.InvalidRescueTokenAddress.selector);
        vm.prank(rescuer);
        witnessContract.rescueERC20(IERC20(address(0)), address(0x5), 100);
    }

    function testRescueTokensFailInvalidRescueToAddress() public {
        vm.expectRevert(Rescuable.InvalidRescueToAddress.selector);
        vm.prank(rescuer);
        witnessContract.rescueERC20(IERC20(address(token)), address(0), 100);
    }

    function testRescueTokensFailInvalidRescueAmount() public {
        vm.expectRevert(Rescuable.InvalidRescueAmount.selector);
        vm.prank(rescuer);
        witnessContract.rescueERC20(IERC20(address(token)), address(0x5), 0);
    }

    function testRescueTokensFailRescueAmountExceedsBalance() public {
        uint256 amount = 100 * 10 ** 18;
        address to = address(0x5);

        vm.prank(rescuer);
        vm.expectRevert(Rescuable.RescueAmountExceedsBalance.selector);
        witnessContract.rescueERC20(IERC20(address(token)), to, amount);
    }

    function testWitness() public {
        address newWitness = address(0x7);

        vm.prank(owner);
        assertFalse(witnessContract.isWitness(newWitness));

        vm.expectRevert(
            abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, keccak256("WITNESS_AUTHORIZER_ROLE"), owner)
        );
        witnessContract.addWitness(newWitness);

        vm.prank(witnessAuthorizer);
        vm.expectRevert(ITransferWithWitness.InvalidWitness.selector);
        witnessContract.addWitness(address(0));

        vm.prank(witnessAuthorizer);
        vm.expectEmit(true, false, false, true);
        emit WitnessAdded(newWitness);
        witnessContract.addWitness(newWitness);

        vm.prank(owner);
        assertTrue(witnessContract.isWitness(newWitness));

        vm.expectRevert(
            abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, keccak256("WITNESS_AUTHORIZER_ROLE"), owner)
        );
        witnessContract.removeWitness(newWitness);

        vm.prank(witnessAuthorizer);
        vm.expectRevert(ITransferWithWitness.NotWitness.selector);
        witnessContract.removeWitness(address(0));

        vm.prank(witnessAuthorizer);
        vm.expectEmit(true, false, false, true);
        emit WitnessRemoved(newWitness);
        witnessContract.removeWitness(newWitness);

        vm.prank(owner);
        assertFalse(witnessContract.isWitness(newWitness));
    }

    function testWitnessAuthorizer() public {
        assertEq(witnessContract.witnessAuthorizer(), address(witnessAuthorizer));

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove witnessAuthorizer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        witnessContract.removeWitnessAuthorizer();

        // Then remove it
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerRemoved(keccak256("WITNESS_AUTHORIZER_ROLE"));
        witnessContract.removeWitnessAuthorizer();
        assertEq(witnessContract.witnessAuthorizer(), address(0));

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove witnessAuthorizer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        witnessContract.updateWitnessAuthorizer(witnessAuthorizer);

        // First set a witnessAuthorizer
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerChanged(witnessAuthorizer, keccak256("WITNESS_AUTHORIZER_ROLE"));
        witnessContract.updateWitnessAuthorizer(witnessAuthorizer);
        assertEq(witnessContract.witnessAuthorizer(), witnessAuthorizer);
    }

    function testRescuer() public {
        assertEq(witnessContract.rescuer(), rescuer);

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove rescuer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        witnessContract.removeRescuer();

        // Then remove it
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerRemoved(keccak256("RESCUER_ROLE"));
        witnessContract.removeRescuer();
        assertEq(witnessContract.rescuer(), address(0));

        // Switch to non-owner account
        vm.prank(payee);
        // Attempt to remove rescuer should revert
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, payee));
        witnessContract.updateRescuer(rescuer);

        // First set a rescuer
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Authorizable.AuthorizerChanged(rescuer, keccak256("RESCUER_ROLE"));
        witnessContract.updateRescuer(rescuer);
        assertEq(witnessContract.rescuer(), rescuer);
    }

    function testDirectTransferNotAllowed() public {
        vm.expectRevert(TransferWithWitness.DirectTransferNotAllowed.selector);
        payable(address(witnessContract)).transfer(1 ether);
    }

    function testFallbackNotAllowed() public {
        (bool success,) =
            address(witnessContract).call{value: 1 ether}(abi.encodeWithSignature("nonexistentFunction()"));
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

    receive() external payable {}
}
