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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title Authorizable
 */
abstract contract Authorizable is Ownable2Step {
    mapping(bytes32 => address) private _authorized;

    error InvalidAuthorizer(bytes32 role);
    error NotAuthorizer(bytes32 role, address addr);

    event AuthorizerChanged(address indexed addr, bytes32 indexed role);
    event AuthorizerRemoved(bytes32 indexed role);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Returns current authorizer
     * @param role Role
     * @return Authorizer's address
     */
    function _authorizer(bytes32 role) internal view returns (address) {
        return _authorized[role];
    }

    /**
     * @notice Authorize an address
     * @param role Role
     * @param addr Address
     */
    function _updateAuthorizer(bytes32 role, address addr) internal onlyOwner {
        if (addr == address(0)) revert InvalidAuthorizer(role);
        _authorized[role] = addr;

        emit AuthorizerChanged(addr, role);
    }

    /**
     * @notice Deauthorize an address
     * @param role Role
     */
    function _removeAuthorizer(bytes32 role) internal onlyOwner {
        delete _authorized[role];

        emit AuthorizerRemoved(role);
    }

    /**
     * @notice Validate if an address is authorized
     * @param role Role
     * @param addr Address
     */
    function _validAuthorizer(bytes32 role, address addr) internal view {
        if (addr != _authorized[role]) revert NotAuthorizer(role, addr);
    }
}
