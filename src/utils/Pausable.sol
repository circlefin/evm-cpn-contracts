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
pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title Pausable
 * @dev Non-upgradeable version of Pausable with dedicated pauser role.
 */
abstract contract Pausable is Context, Ownable2Step {
    bool private _paused;
    address private _pauser;

    event Paused(address account);
    event Unpaused(address account);
    event PauserTransferred(address indexed previousPauser, address indexed newPauser);

    error EnforcedPause();
    error ExpectedPause();
    error NotPauser(address caller);
    error SamePauser(address pauser);
    error PauserZeroAddress();

    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    modifier whenPaused() {
        _requirePaused();
        _;
    }

    modifier onlyPauser() {
        if (_msgSender() != _pauser) revert NotPauser(_msgSender());
        _;
    }

    /**
     * @dev Internal helper – should be called in the constructor to assign the initial pauser.
     */
    function _initializePauser(address initialPauser) internal {
        _paused = false;
        _pauser = initialPauser;
    }

    function paused() public view virtual returns (bool) {
        return _paused;
    }

    function pauser() public view returns (address) {
        return _pauser;
    }

    function _requireNotPaused() internal view virtual {
        if (paused()) revert EnforcedPause();
    }

    function _requirePaused() internal view virtual {
        if (!paused()) revert ExpectedPause();
    }

    function pause() external onlyPauser whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    function unpause() external onlyPauser whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }

    function _setPauser(address newPauser) internal {
        address current = _pauser;
        if (current == newPauser) revert SamePauser(current);
        _pauser = newPauser;
        emit PauserTransferred(current, newPauser);
    }

    function updatePauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert PauserZeroAddress();
        _setPauser(newPauser);
    }

    function removePauser() external onlyOwner {
        _setPauser(address(0));
    }
}
