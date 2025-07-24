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

import {Create2Factory} from "../../src/factory/Create2Factory.sol";
import {Script} from "forge-std/src/Script.sol";

// forge script script/deploy/DeployCreate2Factory.s.sol \
//   --rpc-url $BLOCKCHAIN_RPC_URL \
//   --private-key $DEPLOYER_PRIVATE_KEY \
//   --broadcast
contract DeployCreate2FactoryScript is Script {
    address private deployer;

    function deployCreate2Factory(address _deployer) internal returns (Create2Factory _create2Factory) {
        vm.startBroadcast(_deployer);
        _create2Factory = new Create2Factory();
        vm.stopBroadcast();
    }

    function setUp() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
    }

    function run() public {
        deployCreate2Factory(deployer);
    }
}
