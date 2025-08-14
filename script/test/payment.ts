// SPDX-License-Identifier: Apache-2.0

import {
  createWalletClient,
  createPublicClient,
  encodeAbiParameters,
  encodePacked,
  http,
  keccak256,
  toHex,
  concatHex,
  Hex,
  Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { config } from "dotenv";
import { abi as circlePaymentAbi } from "../../out/CirclePaymentsNetwork.sol/CirclePaymentsNetwork.json";

config({ path: "../../configs/.env.dev" });

function normalizeKey(raw: string | undefined, name: string): Hex {
  if (!raw) throw new Error(`Missing ${name}`);
  const prefixed = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (prefixed.length !== 66) throw new Error(`Invalid ${name} length`);
  return prefixed as Hex;
}

function envHex(name: string): Hex {
  const v = process.env[name];
  if (!v) throw new Error(`Missing ${name}`);
  return v.startsWith("0x") ? (v as Hex) : (`0x${v}` as Hex);
}

function nowSec(): bigint {
  return BigInt(Math.floor(Date.now() / 1e3));
}

const TOKEN_PERMISSIONS_TYPEHASH = keccak256(
  toHex("TokenPermissions(address token,uint256 amount)")
);

const PERMIT_TRANSFER_FROM_TYPEHASH = keccak256(
  toHex("PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)")
);

const PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB =
  "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

const PAYER_PAYMENT_INTENT_TYPEHASH = keccak256(
  toHex(
    "PaymentIntent(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce,address beneficiary,uint256 maxFee,bool requirePayeeSign,address attester)"
  )
);

let WITNESS_PAYMENT_TYPE_STR: string;
let WITNESS_TYPE_HASH: Hex;

const EIP712_DOMAIN_TYPEHASH = keccak256(
  toHex("EIP712Domain(string name,uint256 chainId,address verifyingContract)")
);
const PERMIT2_NAME_HASH = keccak256(toHex("Permit2"));

function envAddr(name: string): Address {
  return envHex(name) as Address;
}

async function main() {
  const rpcUrl = process.env.BLOCKCHAIN_RPC_URL!;
  const chain = sepolia;

  const permit2 = envAddr("PERMIT2_CONTRACT_ADDRESS");
  const circlePayment = envAddr("CIRCLE_PAYMENT_CONTRACT_ADDRESS");
  const token = envAddr("TOKEN_ADDRESS");

  const payerKey = normalizeKey(process.env.PAYER_PRIVATE_KEY, "PAYER_PRIVATE_KEY");
  const attesterKey = normalizeKey(process.env.ATTESTER_PRIVATE_KEY, "ATTESTER_PRIVATE_KEY");

  const payee: Address = envAddr("PAYEE_ADDRESS");
  const beneficiary: Address = envAddr("BENEFICIARY_ADDRESS");

  const amountTokens = 950_000n;
  const feeTokens = 50_000n;
  const permittedAmount = amountTokens + feeTokens;
  const permitDeadline = nowSec() + 3600n;
  const permitNonce = nowSec();

  const payerAccount = privateKeyToAccount(payerKey);
  const attesterAccount = privateKeyToAccount(attesterKey);

  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const walletClient = createWalletClient({
      account: attesterAccount,
      chain,
      transport: http(rpcUrl),
  });

  WITNESS_PAYMENT_TYPE_STR = (await publicClient.readContract({
      address: circlePayment,
      abi: circlePaymentAbi,
      functionName: "_WITNESS_PAYMENT_TYPE_STR",
  })) as string;

  const WITNESS_STR_CLEAN = WITNESS_PAYMENT_TYPE_STR.trim();
  WITNESS_TYPE_HASH = keccak256(toHex(WITNESS_STR_CLEAN));

  const tokenPermissionsHash = keccak256(
      encodeAbiParameters(
          [
              { type: "bytes32" },
              { type: "address" },
              { type: "uint256" },
          ],
          [TOKEN_PERMISSIONS_TYPEHASH, token, permittedAmount]
      )
  );

  const latestBlock = await publicClient.getBlock();
  const chainNow = BigInt(latestBlock.timestamp);
  const validAfter = chainNow - 30n;
  const validBefore = chainNow + 3600n;

  console.log("chainNow :", chainNow.toString());
  console.log("validAfter:", validAfter.toString());
  console.log("validBefore:", validBefore.toString());

  const intentNonce = keccak256(
      encodePacked(["uint256", "address"], [chainNow, payerAccount.address])
  );

  const witnessHash = keccak256(
      encodeAbiParameters(
          [
              { type: "bytes32" },
              { type: "address" },
              { type: "address" },
              { type: "uint256" },
              { type: "uint256" },
              { type: "uint256" },
              { type: "bytes32" },
              { type: "address" },
              { type: "uint256" },
              { type: "bool" },
              { type: "address" },
          ],
          [
              PAYER_PAYMENT_INTENT_TYPEHASH,
              payerAccount.address,
              payee,
              amountTokens,
              validAfter,
              validBefore,
              intentNonce,
              beneficiary,
              feeTokens,
              false,
              attesterAccount.address,
          ]
      )
  );

  const dynamicWitnessTypeHash = keccak256(
      toHex(PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB + WITNESS_STR_CLEAN)
  );

  const permitHashWithWitness = keccak256(
      encodeAbiParameters(
          [
              { type: "bytes32" },
              { type: "bytes32" },
              { type: "address" },
              { type: "uint256" },
              { type: "uint256" },
              { type: "bytes32" },
          ],
          [
              dynamicWitnessTypeHash,
              tokenPermissionsHash,
              circlePayment,
              permitNonce,
              permitDeadline,
              witnessHash,
          ]
      )
  );

  const domainSeparator = keccak256(
      encodeAbiParameters(
          [
              { type: "bytes32" },
              { type: "bytes32" },
              { type: "uint256" },
              { type: "address" },
          ],
          [
              EIP712_DOMAIN_TYPEHASH,
              PERMIT2_NAME_HASH,
              BigInt(chain.id),
              permit2,
          ]
      )
  );

  const payerSig: Hex = await payerAccount.signTypedData({
      domain: {
          name: "Permit2",
          chainId: chain.id,
          verifyingContract: permit2,
      },
      types: {
          PermitWitnessTransferFrom: [
              { name: "permitted", type: "TokenPermissions" },
              { name: "spender", type: "address" },
              { name: "nonce", type: "uint256" },
              { name: "deadline", type: "uint256" },
              { name: "witness", type: "PaymentIntent" },
          ],
          TokenPermissions: [
              { name: "token", type: "address" },
              { name: "amount", type: "uint256" },
          ],
          PaymentIntent: [
              { name: "from", type: "address" },
              { name: "to", type: "address" },
              { name: "value", type: "uint256" },
              { name: "validAfter", type: "uint256" },
              { name: "validBefore", type: "uint256" },
              { name: "nonce", type: "bytes32" },
              { name: "beneficiary", type: "address" },
              { name: "maxFee", type: "uint256" },
              { name: "requirePayeeSign", type: "bool" },
              { name: "attester", type: "address" },
          ],
      },
      primaryType: "PermitWitnessTransferFrom",
      message: {
          permitted: {
              token,
              amount: permittedAmount,
          },
          spender: circlePayment,
          nonce: permitNonce,
          deadline: permitDeadline,
          witness: {
              from: payerAccount.address,
              to: payee,
              value: amountTokens,
              validAfter,
              validBefore,
              nonce: intentNonce,
              beneficiary,
              maxFee: feeTokens,
              requirePayeeSign: false,
              attester: attesterAccount.address,
          },
      },
  });

  const permitStruct = {
      permitted: { token, amount: permittedAmount },
      nonce: permitNonce,
      deadline: permitDeadline,
  };

  const payerData = {
      permit: permitStruct,
      signature: payerSig,
  };

  const baseFee = await publicClient.getGasPrice();
  const maxPriorityFeePerGas = 2_000_000_000n; // 2 gwei tip
  const maxFeePerGas = baseFee + maxPriorityFeePerGas;

  const execArgs = [
    {
      from: payerAccount.address,
      to: payee,
      value: amountTokens,
      validAfter,
      validBefore,
      nonce: intentNonce,
      beneficiary,
      maxFee: feeTokens,
      requirePayeeSign: false,
      attester: attesterAccount.address,
    },
    payerData,
    "0x",
    feeTokens,
  ] as const;

  const { request } = await publicClient.simulateContract({
      address: circlePayment,
      abi: circlePaymentAbi,
      functionName: "execute",
      args: execArgs,
      account: attesterAccount,
  });

  const txHash = await walletClient.writeContract({
    address: circlePayment,
    abi: circlePaymentAbi,
    functionName: "execute",
    args: execArgs,
    account: attesterAccount,
    gas: request.gas,
    maxFeePerGas,
    maxPriorityFeePerGas,
  });
  console.log("payment tx:", txHash);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
