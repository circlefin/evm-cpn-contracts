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
import {IERC20} from "./../interfaces/IERC20.sol";
import {SafeERC20} from "./SafeERC20.sol";

/**
 * @title Rescuable
 */
abstract contract Rescuable is Authorizable {
    using SafeERC20 for IERC20;

    error InvalidRescueTokenAddress();
    error InvalidRescueToAddress();
    error InvalidRescueAmount();
    error RescueAmountExceedsBalance();

    // keccak256("RESCUER_ROLE")
    bytes32 private constant RESCUER_ROLE = 0xcf6f9f892731e14b8859835f2ff35575f447fb501f46243c4eb8bac19e31a050;

    event TokensRescued(address indexed token, address indexed sender, address indexed to, uint256 amount);

    /**
     * @notice Revert if called by any account other than the authorizer.
     */
    modifier onlyRescuer() {
        _validAuthorizer(RESCUER_ROLE, _msgSender());
        _;
    }

    /**
     * @notice Returns current rescuer
     * @return Rescuer's address
     */
    function rescuer() external view returns (address) {
        return _authorizer(RESCUER_ROLE);
    }

    /**
     * @notice Rescue ERC20 tokens locked up in this contract.
     * @param token ERC20 token contract address
     * @param to        Recipient address
     * @param amount    Amount to withdraw
     */
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyRescuer {
        if (address(token) == address(0)) revert InvalidRescueTokenAddress();
        if (to == address(0)) revert InvalidRescueToAddress();
        if (amount == 0) revert InvalidRescueAmount();

        uint256 balance = token.balanceOf(address(this));
        if (balance < amount) revert RescueAmountExceedsBalance();
        token.safeTransfer(to, amount);

        emit TokensRescued(address(token), msg.sender, to, amount);
    }

    /**
     * @notice Updates the rescuer address.
     * @param newRescuer The address of the new rescuer.
     */
    function updateRescuer(address newRescuer) external onlyOwner {
        _updateAuthorizer(RESCUER_ROLE, newRescuer);
    }

    /**
     * @notice Removes the rescuer address.
     */
    function removeRescuer() external onlyOwner {
        _removeAuthorizer(RESCUER_ROLE);
    }
}
