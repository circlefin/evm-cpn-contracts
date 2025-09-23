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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title Create2Factory
/// @notice Deploys a contract deterministically using CREATE2
contract Create2Factory is Ownable2Step {
    /// @notice Reverts when bytecode is empty
    error EmptyBytecode();
    /// @notice Reverts when deployment fails
    error DeploymentFailed();

    /// @notice Emitted when a contract is deployed
    event FactoryDeployed(address indexed deployed, bytes32 indexed salt);

    /// @notice Initializes ownership to `initialOwner`
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Deploy a contract using CREATE2
    /// @param salt Unique salt to ensure deterministic deployment
    /// @param bytecode Full creation bytecode (including constructor args)
    /// @return deployed The address of the deployed contract
    function deploy(bytes32 salt, bytes calldata bytecode) external onlyOwner returns (address deployed) {
        deployed = _deploy(salt, bytecode);
    }

    /// @notice Predict the deployment address using salt + bytecode
    /// @param salt User-defined salt
    /// @param bytecode Creation bytecode
    /// @return predicted Deterministic deployment address
    function getAddress(bytes32 salt, bytes calldata bytecode) external view returns (address predicted) {
        bytes32 hash = keccak256(bytecode);
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
    }

    /// @notice Deploy a contract and immediately perform multiple calls to it
    /// @param salt User-provided salt
    /// @param bytecode Contract creation code
    /// @param calls ABI-encoded function calls to invoke on the deployed address
    /// @return deployed The address of the deployed contract
    function deployAndMultiCall(bytes32 salt, bytes calldata bytecode, bytes[] calldata calls)
        external
        onlyOwner
        returns (address deployed)
    {
        deployed = _deploy(salt, bytecode);
        uint256 len = calls.length;
        for (uint256 i = 0; i < len; i++) {
            // slither-disable-next-line low-level-calls, solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory ret) = deployed.call(calls[i]);
            if (!ok) {
                // Bubble the original error (e.g. custom error like ZeroAddress)
                // slither-disable-next-line assembly
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    /// @dev Internal deploy helper used by both deploy() and deployAndMultiCall()
    function _deploy(bytes32 salt, bytes calldata bytecode) internal returns (address deployed) {
        if (bytecode.length == 0) revert EmptyBytecode();

        bytes memory memcode = bytecode;
        assembly {
            deployed := create2(0, add(memcode, 0x20), mload(memcode), salt)
        }

        // move this check out of assembly
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();

        emit FactoryDeployed(deployed, salt);
    }
}
