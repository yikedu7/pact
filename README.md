# agent-escrow

Agent task escrow + ERC-8004 reputation (hackathon MVP).

A buyer agent orders a task from an expert bot. The structured delivery criteria are frozen
on-chain as a hash and payment is escrowed in an ERC-20. A verifier bot checks the delivery and
either releases the funds (after user approval, or automatically in `approve_for_me` mode) or
refunds the buyer. Timeouts also refund. Every settlement writes the fulfillment record (task
type, amount, pass/fail, on time) to an ERC-8004 Reputation Registry.

> **Testnet only. Never use real funds or keys that hold real funds.** The contracts are unaudited,
> and the scripts refuse to run on any chain other than Monad testnet, Base Sepolia, and anvil.

Guild is **on-chain escrow for agent task deals**. Negotiation and signing run through pluggable
suppliers; **Cursor Automations** and **Grok Bot** are first host adapters, not the product.

| Layer | In this repo | Responsibility |
| --- | --- | --- |
| **Protocol core** | `contracts/`, `deployments/` | `TaskEscrow`, MockUSDC, ERC-8004 registries, JCS `specHash` |
| **NegotiationChannel** | `relay/` (+ future `agents/` adapters) | `guild.negotiate/v0.1` over HTTPS; public [`guild-relay`](relay/README.md) holds webhook keys so creators share only `/guild-relay/<botId>` |
| **ExecutionRuntime** | `agents/` | Buyer / expert / verifier skills → viem txs (Privy or local keys) |

**Hackathon demo (2026-10-13):** cross-bot negotiate via the public relay, then Monad testnet order
**2** released (5 USDC, `ApproveForMe`). Record, tx hashes, and `specHash` notes:
[`docs/demos/2026-10-13-dfcb9220/`](docs/demos/2026-10-13-dfcb9220/).

**Next:** bot self-sign (embed the same Privy path in the agent host; no RelayHost handoff).

**Not done (MVP):** real delivery verification, cross-account human buyer, bot directory / friends,
Tunnel.

- Product spec (source of truth): [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md)
- Contracts, state machine, hashing, reputation format, and agent integration:
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Off-chain signing with Privy server wallets (one per role: buyer, expert, verifier):
  [`docs/PRIVY_NOTES.md`](docs/PRIVY_NOTES.md)

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
| `script/demo-local.sh` | One-command local demo on anvil (Foundry) |
| `agents/` | TypeScript buyer / expert / verifier agents (viem + Privy or local keys) |
| `agents/script/demo-local.sh` | Deploy on anvil + run the logo demo via the agents CLI |
| `relay/` | Supabase Edge Function `guild-relay` (public delivery proxy; no secrets in git) |
| `docs/demos/` | Sanitized end-to-end demo records (negotiation + on-chain) |
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

## TypeScript agents (logo demo)

Off-chain agents live in [`agents/`](agents/). They mirror `script/Demo.s.sol`: register ERC-8004
agents, `createOrder` → `agree` → `fund` → `submitDelivery` → `release`/`fail`, then buyer
`approve` when `approval_mode=user`. Criteria JSON is hashed with RFC 8785 (JCS), matching
`TaskEscrow.hashSpec` and the pinned vector in `test/Demo.t.sol`.

**Signing:** with `PRIVY_APP_ID`, `PRIVY_APP_SECRET`, and the three `PRIVY_WALLET_*_ID` values set,
transactions go through Privy `eth_sendTransaction` (see [`docs/PRIVY_NOTES.md`](docs/PRIVY_NOTES.md)).
You must also set `PRIVY_WALLET_*_ADDRESS` for gas estimation and `PRIVY_CAIP2` once Privy's CAIP-2
for Monad testnet is confirmed. Without Privy env vars, the CLI uses local private keys (anvil
defaults on chain `31337`).

```bash
cd agents && npm ci && npm test && npm run typecheck
```

### Local anvil (one command)

```bash
./agents/script/demo-local.sh
```

### Against a deployed testnet

1. Deploy with Foundry (`deployments/<chainId>.json` is written automatically).
2. Fund the three role wallets with native gas; mint or transfer MockUSDC to the buyer.
3. Set `DEFAULT_VERIFIER` at deploy time to the Privy verifier address (or pass that address in
   `OrderParams.verifier` from the buyer agent).

**Monad testnet** — chain id `10143`, CAIP-2 `eip155:10143` (verify in Privy before demo day):

```bash
export RPC_URL="$MONAD_TESTNET_RPC"
export CHAIN_ID=10143
# Privy + wallet ids, or BUYER_/EXPERT_/VERIFIER_PRIVATE_KEY for a dry key-based smoke test
export SCENARIO=pass APPROVAL_MODE=approve_for_me
cd agents && npm run demo
```

**Base Sepolia fallback** — chain id `84532`, CAIP-2 `eip155:84532`:

```bash
export RPC_URL="$BASE_SEPOLIA_RPC"
export CHAIN_ID=84532
export PRIVY_CAIP2=eip155:84532
cd agents && npm run demo
```

CI runs `agents` typecheck and unit tests without live Privy. Set `EXPERT_AGENT_ID`,
`BUYER_AGENT_ID`, and `VERIFIER_AGENT_ID` to reuse agents from a previous run.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#wallets-privy-server-wallets) for the full
role-to-call mapping.
