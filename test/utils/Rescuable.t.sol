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

import {Rescuable} from "../../src/utils/Rescuable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/src/Test.sol";

/* ───────────────────────────── Mock ERC‑20 ───────────────────────────── */
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/* ──────────────────────── Receiver that reverts on ETH ───────────────── */
contract RevertingReceiver {
    receive() external payable {
        revert("nope");
    }
}

/* ─────────────────────────────  Harness  ─────────────────────────────── */
contract RescuableHarness is Rescuable {
    using SafeERC20 for IERC20;

    constructor(address owner_, address rescuer_) Ownable(owner_) {
        _initializeRescuer(rescuer_);
    }

    /* simple function gated by onlyRescuer */
    function onlyRescuerFn() external view onlyRescuer returns (uint8) {
        return 42;
    }

    /* receive ether to test native rescue */
    receive() external payable {}
}

/* ─────────────────────────────  Tests  ─────────────────────────────── */
contract RescuableTest is Test {
    RescuableHarness private h;
    MockERC20 private tkn;

    address private owner = address(0xAA);
    address private rescuer = address(0xBB);
    address private other = address(0xCC);
    address private to = address(0xDD);

    function setUp() public {
        h = new RescuableHarness(owner, rescuer);
        tkn = new MockERC20();
    }

    /* ---------- initial ---------- */
    function test_initialState() public view {
        assertEq(h.rescuer(), rescuer);
    }

    /* ---------- onlyRescuer guard ---------- */
    function test_onlyRescuer_pass() public {
        vm.prank(rescuer);
        assertEq(h.onlyRescuerFn(), 42);
    }

    function test_onlyRescuer_revert() public {
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSignature("NotRescuer(address)", other));
        h.onlyRescuerFn();
    }

    /* ---------- rescue ERC20 happy ---------- */
    function test_rescueERC20_success() public {
        tkn.mint(address(h), 100 ether);
        vm.prank(rescuer);
        vm.expectEmit(true, true, true, true);
        emit Rescuable.TokensRescued(address(tkn), rescuer, to, 60 ether);
        h.rescueERC20(tkn, to, 60 ether);
        assertEq(tkn.balanceOf(to), 60 ether);
    }

    /* ---------- rescue ERC20 negative paths ---------- */
    function test_rescueERC20_invalidInputs() public {
        // token zero
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.InvalidRescueTokenAddress.selector);
        h.rescueERC20(IERC20(address(0)), to, 1);

        // to zero
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.InvalidRescueToAddress.selector);
        h.rescueERC20(tkn, address(0), 1);

        // amount zero
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.InvalidRescueAmount.selector);
        h.rescueERC20(tkn, to, 0);

        // exceeds balance
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.RescueAmountExceedsBalance.selector);
        h.rescueERC20(tkn, to, 1);
    }

    /* ---------- rescue native happy ---------- */
    function test_rescueNative_success() public {
        vm.deal(address(h), 5 ether);
        vm.prank(rescuer);
        vm.expectEmit(true, true, true, true);
        emit Rescuable.TokensRescued(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, rescuer, to, 2 ether);
        h.rescueNativeToken(to, 2 ether);
        assertEq(to.balance, 2 ether);
    }

    /* ---------- rescue native negative ---------- */
    function test_rescueNative_invalidInputs() public {
        // to zero
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.InvalidRescueToAddress.selector);
        h.rescueNativeToken(address(0), 1);

        // amount zero
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.InvalidRescueAmount.selector);
        h.rescueNativeToken(to, 0);

        // exceeds balance
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.RescueAmountExceedsBalance.selector);
        h.rescueNativeToken(to, 1);
    }

    function test_rescueNative_transferFail() public {
        RevertingReceiver bad = new RevertingReceiver();
        vm.deal(address(h), 1 ether);
        vm.prank(rescuer);
        vm.expectRevert(Rescuable.NativeTransferFailed.selector);
        h.rescueNativeToken(address(bad), 1 ether);
    }

    /* ---------- update rescuer ---------- */
    function test_updateRescuer_byOwner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Rescuable.RescuerChanged(rescuer, other);
        h.updateRescuer(other);
        assertEq(h.rescuer(), other);
    }

    function test_updateRescuer_nonOwner() public {
        vm.prank(other);
        vm.expectRevert(); // Ownable  revert
        h.updateRescuer(other);
    }

    function test_updateRescuer_zeroAddr() public {
        vm.prank(owner);
        vm.expectRevert(Rescuable.RescuerZeroAddress.selector);
        h.updateRescuer(address(0));
    }

    function test_updateRescuer_sameAddr() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("SameRescuer(address)", rescuer));
        h.updateRescuer(rescuer);
    }

    /* ---------- remove rescuer ---------- */
    function test_removeRescuer_success() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Rescuable.RescuerChanged(rescuer, address(0));
        h.removeRescuer();
        assertEq(h.rescuer(), address(0));

        vm.prank(rescuer);
        vm.expectRevert(abi.encodeWithSignature("NotRescuer(address)", rescuer));
        h.onlyRescuerFn();
    }

    function test_removeRescuer_nonOwner() public {
        vm.prank(other);
        vm.expectRevert();
        h.removeRescuer();
    }
}
