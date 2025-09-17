# evm-cpn-contracts

The repository for the smart contracts used by Circle Payment Platform.

This repository includes support for Foundry frameworks. All code / tests / scripts should be built on Foundry. 

## Setup
1. Run `git submodule update --init --recursive` to update/download all libraries.
2. Run `yarn install` to install any additional dependencies.
3. Run `curl -L https://foundry.paradigm.xyz | bash` and follow the outputted instructions to source env file. 
4. Run `foundryup`

## Development

### Lint
Run `yarn lint` to lint all `.sol` files in the `src` and `test` directories. Run `yarn format:check` and `yarn format:write` to check for, and fix formatting issues, respectively.

### Test
To run tests using Foundry, follow the steps below:
1. Run `yarn build`
2. Run `yarn test`

### Test Coverage
Run `yarn coverage` to generate a coverage report.