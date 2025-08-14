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

import {CirclePaymentsNetwork} from "../../src/CirclePaymentsNetwork.sol";
import {Create2Factory} from "../../src/factory/Create2Factory.sol";
import {IMinimalPermit2} from "../../src/interfaces/IMinimalPermit2.sol";
import {Script} from "forge-std/src/Script.sol";
import {console2} from "forge-std/src/console2.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// forge script script/deploy/DeployCirclePaymentsNetworkScript.s.sol \
//   --rpc-url $BLOCKCHAIN_RPC_URL \
//   --private-key $DEPLOYER_PRIVATE_KEY \
//   --broadcast
contract DeployCirclePaymentsNetworkScript is Script {
    /// ─────────── env vars ───────────
    address private deployer;

    address private ownerAddr;
    address private rescuerAddr;
    address private pauserAddr;
    address private configuratorAddr;
    address private permit2Addr;

    Create2Factory private factory;
    bytes32 private salt;

    /// ─────────── helpers ───────────
    function _loadAttesters() internal view returns (address[] memory attesters) {
        uint256 count = vm.envUint("CIRCLE_PAYMENT_ATTESTER_COUNT");
        attesters = new address[](count);
        for (uint256 i; i < count; ++i) {
            attesters[i] = vm.envAddress(string.concat("CIRCLE_PAYMENT_ATTESTER_", Strings.toString(i)));
        }
    }

    /// ─────────── setUp ───────────
    function setUp() public {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");

        ownerAddr = vm.envAddress("CIRCLE_PAYMENT_OWNER_ADDRESS");
        rescuerAddr = vm.envAddress("CIRCLE_PAYMENT_RESCUER_ADDRESS");
        pauserAddr = vm.envAddress("CIRCLE_PAYMENT_PAUSER_ADDRESS");
        configuratorAddr = vm.envAddress("CIRCLE_PAYMENT_CONFIGURATOR_ADDRESS");
        permit2Addr = vm.envAddress("PERMIT2_CONTRACT_ADDRESS");

        factory = Create2Factory(vm.envAddress("CREATE2_FACTORY_CONTRACT_ADDRESS"));
        salt = keccak256(bytes(vm.envString("CIRCLE_PAYMENT_SALT")));
    }

    /// ─────────── run ───────────
    function run() public {
        address[] memory attesters = _loadAttesters();

        vm.startBroadcast(deployer);

        bytes memory initData = abi.encodeCall(
            CirclePaymentsNetwork.initialize,
            (IMinimalPermit2(permit2Addr), ownerAddr, rescuerAddr, pauserAddr, configuratorAddr, attesters)
        );

        bytes[] memory calls = new bytes[](1);
        calls[0] = initData;

        address circlePayment = factory.deployAndMultiCall(salt, type(CirclePaymentsNetwork).creationCode, calls);
        console2.log("CirclePaymentsNetwork deployed at:", circlePayment);

        vm.stopBroadcast();
    }
}
