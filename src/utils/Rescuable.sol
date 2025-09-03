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
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/// @title Rescuable
/// @notice Enables recovery of ERC20 or native tokens by an authorized rescuer
/// @dev Designed for use in contracts that may receive stuck funds
abstract contract Rescuable is Context, Ownable2Step, Initializable {
    using SafeERC20 for IERC20;

    /// @dev Address assigned as the current rescuer
    address private _rescuer;

    /// @dev Common placeholder used to represent native tokens (e.g., ETH) in logs and offchain systems
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Reverts when caller is not the current rescuer
    /// @param caller Unauthorized caller
    error NotRescuer(address caller);

    /// @notice Reverts when the new rescuer is the same as current
    /// @param addr Duplicate rescuer address
    error SameRescuer(address addr);

    /// @notice Reverts when rescuer address is zero
    error RescuerZeroAddress();

    /// @notice Reverts when attempting to rescue from zero token address
    error InvalidRescueTokenAddress();

    /// @notice Reverts when destination address is zero
    error InvalidRescueToAddress();

    /// @notice Reverts when attempting to rescue zero amount
    error InvalidRescueAmount();

    /// @notice Reverts if native token transfer fails
    error NativeTransferFailed();

    /// @notice Emitted when tokens are rescued from the contract
    /// @param token Token address (use NATIVE_TOKEN_ADDRESS for native tokens)
    /// @param sender Initiator of the rescue
    /// @param to Recipient of rescued tokens
    /// @param value Amount rescued
    event TokensRescued(address indexed token, address indexed sender, address indexed to, uint256 value);

    /// @notice Emitted when the rescuer role is transferred
    /// @param previousRescuer Address of the previous rescuer
    /// @param newRescuer Address of the new rescuer
    event RescuerTransferred(address indexed previousRescuer, address indexed newRescuer);

    /// @notice Modifier to restrict access to the current rescuer
    /// @dev Reverts with NotRescuer if msg.sender is not rescuer
    modifier onlyRescuer() {
        if (_msgSender() != _rescuer) revert NotRescuer(_msgSender());
        _;
    }

    /// @dev Initializes the rescuer role
    /// @param initialRescuer Address to set as initial rescuer
    function _initializeRescuer(address initialRescuer) internal onlyInitializing {
        if (initialRescuer != address(0)) {
            _rescuer = initialRescuer;
            emit RescuerTransferred(address(0), initialRescuer);
        }
    }

    /// @notice Returns the current rescuer address
    /// @return Address with rescuer privileges
    function rescuer() public view returns (address) {
        return _rescuer;
    }

    /// @notice Updates the rescuer address
    /// @dev Callable only by the contract owner
    /// @param newRescuer Address to assign as new rescuer
    function updateRescuer(address newRescuer) external onlyOwner {
        if (newRescuer == address(0)) revert RescuerZeroAddress();
        _setRescuer(newRescuer);
    }

    /// @notice Removes the rescuer role
    /// @dev Callable only by the contract owner
    function removeRescuer() external onlyOwner {
        _setRescuer(address(0));
    }

    /// @notice Allows rescuer to transfer ERC20 tokens from contract
    /// @param token ERC20 token to rescue
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyRescuer {
        if (address(token) == address(0)) revert InvalidRescueTokenAddress();
        if (to == address(0)) revert InvalidRescueToAddress();
        if (amount == 0) revert InvalidRescueAmount();

        token.safeTransfer(to, amount);
        emit TokensRescued(address(token), _msgSender(), to, amount);
    }

    /// @notice Allows rescuer to transfer native tokens from contract
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function rescueNative(address to, uint256 amount) external onlyRescuer {
        if (to == address(0)) revert InvalidRescueToAddress();
        if (amount == 0) revert InvalidRescueAmount();
        // slither-disable-next-line arbitrary-send-eth
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();

        emit TokensRescued(NATIVE_TOKEN_ADDRESS, _msgSender(), to, amount);
    }

    /// @dev Internal function to update rescuer and emit event
    /// @param newRescuer Address to assign as rescuer
    function _setRescuer(address newRescuer) private {
        address current = _rescuer;
        if (newRescuer == current) revert SameRescuer(newRescuer);
        _rescuer = newRescuer;
        emit RescuerTransferred(current, newRescuer);
    }
}
