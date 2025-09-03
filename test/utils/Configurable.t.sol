// SPDX-License-Identifier: Apache-2.0
/*
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
// solhint-disable-next-line one-contract-per-file
pragma solidity 0.8.24;

import {Configurable} from "../../src/utils/Configurable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/src/Test.sol";

/* -------------------------------------------------------------------------- */
/*                         ── Harness (concrete impl) ──                      */
/* -------------------------------------------------------------------------- */
contract ConfigurableMock is Initializable, Configurable {
    constructor(address initialOwner) Ownable(initialOwner) {}

    function init(address initialConfigurator) external initializer {
        _initializeConfigurator(initialConfigurator);
    }

    function configOnlyFn() external view onlyConfigurator returns (bool) {
        return true;
    }
}

/* -------------------------------------------------------------------------- */
/*                                ── Tests ──                                 */
/* -------------------------------------------------------------------------- */
contract ConfigurableTest is Test {
    ConfigurableMock private mock;

    address private owner = address(0xA0);
    address private configurator = address(0xC0);
    address private newConfig = address(0xC1);
    address private attacker = address(0xE0);

    /* ---------------- set-up ---------------- */
    function setUp() public {
        mock = new ConfigurableMock(owner);
        mock.init(configurator);
    }

    /* ---------------- onlyConfigurator path (success) ---------------- */
    function test_onlyConfigurator_passes() public {
        vm.prank(configurator);
        bool ok = mock.configOnlyFn();
        assertTrue(ok);
    }

    /* ---------------- onlyConfigurator path (revert) ---------------- */
    function test_onlyConfigurator_revertsForNonConfigurator() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("NotConfigurator(address)", attacker));
        mock.configOnlyFn();
    }

    /* ---------------- updateConfigurator: owner flow ---------------- */
    function test_updateConfigurator_byOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Configurable.ConfiguratorTransferred(configurator, newConfig);
        mock.updateConfigurator(newConfig);
        assertEq(mock.configurator(), newConfig);
    }

    /* ---------------- updateConfigurator: onlyOwner guard ---------------- */
    function test_updateConfigurator_revertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        mock.updateConfigurator(newConfig);
    }

    /* ---------------- updateConfigurator: zero-address branch ---------------- */
    function test_updateConfigurator_revertsZeroAddr() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("ConfiguratorZeroAddress()"));
        mock.updateConfigurator(address(0));
    }

    /* ---------------- updateConfigurator: same-address branch ---------------- */
    function test_updateConfigurator_revertsSameAddr() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SameConfigurator(address)", configurator));
        mock.updateConfigurator(configurator);
    }

    function test_removeConfigurator_byOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Configurable.ConfiguratorTransferred(configurator, address(0));
        mock.removeConfigurator();

        // role cleared
        assertEq(mock.configurator(), address(0));

        // former configurator no longer passes guard
        vm.prank(configurator);
        vm.expectRevert(abi.encodeWithSignature("NotConfigurator(address)", configurator));
        mock.configOnlyFn();
    }

    /* ---------------- removeConfigurator: onlyOwner guard ---------------- */
    function test_removeConfigurator_revertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        mock.removeConfigurator();
    }
}
