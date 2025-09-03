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
pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/// @title Configurable
/// @notice Provides a configurator role for privileged parameter updates
/// @dev Intended to be inherited by contracts requiring off-owner configuration access
abstract contract Configurable is Context, Ownable2Step, Initializable {
    /// @dev Address assigned with the configurator role
    address private _configurator;

    /// @notice Reverts when caller is not configurator
    error NotConfigurator(address caller);
    /// @notice Reverts when attempting to set the same configurator
    error SameConfigurator(address addr);
    /// @notice Reverts when new configurator address is zero
    error ConfiguratorZeroAddress();

    /// @notice Emitted when the configurator role is transferred
    /// @param previousConfigurator Address of the previous configurator
    /// @param newConfigurator Address of the new configurator
    event ConfiguratorTransferred(address indexed previousConfigurator, address indexed newConfigurator);

    /// @notice Restricts function to be called only by the current configurator
    /// @dev Reverts with NotConfigurator if caller is not _configurator
    modifier onlyConfigurator() {
        if (_msgSender() != _configurator) revert NotConfigurator(_msgSender());
        _;
    }

    /// @dev Initializes the configurator role
    /// @param initialConfigurator Address to assign as initial configurator
    function _initializeConfigurator(address initialConfigurator) internal onlyInitializing {
        if (initialConfigurator != address(0)) {
            _configurator = initialConfigurator;
            emit ConfiguratorTransferred(address(0), initialConfigurator);
        }
    }

    /// @notice Returns the current configurator address
    /// @return Address assigned as configurator
    function configurator() public view returns (address) {
        return _configurator;
    }

    /// @notice Assigns a new configurator
    /// @dev Callable only by the contract owner. Reverts if newConfigurator is address(0)
    /// @param newConfigurator Address to assign as new configurator
    function updateConfigurator(address newConfigurator) external onlyOwner {
        if (newConfigurator == address(0)) revert ConfiguratorZeroAddress();
        _setConfigurator(newConfigurator);
    }

    /// @notice Removes the configurator role
    /// @dev Sets configurator to address(0). Callable only by the contract owner.
    function removeConfigurator() external onlyOwner {
        _setConfigurator(address(0));
    }

    /// @dev Internal function to update configurator role and emit event
    /// @param newConfigurator Address to assign as new configurator
    function _setConfigurator(address newConfigurator) internal {
        address current = _configurator;
        if (newConfigurator == current) revert SameConfigurator(newConfigurator);
        _configurator = newConfigurator;
        emit ConfiguratorTransferred(current, newConfigurator);
    }
}
