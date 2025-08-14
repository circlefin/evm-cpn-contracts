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
// solhint-disable-next-line one-contract-per-file
pragma solidity 0.8.24;

import {CirclePaymentsNetwork} from "../../src/CirclePaymentsNetwork.sol";
import {IMinimalPermit2} from "../../src/interfaces/IMinimalPermit2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/src/Test.sol";
import {console} from "forge-std/src/console.sol";

contract Mock1271Wallet {
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;

    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return MAGICVALUE;
    }
}

contract TestERC20 is ERC20 {
    constructor() ERC20("MockUSD", "mUSDC") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract DummyPermit2 is IMinimalPermit2 {
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes32,
        string calldata,
        bytes calldata
    ) external override {
        IERC20(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount);
    }
}

contract CirclePaymentsNetworkGasTest is Test {
    CirclePaymentsNetwork internal payment;
    DummyPermit2 internal permit2;
    TestERC20 internal usdc;

    address internal payer = address(0xa0);
    address internal payeeEOA;
    address internal payee1271;
    address internal feeSink = address(0xc0);
    address internal attester = address(0xd0);

    uint256 internal payeePk;
    bool internal writeToFile;
    uint256 private _permitNonce;

    function setUp() public {
        payeePk = 0xB22;
        payeeEOA = vm.addr(payeePk);
        payee1271 = address(new Mock1271Wallet());

        permit2 = new DummyPermit2();
        payment = new CirclePaymentsNetwork();

        address[] memory attesters = new address[](1);
        attesters[0] = attester;
        payment.initialize(
            IMinimalPermit2(address(permit2)), address(this), address(0xe0), address(0xf0), address(0xdead), attesters
        );

        usdc = new TestERC20();
        usdc.mint(payer, 1_000_000 ether);
        vm.prank(payer);
        usdc.approve(address(permit2), type(uint256).max);

        writeToFile = vm.envOr("WRITE_GAS_PROFILE_TO_FILE", false);
    }

    function testBenchmark_execute_basic() public {
        _runExecute("execute_basic", payeeEOA, false, "", 0x01);
    }

    function testBenchmark_execute_withSigEOA() public {
        bytes32 digest = _buildPayeeDigest(payeeEOA, 100 ether, 0x02);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payeePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        _runExecute("execute_withPayeeSigEOA", payeeEOA, true, sig, 0x02);
    }

    function testBenchmark_execute_withSig1271() public {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));
        _runExecute("execute_withPayeeSig1271", payee1271, true, sig, 0x03);
    }

    function testBenchmark_cancel_basic() public {
        uint256 fee = 5 ether;
        bytes32 n = keccak256("gas-cancel");

        CirclePaymentsNetwork.PaymentIntent memory intent = CirclePaymentsNetwork.PaymentIntent({
            from: payer,
            to: address(0),
            value: 0,
            validAfter: 0,
            validBefore: 0,
            nonce: n,
            beneficiary: feeSink,
            maxFee: fee,
            requirePayeeSign: false,
            attester: attester
        });

        CirclePaymentsNetwork.PayerData memory pd = CirclePaymentsNetwork.PayerData({
            permit: IMinimalPermit2.PermitTransferFrom({
                permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: fee}),
                nonce: _permitNonce++,
                deadline: block.timestamp + 1 days
            }),
            signature: ""
        });

        vm.startPrank(attester);
        uint256 gasBefore = gasleft();
        payment.cancel(intent, pd, fee);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        if (!writeToFile) {
            console.log("case - cancel_basic");
            console.log("   gasUsed: %s", gasUsed);
            return;
        }

        string memory id = "obj";
        string memory json = vm.serializeString(id, "entryPointVersion", "0.7");
        json = vm.serializeUint(id, "gasUsed", gasUsed);
        json = vm.serializeAddress(id, "txToAddress", address(payment));
        json = vm.serializeBytes(id, "txCalldata", abi.encodeCall(payment.cancel, (intent, pd, fee)));
        string memory wrapped = vm.serializeString("root", "cancel_basic", json);
        vm.writeJson(wrapped, "./gas/results/cancel_basic.json");
    }

    /// -----------------------------------------------------------------------
    /// INTERNAL HELPERS
    /// -----------------------------------------------------------------------

    function _writeGasProfile(string memory label, uint256 gasUsed, bytes memory txCalldata) internal {
        string memory id = "obj";
        string memory json = vm.serializeString(id, "entryPointVersion", "0.7");
        json = vm.serializeUint(id, "gasUsed", gasUsed);
        json = vm.serializeAddress(id, "txToAddress", address(payment));
        json = vm.serializeBytes(id, "txCalldata", txCalldata);

        string memory wrapped = vm.serializeString("root", label, json);
        vm.writeJson(wrapped, string.concat("./gas/results/", label, ".json"));
    }

    /// -----------------------------------------------------------------------
    /// MAIN EXECUTION BENCHMARK
    /// -----------------------------------------------------------------------

    function _runExecute(string memory label, address payee, bool requireSig, bytes memory sig, uint256 nonceSeed)
        internal
    {
        uint256 value = 100 ether;
        uint256 fee = 5 ether;
        bytes32 n = keccak256(abi.encodePacked(label, nonceSeed));

        // Build PaymentIntent
        CirclePaymentsNetwork.PaymentIntent memory intent;
        intent.from = payer;
        intent.to = payee;
        intent.value = value;
        intent.validAfter = 0;
        intent.validBefore = block.timestamp + 1 days;
        intent.nonce = n;
        intent.beneficiary = feeSink;
        intent.maxFee = fee;
        intent.requirePayeeSign = requireSig;
        intent.attester = attester;

        // Build PayerData
        CirclePaymentsNetwork.PayerData memory pd;
        pd.permit = IMinimalPermit2.PermitTransferFrom({
            permitted: IMinimalPermit2.TokenPermissions({token: address(usdc), amount: value + fee}),
            nonce: 0,
            deadline: block.timestamp + 1 days
        });
        pd.signature = "";

        // Execute & measure gas
        vm.startPrank(attester);
        uint256 gasBefore = gasleft();
        payment.execute(intent, pd, sig, fee);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Console output or JSON dump
        if (!writeToFile) {
            console.log("case - %s", label);
            console.log("   gasUsed: %s", gasUsed);
            return;
        }

        bytes memory txCalldata = abi.encodeCall(payment.execute, (intent, pd, sig, fee));
        _writeGasProfile(label, gasUsed, txCalldata);
    }

    function _buildPayeeDigest(address payee, uint256 value, uint256 nonceSeed) internal view returns (bytes32) {
        bytes32 nonce = keccak256(abi.encodePacked("execute_withPayeeSigEOA", nonceSeed));
        bytes32 structHash = keccak256(
            abi.encode(
                payment.PAYEE_PAYMENT_INTENT_TYPEHASH(),
                address(usdc),
                payee,
                value,
                0,
                block.timestamp + 1 days,
                nonce,
                attester
            )
        );
        bytes32 domain = payment._domainSeparator();
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
