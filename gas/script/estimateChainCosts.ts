/**
 * Copyright 2025 Circle Internet Group, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
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
 */
import * as fs from 'fs';
import * as path from 'path';
import * as dotenv from 'dotenv';
import {
    serializeTransaction,
    bytesToHex,
    hexToBytes
} from "viem";
import crypto from 'crypto';
import {calldataGas} from './fee';

dotenv.config();

interface GasUsageSummary {
    gasUsed: number;
    txCalldata: `0x${string}`;
    txToAddress?: `0x${string}`;
    entryPointVersion: string;
}
interface ChainCostSummary {
    gasUsed: number;
    l1FeeNativeTokens?: number;
    totalNativeTokensUsed: number;
    totalPriceUSD: number;
}
interface ChainPriceConfig {
    gasPriceGwei: number
    nativeTokenPriceUSD: number
    getL1Fee?(serializedTxBytes: string): number

    // Allow any additional properties
    [key: string]: any;
}

const GWEI_PER_ETH = 1000000000;

// Alchemy EntryPoint v0.7 addresses, taken from https://docs.alchemy.com/reference/account-abstraction-faq#entrypoint
const ENTRY_POINT_V07_ADDRESS = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
const ENTRY_POINT_V06_ADDRESS = "0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789";

// Update below values to the latest ones to get the most accurate measurements.
const ETH_MAINNET_PRICE_CONFIG: ChainPriceConfig = {
    gasPriceGwei: 2.2,
    nativeTokenPriceUSD: 2720,
}
const POLYGON_MAINNET_PRICE_CONFIG: ChainPriceConfig = {
    gasPriceGwei: 30,
    nativeTokenPriceUSD: 0.3
}
const ARB_ESTIMATED_ETH_BLOB_GAS_PRICE = 16;
const ARB_MAINNET_PRICE_CONFIG: ChainPriceConfig = {
    gasPriceGwei: 0.01,

    // ETH (bridged) is used to pay for transactions on Arbitrum. This is different from 
    // the price of the ARB governance token.
    nativeTokenPriceUSD: ETH_MAINNET_PRICE_CONFIG.nativeTokenPriceUSD,

    getL1Fee: function(serializedTx: `0x${string}`) {
        const estimatedL1BlobBytes = Number(calldataGas(hexToBytes(serializedTx))) / 16;
        const estimatedL1Fee = estimatedL1BlobBytes * ARB_ESTIMATED_ETH_BLOB_GAS_PRICE;

        return estimatedL1Fee / GWEI_PER_ETH;
    }
}

function main() {
    fs.readdirSync(process.env.GAS_RESULTS_FOLDER!).forEach(file => {
        if (file.slice(-5) != '.json') {
            return
        }
        const fullFilePath = path.join(process.env.GAS_RESULTS_FOLDER!, file);
        const fileContents = JSON.parse(fs.readFileSync(fullFilePath, 'utf8'));
        const chainCosts = computeChainCosts(fileContents);
        if (!chainCosts.size) {
            return
        }

        // Save the results
        const finalRes = {
            "chainPriceConfigs": {
                "ETH": ETH_MAINNET_PRICE_CONFIG,
                "POLYGON": POLYGON_MAINNET_PRICE_CONFIG,
                "ARB": ARB_MAINNET_PRICE_CONFIG,
            },
            "testCases": Object.fromEntries(chainCosts)
        }
        const outPath = path.join(process.env.CHAIN_COSTS_FOLDER!, file);
        fs.writeFileSync(outPath, JSON.stringify(finalRes, null, 2));
    });
}
main();

// For each object, compute the estimated cost for each chain based on 
//  chain price configuration.
function computeChainCosts(gasUsageSummaries: any) {
    let res: Map<string, any> = new Map();
    for (let testCase in gasUsageSummaries) {
        let curCaseCosts: Map<string, ChainCostSummary> = new Map();

        const gasUsageSummary: GasUsageSummary = gasUsageSummaries[testCase];
        if (!gasUsageSummary.gasUsed || !gasUsageSummary.txCalldata) {
            console.log(`Skipping cost analysis for test case "${testCase}" due to missing data...`);
            continue;
        }

        // For calculating L1 fee portion for L2s
        curCaseCosts.set("ETH", computeChainCost(ETH_MAINNET_PRICE_CONFIG, gasUsageSummary));
        curCaseCosts.set("POLYGON", computeChainCost(POLYGON_MAINNET_PRICE_CONFIG, gasUsageSummary));
        curCaseCosts.set("ARB", computeChainCost(ARB_MAINNET_PRICE_CONFIG, gasUsageSummary));

        res.set(testCase, Object.fromEntries(curCaseCosts));
    }
    return res
}

function computeChainCost(chainPriceConfig: ChainPriceConfig, gasUsageSummary: GasUsageSummary) {
    // @ts-ignore
    let res: ChainCostSummary = {
        gasUsed: gasUsageSummary.gasUsed, 
        totalNativeTokensUsed: gasUsageSummary.gasUsed * chainPriceConfig.gasPriceGwei,
    }
    if (chainPriceConfig.getL1Fee) {
        const mockSerializedTx = serializeMockTransaction(gasUsageSummary);

        res.l1FeeNativeTokens = chainPriceConfig.getL1Fee(mockSerializedTx)
        res.totalNativeTokensUsed += res.l1FeeNativeTokens
    }

    res.totalNativeTokensUsed = res.totalNativeTokensUsed / GWEI_PER_ETH    // Convert from Gwei
    res.totalPriceUSD = res.totalNativeTokensUsed * chainPriceConfig.nativeTokenPriceUSD
    return res
}

// Serializes a dummy transaction with mock values for all parts except the to address and data.
function serializeMockTransaction(gasUsageSummary: GasUsageSummary) {
    let toAddress = gasUsageSummary.txToAddress;
    if (!toAddress) {
        switch (gasUsageSummary.entryPointVersion) {
            case "0.6":
                toAddress = ENTRY_POINT_V06_ADDRESS
                break;
            case "0.7":
                toAddress = ENTRY_POINT_V07_ADDRESS
                break;
            default:
                console.log("Warning: unable to determine toAddress while serializing mock transaction. Using random address.")
                toAddress = bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
        }
    }

    return serializeTransaction(
        {
          to: toAddress,
          value: 0n,
          data: gasUsageSummary.txCalldata,
          nonce: 39826,
          gas: 26576n,
          type: "eip1559",
          maxFeePerGas: 12700000n,
          maxPriorityFeePerGas: 0n,
          chainId: 42161,
        },
        {
          r: "0x28ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276",
          s: "0x67cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83",
          v: BigInt(37),
        },
    );
}
