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
