/**
 * SPDX-License-Identifier: Apache-2.0
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

import {Authorizable} from "../../src/utils/Authorizable.sol";

/**
 * @title TestableAuthorizable
 * @notice Concrete implementation of Authorizable for testing purposes
 * @dev Exposes internal functions as external for testing
 */
contract TestableAuthorizable is Authorizable {
    function authorizer(bytes32 role) external view returns (address) {
        return _authorizer(role);
    }

    function updateAuthorizer(bytes32 role, address addr) external {
        _updateAuthorizer(role, addr);
    }

    function removeAuthorizer(bytes32 role) external {
        _removeAuthorizer(role);
    }

    function validAuthorizer(bytes32 role, address addr) external view {
        _validAuthorizer(role, addr);
    }
}
