# agent-escrow

Agent task escrow + ERC-8004 reputation (hackathon MVP).

A buyer agent orders a task from an expert bot. The structured delivery criteria are frozen
on-chain as a hash and payment is escrowed in an ERC-20. A verifier bot checks the delivery and
either releases the funds (after user approval, or automatically in `approve_for_me` mode) or
refunds the buyer. Timeouts also refund. Every settlement writes the fulfillment record (task
type, amount, pass/fail, on time) to an ERC-8004 Reputation Registry.

> **Testnet only. Never use real funds or keys that hold real funds.** The contracts are unaudited,
> and the scripts refuse to run on any chain other than Monad testnet, Base Sepolia, and anvil.

- Product spec (source of truth): [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md)
- Contracts, state machine, hashing, reputation format, and agent integration:
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

```
Created → Agreed (spec frozen) → Funded → Delivered → Verified(pass/fail) → Released | Refunded
                                   └── timeout refund ──┘          (Disputed: reserved, not implemented)
```

## Layout

| Path | Contents |
| --- | --- |
| `contracts/TaskEscrow.sol` | Order state machine and ERC-20 custody; writes ERC-8004 feedback |
| `contracts/registries/` | Lean ERC-8004 `IdentityRegistry` (ERC-721) and `ReputationRegistry` |
| `contracts/libraries/FulfillmentFeedback.sol` | On-chain ERC-8004 feedback file (JSON data URI) |
| `contracts/mocks/MockUSDC.sol` | 6-decimal test token with open `mint` |
| `script/Deploy.s.sol` | Deploys the stack and writes `deployments/<chainId>.json` |
| `script/Demo.s.sol` | Runs the spec's "Guild logo, 5 USDC, 24h" order step by step |
| `script/demo-local.sh` | One-command local demo on anvil |
| `test/` | Unit, fuzz, and invariant tests |

## Quickstart

