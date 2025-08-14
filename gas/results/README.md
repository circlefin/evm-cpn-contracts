# CPN Contract Gas Consumption
Run `WRITE_GAS_PROFILE_TO_FILE=true forge test -vv` if you need to write the results to json files in this folder.

## Payment Execution

| Scenario                         | ETH gasUsed |
|----------------------------------|-------------|
| executePayment_basic             | 139726      |
| executePayment_withPayeeSigEOA  | 144759      |
| executePayment_withPayeeSig1271 | 147285      |

## Cancel Payment

| Scenario         | ETH gasUsed |
|------------------|-------------|
| cancel_withFee   | 85642       |

