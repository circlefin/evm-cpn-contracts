/**
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright (c) 2025, Circle Internet Financial, LLC.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
// solhint-disable-next-line one-contract-per-file
pragma solidity 0.8.24;

import {Create2Factory} from "../../src/factory/Create2Factory.sol";
import {Test} from "forge-std/src/Test.sol";

contract MockTarget {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function setOwner(address newOwner) external {
        owner = newOwner;
    }
}

contract Create2FactoryTest is Test {
    Create2Factory internal factory;
    bytes32 internal sender;

    function setUp() public {
        factory = new Create2Factory(address(this));
        sender = keccak256("test-psp"); // fixed sender for test namespace
    }

    function testDeployMinimalContract_ReturnsExpectedValue() public {
        bytes32 salt = keccak256("minimal");
        bytes memory runtime = hex"602a60005260206000f3";
        bytes memory creation = hex"600a600c600039600a6000f3";
        bytes memory bytecode = abi.encodePacked(creation, runtime);

        address predicted = factory.getAddress(salt, bytecode);
        address deployed = factory.deploy(salt, bytecode);

        assertEq(deployed, predicted, "Deployed address mismatch");

        (bool ok, bytes memory data) = deployed.staticcall("");
        assertTrue(ok, "staticcall failed");
        assertEq(abi.decode(data, (uint256)), 42, "Expected return value 42");
    }

    function testDeployMockTargetConstructorArg() public {
        bytes32 salt = keccak256("mocktarget");
        address expectedOwner = address(this);

        bytes memory bytecode = abi.encodePacked(type(MockTarget).creationCode, abi.encode(expectedOwner));

        address predicted = factory.getAddress(salt, bytecode);
        address deployed = factory.deploy(salt, bytecode);

        assertEq(deployed, predicted, "Deployed address mismatch");
        assertEq(MockTarget(deployed).owner(), expectedOwner, "Owner not set correctly");
    }

    function testRevertsIfDeploymentFails() public {
        bytes32 salt = keccak256("empty");
        bytes memory badBytecode = "";

        vm.expectRevert(Create2Factory.EmptyBytecode.selector);
        factory.deploy(salt, badBytecode);
    }

    function testRevertsOnDuplicateSalt() public {
        bytes32 salt = keccak256("duplicate");
        address expectedOwner = address(this);

        bytes memory bytecode = abi.encodePacked(type(MockTarget).creationCode, abi.encode(expectedOwner));

        address deployed1 = factory.deploy(salt, bytecode);
        assertEq(MockTarget(deployed1).owner(), expectedOwner);

        vm.expectRevert();
        factory.deploy(salt, bytecode);
    }

    function testDeployAndMultiCall() public {
        bytes32 salt = keccak256("multi-call");
        address expectedOwner = address(this);

        // Step 1: deploy MockTarget with default constructor
        bytes memory bytecode = abi.encodePacked(type(MockTarget).creationCode, abi.encode(address(0)));

        // Step 2: encode call to setOwner(expectedOwner)
        bytes memory call = abi.encodeWithSelector(MockTarget.setOwner.selector, expectedOwner);
        bytes[] memory calls = new bytes[](1);
        calls[0] = call;

        // Step 3: deploy and initialize
        address deployed = factory.deployAndMultiCall(salt, bytecode, calls);

        // Step 4: verify
        assertEq(MockTarget(deployed).owner(), expectedOwner, "Owner not set correctly via multicall");
    }
}
