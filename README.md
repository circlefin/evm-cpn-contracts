# CPN Contracts

Onchain payment settlement for Circle Payments Network:

* **Create2Factory** — deterministic deployments via `CREATE2`.
* **PaymentSettlement** — EIP-712 attested payments using Uniswap Permit2 witness transfers, fee split, nonce replay-protection, pausable, rescuable, and configurable roles.

---

## Prerequisites

### Setup

1. Run `git submodule update --init --recursive` to update/download all libraries.
2. Run `yarn install` to install any additional dependencies.
3. Run `curl -L https://foundry.paradigm.xyz | bash` and follow the outputted instructions to source env file. 
4. Run `foundryup`

### VS Code Setup

* Install Solidity extension: [https://marketplace.visualstudio.com/items?itemName=juanblanco.solidity](https://marketplace.visualstudio.com/items?itemName=juanblanco.solidity)
* Open a `.sol` file → **Solidity: Change global compiler version (Remote)** → select **0.8.24**
* (Optional) Install Solhint: [https://marketplace.visualstudio.com/items?itemName=idrabenia.solidity-solhint](https://marketplace.visualstudio.com/items?itemName=idrabenia.solidity-solhint)

---

## Testing

### Unit tests

```bash
yarn test
```

### Test Coverage
Run `yarn coverage` to generate a coverage report.

### Gas tests

Gas benchmarks live under `test/gas/` (e.g., `PaymentSettlementGas.t.sol`).

```bash
yarn benchmark:write
```

### Lint
Run `yarn lint` to lint all `.sol` files in the `src` and `test` directories. Run `yarn format:check` and `yarn format:write` to check for, and fix formatting issues, respectively.

### Static analysis (optional)

* Slither (recommended):

  ```bash
  slither .
  ```

---

## Deployment

> Use a funded deployer key for the target network. Keep `solc`/optimizer settings identical across simulations and broadcast.

### Create2Factory

Deploy once per network.

```bash
export BLOCKCHAIN_RPC_URL=...
export DEPLOYER_PRIVATE_KEY=0x...
export CREATE2_FACTORY_SALT=...

forge script script/deploy/DeployCreate2Factory.s.sol \
  --rpc-url $BLOCKCHAIN_RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
```

### PaymentSettlement

Initialize with Permit2 + roles + attester set.
**Required inputs** (via env or script args):

Example:

```bash
export BLOCKCHAIN_RPC_URL=...
export DEPLOYER_PRIVATE_KEY=0x...
export DEPLOYER_ADDRESS=0x...
export CREATE2_FACTORY_CONTRACT_ADDRESS=0x...
export CIRCLE_PAYMENT_SALT=...
export CIRCLE_PAYMENT_OWNER_ADDRESS=0x...
export PERMIT2_CONTRACT_ADDRESS=0x...
export CIRCLE_PAYMENT_RESCUER_ADDRESS=0x...
export CIRCLE_PAYMENT_PAUSER_ADDRESS=0x...
export CIRCLE_PAYMENT_CONFIGURATOR_ADDRESS=0x...
export CIRCLE_PAYMENT_ATTESTER_COUNT=1
export CIRCLE_PAYMENT_ATTESTER_0 = ...

forge script script/deploy/DeployPaymentSettlement.s.sol \
  --rpc-url $BLOCKCHAIN_RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
```

---

## Create2 address prediction

`Create2Factory.getAddress(salt, bytecode)` returns the deterministic address for the given salt + creation bytecode. Ensure constructor args are ABI-encoded into `bytecode` before predicting.

---

## Repository layout

```
src/                    # Solidity contracts (Create2Factory, PaymentSettlement, utils)
script/deploy/          # Forge deployment scripts
test/                   # Unit & gas tests
gas/script/             # Helper TS/JS for gas estimation
```

---

## Security

Do not open public issues for vulnerabilities. Report privately via the channel in `SECURITY.md`.

---

## License

Apache 2.0. See `LICENSE` and additional notices in `NOTICES`.
