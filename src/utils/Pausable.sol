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
pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/// @title Pausable
/// @notice Adds pausing functionality with a dedicated pauser role
/// @dev Intended to be inherited by contracts requiring pause functionality
abstract contract Pausable is Context, Ownable2Step, Initializable {
    /// @dev Internal state tracking whether the contract is paused
    bool private _paused;

    /// @dev Address assigned with the pauser role
    address private _pauser;

    /// @notice Emitted when the contract is paused
    /// @param account Address that triggered the pause
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    /// @param account Address that triggered the unpause
    event Unpaused(address account);

    /// @notice Emitted when the pauser role is transferred
    /// @param previousPauser The address of the old pauser
    /// @param newPauser The address of the new pauser
    event PauserTransferred(address indexed previousPauser, address indexed newPauser);

    /// @notice Reverts when the contract is paused but should not be
    error EnforcedPause();

    /// @notice Reverts when the contract is not paused but should be
    error ExpectedPause();

    /// @notice Reverts when caller is not the current pauser
    /// @param caller The unauthorized caller
    error NotPauser(address caller);

    /// @notice Reverts when assigning the same pauser again
    /// @param pauser The duplicated pauser address
    error SamePauser(address pauser);

    /// @notice Reverts when the new pauser is the zero address
    error PauserZeroAddress();

    /// @notice Modifier to allow function execution only when contract is not paused
    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    /// @notice Modifier to allow function execution only when contract is paused
    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /// @notice Modifier to restrict function to the current pauser
    /// @dev Reverts with NotPauser if msg.sender is not the current pauser
    modifier onlyPauser() {
        if (_msgSender() != _pauser) revert NotPauser(_msgSender());
        _;
    }

    /// @dev Initializes the pauser role at deployment
    /// @param initialPauser The initial address assigned as pauser
    function _initializePauser(address initialPauser) internal onlyInitializing {
        _paused = false;
        if (initialPauser != address(0)) {
            _pauser = initialPauser;
            emit PauserTransferred(address(0), initialPauser);
        }
    }

    /// @notice Returns whether the contract is currently paused
    /// @return True if paused, false otherwise
    function paused() public view returns (bool) {
        return _paused;
    }

    /// @notice Returns the current pauser address
    /// @return The address with pauser role
    function pauser() public view returns (address) {
        return _pauser;
    }

    /// @dev Reverts if the contract is paused
    function _requireNotPaused() internal view {
        if (paused()) revert EnforcedPause();
    }

    /// @dev Reverts if the contract is not paused
    function _requirePaused() internal view {
        if (!paused()) revert ExpectedPause();
    }

    /// @notice Triggers the paused state
    /// @dev Callable only by the pauser when not already paused
    function pause() external onlyPauser whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /// @notice Lifts the paused state
    /// @dev Callable only by the pauser when currently paused
    function unpause() external onlyPauser whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }

    /// @dev Internal function to update the pauser role
    /// @param newPauser The new address to assign as pauser
    function _setPauser(address newPauser) internal {
        address current = _pauser;
        if (current == newPauser) revert SamePauser(current);
        _pauser = newPauser;
        emit PauserTransferred(current, newPauser);
    }

    /// @notice Updates the pauser address
    /// @dev Callable only by the contract owner
    /// @param newPauser Address to assign as the new pauser
    function updatePauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert PauserZeroAddress();
        _setPauser(newPauser);
    }

    /// @notice Removes the pauser role
    /// @dev Sets the pauser to the zero address. Callable only by the contract owner.
    function removePauser() external onlyOwner {
        _setPauser(address(0));
    }
}
