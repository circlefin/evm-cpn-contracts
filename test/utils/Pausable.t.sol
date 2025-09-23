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

import {Pausable} from "../../src/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Test} from "forge-std/src/Test.sol";

/* ───────────────────────────── Harness ───────────────────────────── */
contract PausableHarness is Initializable, Pausable {
    /* helper funcs exercising modifiers */
    function onlyWhenNotPaused() external view whenNotPaused returns (uint8) {
        return 1;
    }

    function onlyWhenPaused() external view whenPaused returns (uint8) {
        return 2;
    }

    function onlyPauserFunc() external view onlyPauser returns (uint8) {
        return 3;
    }

    /* public wrapper for _setPauser (tests same-pauser branch) */
    function setPauserInternal(address p) external {
        _setPauser(p);
    }

    /* constructor wiring owner + pauser */
    constructor(address initOwner) Ownable(initOwner) {}

    function init(address initPauser) external initializer {
        _initializePauser(initPauser);
    }
}

/* ───────────────────────────── Tests ───────────────────────────── */
contract PausableTest is Test {
    PausableHarness private mock;
    address private owner = address(0xA0);
    address private pauser = address(0xB0);
    address private newP = address(0xB1);
    address private evil = address(0xEE);

    function setUp() public {
        mock = new PausableHarness(owner);
        mock.init(pauser);
    }

    /* ---------- initial state ---------- */
    function test_initialState() public view {
        assertFalse(mock.paused(), "should start un-paused");
        assertEq(mock.pauser(), pauser);
    }

    /* ---------- pause / unpause happy paths ---------- */
    function test_pauseAndUnpause() public {
        /* pause */
        vm.prank(pauser);
        vm.expectEmit(true, false, false, true);
        emit Pausable.Paused(pauser);
        mock.pause();
        assertTrue(mock.paused());

        /* call guarded by whenPaused */
        assertEq(mock.onlyWhenPaused(), 2);

        /* unpause */
        vm.prank(pauser);
        vm.expectEmit(true, false, false, true);
        emit Pausable.Unpaused(pauser);
        mock.unpause();
        assertFalse(mock.paused());

        /* call guarded by whenNotPaused */
        assertEq(mock.onlyWhenNotPaused(), 1);
    }

    /* ---------- double-pause / double-unpause reverts ---------- */
    function test_doublePauseReverts() public {
        vm.prank(pauser);
        mock.pause();

        vm.prank(pauser);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mock.pause();
    }

    function test_doubleUnpauseReverts() public {
        vm.startPrank(pauser);
        mock.pause();
        mock.unpause();

        vm.expectRevert(Pausable.ExpectedPause.selector);
        mock.unpause();
        vm.stopPrank();
    }

    /* ---------- onlyPauser guard ---------- */
    function test_onlyPauserGuard() public {
        vm.prank(evil);
        vm.expectRevert(abi.encodeWithSignature("NotPauser(address)", evil));
        mock.onlyPauserFunc();
    }

    /* ---------- updatePauser happy path (owner) ---------- */
    function test_updatePauserByOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Pausable.PauserTransferred(pauser, newP);
        mock.updatePauser(newP);
        assertEq(mock.pauser(), newP);
    }

    /* ---------- updatePauser guard paths ---------- */
    function test_updatePauser_nonOwnerReverts() public {
        vm.prank(evil);
        vm.expectRevert(); // Ownable guard
        mock.updatePauser(newP);
    }

    function test_updatePauser_zeroAddrReverts() public {
        vm.prank(owner);
        vm.expectRevert(Pausable.PauserZeroAddress.selector);
        mock.updatePauser(address(0));
    }

    function test_updatePauser_sameAddrReverts() public {
        vm.prank(owner);
        mock.updatePauser(newP); // first change → ok

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SamePauser(address)", newP));
        mock.updatePauser(newP); // same again
    }

    /* ---------- _requireNotPaused / _requirePaused exposed via modifiers ---------- */
    function test_whenNotPaused_revertWhilePaused() public {
        vm.prank(pauser);
        mock.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        mock.onlyWhenNotPaused();
    }

    function test_whenPaused_revertWhileUnpaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        mock.onlyWhenPaused();
    }

    /* ---------- internal _setPauser helper ---------- */
    function test_setPauser_sameAddrReverts() public {
        vm.prank(owner);
        mock.updatePauser(newP); // first time OK
        vm.expectRevert(abi.encodeWithSignature("SamePauser(address)", newP));
        mock.setPauserInternal(newP); // same again via internal helper
    }

    function test_removePauser_success() public {
        // initial check
        assertEq(mock.pauser(), pauser);

        // owner removes pauser
        vm.prank(owner);
        mock.removePauser();
        assertEq(mock.pauser(), address(0));

        // removed pauser can no longer call pause()
        vm.prank(pauser);
        vm.expectRevert(abi.encodeWithSignature("NotPauser(address)", pauser));
        mock.pause();
    }

    function test_removePauser_nonOwnerReverts() public {
        vm.prank(evil);
        vm.expectRevert(); // Ownable
        mock.removePauser();
    }
}
