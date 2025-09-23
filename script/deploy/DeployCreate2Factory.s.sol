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

import {Create2Factory} from "../../src/factory/Create2Factory.sol";
import {Script} from "forge-std/src/Script.sol";
import {console2} from "forge-std/src/console2.sol";

// forge script script/deploy/DeployCreate2Factory.s.sol \
//   --rpc-url $BLOCKCHAIN_RPC_URL \
//   --private-key $DEPLOYER_PRIVATE_KEY \
//   --broadcast
contract DeployCreate2FactoryScript is Script {
    address private deployer;

    function deployCreate2Factory(address _deployer) internal returns (Create2Factory _create2Factory) {
        bytes memory bytecode = abi.encodePacked(
            type(Create2Factory).creationCode,
            abi.encode(_deployer) // constructor(address initialOwner)
        );

        bytes32 salt = keccak256(abi.encodePacked(vm.envString("CREATE2_FACTORY_SALT")));
        address deployed;

        vm.startBroadcast(_deployer);
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(deployed != address(0), "Create2Factory deployment failed");
        vm.stopBroadcast();

        _create2Factory = Create2Factory(deployed);
        console2.log("Create2Factory deployed at:", deployed);
    }

    function setUp() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
    }

    function run() public {
        deployCreate2Factory(deployer);
    }
}
