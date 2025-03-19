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

import {Authorizable} from "./Authorizable.sol";

/**
 * @title Witnessable
 */
abstract contract Witnessable is Authorizable {
    // keccak256("WITNESS_AUTHORIZER_ROLE")
    bytes32 private constant WITNESS_AUTHORIZER_ROLE =
        0x07d1bfcfd2de1792ff23be961881d3face60517033eaa20d7a16112c8ce3e155;

    /**
     * @notice Revert if called by any account other than the witness authorizer.
     */
    modifier onlyWitnessAuthorizer() {
        _validAuthorizer(WITNESS_AUTHORIZER_ROLE, _msgSender());
        _;
    }

    /**
     * @notice Returns current witness authorizer
     * @return witness authorizer's address.
     */
    function witnessAuthorizer() external view returns (address) {
        return _authorizer(WITNESS_AUTHORIZER_ROLE);
    }

    /**
     * @notice Updates witness authorizer address.
     * @param addr Address
     */
    function updateWitnessAuthorizer(address addr) external onlyOwner {
        _updateAuthorizer(WITNESS_AUTHORIZER_ROLE, addr);
    }

    /**
     * @notice Removes witness authorizer address.
     */
    function removeWitnessAuthorizer() external onlyOwner {
        _removeAuthorizer(WITNESS_AUTHORIZER_ROLE);
    }
}
