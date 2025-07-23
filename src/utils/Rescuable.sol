/**
 * SPDX-License-Identifier: Apache-2.0
 *
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
pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title Rescuable
 */
abstract contract Rescuable is Context, Ownable2Step {
    using SafeERC20 for IERC20;

    address private _rescuer;

    // EIP‑6900 canonical native token address (used only for event clarity)
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    error NotRescuer(address caller);
    error SameRescuer(address addr);
    error RescuerZeroAddress();

    error InvalidRescueTokenAddress();
    error InvalidRescueToAddress();
    error InvalidRescueAmount();
    error RescueAmountExceedsBalance();
    error NativeTransferFailed();

    event TokensRescued(address indexed token, address indexed sender, address indexed to, uint256 value);
    event RescuerChanged(address indexed oldRescuer, address indexed newRescuer);

    modifier onlyRescuer() {
        if (_msgSender() != _rescuer) revert NotRescuer(_msgSender());
        _;
    }

    function _initializeRescuer(address initialRescuer) internal {
        if (initialRescuer == address(0)) revert RescuerZeroAddress();
        _rescuer = initialRescuer;
        emit RescuerChanged(address(0), initialRescuer);
    }

    function rescuer() public view returns (address) {
        return _rescuer;
    }

    function updateRescuer(address newRescuer) external onlyOwner {
        if (newRescuer == address(0)) revert RescuerZeroAddress();
        _setRescuer(newRescuer);
    }

    function removeRescuer() external onlyOwner {
        _setRescuer(address(0));
    }

    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyRescuer {
        if (address(token) == address(0)) revert InvalidRescueTokenAddress();
        _rescueERC20(token, to, amount);
    }

    function rescueNativeToken(address to, uint256 amount) external onlyRescuer {
        if (to == address(0)) revert InvalidRescueToAddress();
        if (amount == 0) revert InvalidRescueAmount();

        uint256 bal = address(this).balance;
        if (bal < amount) revert RescueAmountExceedsBalance();
        // slither-disable-next-line arbitrary-send-eth
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();

        emit TokensRescued(NATIVE_TOKEN_ADDRESS, _msgSender(), to, amount);
    }

    function _rescueERC20(IERC20 token, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidRescueToAddress();
        if (amount == 0) revert InvalidRescueAmount();

        uint256 bal = token.balanceOf(address(this));
        if (bal < amount) revert RescueAmountExceedsBalance();

        token.safeTransfer(to, amount);
        emit TokensRescued(address(token), _msgSender(), to, amount);
    }

    function _setRescuer(address newRescuer) private {
        if (newRescuer == _rescuer) revert SameRescuer(newRescuer);
        address old = _rescuer;
        _rescuer = newRescuer;
        emit RescuerChanged(old, newRescuer);
    }
}
