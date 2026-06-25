# CPN Contracts

Onchain payment settlement for Circle Payments Network:

* **Create2Factory** — deterministic deployments via `CREATE2`.
* **PaymentSettlement** — EIP-712 attested payments using Uniswap Permit2 witness transfers, fee split, nonce replay-protection, pausable, rescuable, and configurable roles.
* **PaymentSettlementV2** — second-generation settlement contract: dual-amount settlement (separate payer contribution and payee settlement amount), optional shortfall coverage by an incentive provider, cumulative refund accounting with per-party caps, and enum-based nonce lifecycle tracking. Shares the same Permit2, role, pause, and rescue primitives as V1.

---

## Prerequisites

### Setup

1. Run `git submodule update --init --recursive` to update/download all libraries.
2. Run `yarn install` to install any additional dependencies.
3. Run `curl -L https://foundry.paradigm.xyz | bash` and follow the outputted instructions to source env file.
4. Run `foundryup`.

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

### Lint
Run `yarn lint` to lint all `.sol` files in the `src` and `test` directories. Run `yarn format:check` and `yarn format:write` to check for, and fix formatting issues, respectively.

---

## Create2 address prediction

`Create2Factory.getAddress(salt, bytecode)` returns the deterministic address for the given salt + creation bytecode. Ensure constructor args are ABI-encoded into `bytecode` before predicting.

---

## Repository layout

```
src/                    # Solidity contracts (Create2Factory, PaymentSettlement, PaymentSettlementV2, utils)
test/                   # Unit tests
```

---

## Security

Do not open public issues for vulnerabilities. Report privately via the channel in `SECURITY.md`.

---

## License

Apache 2.0. See `LICENSE` and additional notices in `NOTICES`.
