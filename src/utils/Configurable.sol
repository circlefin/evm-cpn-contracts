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

// ───────────────────────────────────────── IMPORTS ──────────────────────────────────────────

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title Configurable
 *
 * @notice   Upgrade-safe helper providing a dedicated *configurator* role.
 *           so downstream contracts can gate sensitive parameter changes with `onlyConfigurator`.
 */
abstract contract Configurable is Context, Ownable2Step {
    /*──────────────────────────── STATE ────────────────────────────*/
    address private _configurator;

    /*──────────────────────────── ERRORS ───────────────────────────*/
    error NotConfigurator(address caller);
    error SameConfigurator(address addr);
    error ConfiguratorZeroAddress();

    /*──────────────────────────── EVENTS ───────────────────────────*/
    event ConfiguratorTransferred(address indexed previousConfigurator, address indexed newConfigurator);

    /*──────────────────────────── MODIFIERS ────────────────────────*/
    /// @notice Restricts the caller to the current **configurator**.
    modifier onlyConfigurator() {
        if (_msgSender() != _configurator) revert NotConfigurator(_msgSender());
        _;
    }

    /*────────────────────────── CONSTRUCTOR HELPER ─────────────────*/
    function _initializeConfigurator(address initialConfigurator) internal {
        _updateConfiguratorInternal(initialConfigurator);
    }

    /*──────────────────────────── GETTERS ──────────────────────────*/
    function configurator() public view returns (address) {
        return _configurator;
    }

    /*───────────────────────── MUTATIONS (owner) ───────────────────*/
    /**
     * @notice Assign a **new configurator**.
     * @dev    Callable only by the contract owner. Set to `address(0)` to *remove* the role.
     */
    function updateConfigurator(address newConfigurator) external onlyOwner {
        if (newConfigurator == address(0)) revert ConfiguratorZeroAddress();
        _updateConfiguratorInternal(newConfigurator);
    }

    /**
     * @notice Removes the configurator role (sets it to address(0)).
     * @dev    Callable only by the contract owner.
     */
    function removeConfigurator() external onlyOwner {
        _updateConfiguratorInternal(address(0));
    }

    /*──────────────────────── INTERNAL HELPERS ─────────────────────*/
    function _updateConfiguratorInternal(address newConfigurator) internal {
        if (newConfigurator == _configurator) revert SameConfigurator(newConfigurator);

        address old = _configurator;
        _configurator = newConfigurator;
        emit ConfiguratorTransferred(old, newConfigurator);
    }
}