Requires [Foundry](https://getfoundry.sh) (CI pins v1.8.5) and `jq` (for the demo script).

```bash
git clone --recursive https://github.com/yikedu7/agent-escrow && cd agent-escrow
# already cloned without --recursive?  git submodule update --init --recursive
forge build
forge test                    # 123 tests
forge test --network monad    # same suite with Monad execution semantics
```

## One-command demo

```bash
./script/demo-local.sh
```

The script starts anvil (unless something is already listening on `:8545`) and deploys the
stack. It then runs four orders and prints the transaction hash of every step:

1. **Pass, user approval:** `register` ×3 (expert, buyer, verifier) → `createOrder` → `agree` →
   `fund` → `submitDelivery` → `release` → `approve`.
2. **Pass, `approve_for_me`:** the verifier's `release` pays the expert in the same transaction.
3. **Fail:** the verifier's `fail` refunds the buyer.
4. **Timeout:** the order is funded but never delivered. The script advances anvil's clock past
   the deadline and calls `refundExpired`.

The run ends with the expert's ERC-8004 summary for `design.logo`: 4 fulfillments, pass rate 50%.
Output excerpt:

```
== Pass, user approval: Created > Agreed > Funded > Delivered > Verified > Released ==
  0x7f15…564c  IdentityRegistry.register
  …
  0x070c…65ec  TaskEscrow.createOrder
  0xbb3f…e9b5  TaskEscrow.agree
  0xb8fe…6910  TaskEscrow.fund
  0xf9a8…0aeb  TaskEscrow.submitDelivery
  0xad5a…e413  TaskEscrow.release
  0x445a…e9f6  TaskEscrow.approve
```

## Deploy

Deployments are configured with environment variables (see [`.env.example`](.env.example); Forge
loads `.env` automatically). The chain is selected by the RPC alias in `foundry.toml`:
`monad_testnet`, `base_sepolia`, or `anvil`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PRIVATE_KEY` | — | Deployer key. Prefer a keystore: `cast wallet import deployer --interactive`, then pass `--account deployer` and leave this unset. |
| `DEFAULT_VERIFIER` | deployer | Protocol verifier bot address, used when an order names no verifier. Immutable. |
| `PAYMENT_TOKEN` | deploy MockUSDC | Existing ERC-20 to settle in. |
| `IDENTITY_REGISTRY` / `REPUTATION_REGISTRY` | deploy new | Reuse existing ERC-8004 registries. A reputation registry requires its identity registry. |
| `MOCK_USDC_MINT` / `MOCK_USDC_MINT_TO` | 0 / deployer | Initial mUSDC mint (6 decimals: `1000000000` = 1,000 mUSDC). |
| `WRITE_DEPLOYMENT` | `true` | Write `deployments/<chainId>.json` (addresses and start block) for the agents. |

Always do a dry run first (omit `--broadcast`): it simulates against the live chain and prints the
addresses and gas estimate.

### Monad testnet (primary)

Chain id `10143`. Get MON from the [faucet](https://faucet.monad.xyz). A full deploy is about 9.3M
gas, roughly 2 MON at current testnet fees. Explorers:
[MonadVision](https://testnet.monadvision.com) and [Monadscan](https://testnet.monadscan.com).
No canonical USDC is listed for Monad testnet, so leave `PAYMENT_TOKEN` empty to deploy MockUSDC.

```bash
DEFAULT_VERIFIER=0xYourVerifierBot \
forge script script/Deploy.s.sol --rpc-url monad_testnet --network monad \
  --account deployer --broadcast --slow \
  --verify --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/
```

To verify a contract later:
`forge verify-contract <address> contracts/TaskEscrow.sol:TaskEscrow --chain 10143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/`.

### Base Sepolia (fallback)

Chain id `84532`. Explorer: [BaseScan](https://sepolia.basescan.org). Get Sepolia ETH from any
Base Sepolia faucet. You can settle in Circle's test USDC
(`PAYMENT_TOKEN=0x036CbD53842c5426634e7929541eC2318f3dCF7e`, from
[faucet.circle.com](https://faucet.circle.com)) or leave it empty for MockUSDC.

```bash
DEFAULT_VERIFIER=0xYourVerifierBot \
forge script script/Deploy.s.sol --rpc-url base_sepolia \
  --account deployer --broadcast --slow \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

`ETHERSCAN_API_KEY` is an Etherscan V2 key, which works for BaseScan.

### Running the demo on a testnet

After deploying, run the same demo as the local one. You need three distinct testnet keys with gas:
`BUYER_PRIVATE_KEY`, `EXPERT_PRIVATE_KEY`, and `VERIFIER_PRIVATE_KEY`. The demo names the
verifier key's address as the order's verifier, so it does not have to be `DEFAULT_VERIFIER`. With
MockUSDC the buyer mints its own tokens. With Circle USDC, fund the buyer with at least 5 USDC
first.

```bash
SCENARIO=pass APPROVAL_MODE=user \
forge script script/Demo.s.sol --rpc-url monad_testnet --network monad --broadcast --slow
```

- `SCENARIO=fail` exercises the refund branch.
- `SCENARIO=timeout` stops at Funded. Call `refundExpired(orderId)` on the escrow once `deliverBy`
  (24h) has passed.
- Pass `EXPERT_AGENT_ID`, `BUYER_AGENT_ID`, and `VERIFIER_AGENT_ID` from the first run's logs to
  reuse the same agents.

Transaction hashes are listed in `broadcast/Demo.s.sol/<chainId>/run-latest.json`.

## Development

```bash
forge fmt --check && forge lint --deny warnings && forge build --sizes
FOUNDRY_PROFILE=ci forge test        # more fuzz and invariant runs, as in CI
forge test --gas-report
```

CI (`.github/workflows/ci.yml`) runs format, lint, build, and the full test suite on both the
`ethereum` and `monad` network profiles.

The TypeScript buyer agent, expert bot, and verifier bot (viem) come in the next PR. Privy server
wallets for the verifier and deployer come later. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#off-chain-agents-next-pr-typescript--viem) for the
integration contract.
