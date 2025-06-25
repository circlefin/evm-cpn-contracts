/**
 * SPDX-License-Identifier: Apache-2.0
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

import {Authorizable} from "../../src/utils/Authorizable.sol";
import {TestableAuthorizable} from "./TestableAuthorizable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/src/Test.sol";

contract AuthorizableTest is Test {
    TestableAuthorizable public authorizable;

    address public owner;
    address public user1;
    address public user2;
    address public unauthorizedUser;

    bytes32 public constant ROLE_A = keccak256("ROLE_A");
    bytes32 public constant ROLE_B = keccak256("ROLE_B");

    event AuthorizerChanged(address indexed addr, bytes32 indexed role);
    event AuthorizerRemoved(bytes32 indexed role);

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        unauthorizedUser = address(0x3);

        authorizable = new TestableAuthorizable();
    }

    function testInitialState() public view {
        // Initially no authorizers should be set
        assertEq(authorizable.authorizer(ROLE_A), address(0));
        assertEq(authorizable.authorizer(ROLE_B), address(0));

        // Owner should be set correctly
        assertEq(authorizable.owner(), owner);
    }

    function testUpdateAuthorizer() public {
        // Should emit event when updating authorizer
        vm.expectEmit(true, true, false, true);
        emit AuthorizerChanged(user1, ROLE_A);

        authorizable.updateAuthorizer(ROLE_A, user1);

        // Check authorizer was set
        assertEq(authorizable.authorizer(ROLE_A), user1);
    }

    function testUpdateAuthorizerMultipleRoles() public {
        // Set different authorizers for different roles
        authorizable.updateAuthorizer(ROLE_A, user1);
        authorizable.updateAuthorizer(ROLE_B, user2);

        assertEq(authorizable.authorizer(ROLE_A), user1);
        assertEq(authorizable.authorizer(ROLE_B), user2);
    }

    function testUpdateAuthorizerOverwrite() public {
        // Set initial authorizer
        authorizable.updateAuthorizer(ROLE_A, user1);
        assertEq(authorizable.authorizer(ROLE_A), user1);

        // Overwrite with new authorizer
        vm.expectEmit(true, true, false, true);
        emit AuthorizerChanged(user2, ROLE_A);

        authorizable.updateAuthorizer(ROLE_A, user2);
        assertEq(authorizable.authorizer(ROLE_A), user2);
    }

    function testUpdateAuthorizerFailsWithZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Authorizable.InvalidAuthorizer.selector, ROLE_A));
        authorizable.updateAuthorizer(ROLE_A, address(0));
    }

    function testUpdateAuthorizerFailsWhenNotOwner() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedUser));
        authorizable.updateAuthorizer(ROLE_A, user1);
    }

    function testRemoveAuthorizer() public {
        // First set an authorizer
        authorizable.updateAuthorizer(ROLE_A, user1);
        assertEq(authorizable.authorizer(ROLE_A), user1);

        // Then remove it
        vm.expectEmit(false, true, false, true);
        emit AuthorizerRemoved(ROLE_A);

        authorizable.removeAuthorizer(ROLE_A);
        assertEq(authorizable.authorizer(ROLE_A), address(0));
    }

    function testRemoveAuthorizerWhenNotSet() public {
        // Should not revert when removing non-existent authorizer
        vm.expectEmit(false, true, false, true);
        emit AuthorizerRemoved(ROLE_A);

        authorizable.removeAuthorizer(ROLE_A);
        assertEq(authorizable.authorizer(ROLE_A), address(0));
    }

    function testRemoveAuthorizerFailsWhenNotOwner() public {
        authorizable.updateAuthorizer(ROLE_A, user1);

        vm.prank(unauthorizedUser);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedUser));
        authorizable.removeAuthorizer(ROLE_A);
    }

    function testValidAuthorizerSuccess() public {
        authorizable.updateAuthorizer(ROLE_A, user1);

        // Should not revert for valid authorizer
        authorizable.validAuthorizer(ROLE_A, user1);
    }

    function testValidAuthorizerFailsWithWrongAddress() public {
        authorizable.updateAuthorizer(ROLE_A, user1);

        vm.expectRevert(abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, ROLE_A, user2));
        authorizable.validAuthorizer(ROLE_A, user2);
    }

    function testValidAuthorizerFailsWithZeroAddress() public {
        authorizable.updateAuthorizer(ROLE_A, user1);

        vm.expectRevert(abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, ROLE_A, address(0)));
        authorizable.validAuthorizer(ROLE_A, address(0));
    }

    function testValidAuthorizerFailsWhenNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, ROLE_A, user1));
        authorizable.validAuthorizer(ROLE_A, user1);
    }

    function testFuzzUpdateAuthorizer(bytes32 role, address addr) public {
        vm.assume(addr != address(0));

        authorizable.updateAuthorizer(role, addr);
        assertEq(authorizable.authorizer(role), addr);
    }

    function testFuzzValidAuthorizer(bytes32 role, address addr) public {
        vm.assume(addr != address(0));

        authorizable.updateAuthorizer(role, addr);

        // Should succeed for correct address
        authorizable.validAuthorizer(role, addr);

        // Should fail for different address (if different)
        if (addr != user1) {
            vm.expectRevert(abi.encodeWithSelector(Authorizable.NotAuthorizer.selector, role, user1));
            authorizable.validAuthorizer(role, user1);
        }
    }
}
