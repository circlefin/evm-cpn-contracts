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

import {
    ByteArray,
} from "viem";

// Matches https://www.npmjs.com/package/@eth-optimism/core-utils?activeTab=code (see file /@eth-optimism/core-utils/dist/optimism/fees.js)
// Not directly importing calldataGas function from "@eth-optimism/core-utils" because that results in importing a vulnerable dependency (fails PR check).
export const calldataGas = (bytes: ByteArray): bigint => {
    const { zeros, ones } = zeroesAndOnes(bytes)
    return zeros * 4n + ones * 16n
}
  
const zeroesAndOnes = (bytes: ByteArray): { zeros: bigint, ones: bigint } => {
    let zeros = 0n
    let ones = 0n
    for (const byte of bytes) {
      if (byte === 0) {
        zeros++
      } else {
        ones++
      }
    }
    return { zeros, ones }
}
