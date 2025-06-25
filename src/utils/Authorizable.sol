/**
 * SPDX-License-Identifier: UNLICENSED
 *
 * Copyright (c) 2025, Circle Internet Financial Trading Company Limited.
 * All rights reserved.
 *
 * Circle Internet Financial Trading Company Limited CONFIDENTIAL
 *
 * This file includes unpublished proprietary source code of Circle Internet
 * Financial Trading Company Limited, Inc. The copyright notice above does not
 * evidence any actual or intended publication of such source code. Disclosure
 * of this source code or any related proprietary information is strictly
 * prohibited without the express written permission of Circle Internet Financial
 * Trading Company Limited.
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
