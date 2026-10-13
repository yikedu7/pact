# Pact

Agent task escrow + ERC-8004 on Monad.

**Pact** is on-chain escrow for agent-to-agent work. A personal agent can hire an expert bot:
they negotiate terms off-chain, then payment is held in escrow until the buyer confirms delivery.
Negotiation and signing run through pluggable suppliers; **Cursor Automations** and **Grok Bot**
are first host adapters, not the product.

A buyer agent orders a task from an expert bot. The structured delivery criteria are frozen
on-chain as a hash and payment is escrowed in an ERC-20. The buyer confirms the delivery:
`createOrder` sets `verifier` to the buyer address, and that same wallet later calls `release`
or `fail` (and `approve` when `approval_mode` is `user`). Timeouts also refund. Every settlement
writes the fulfillment record (task type, amount, pass/fail, on time) to an ERC-8004 Reputation Registry.

> **Testnet only. Never use real funds or keys that hold real funds.** The contracts are unaudited,
> and the scripts refuse to run on any chain other than Monad testnet, Base Sepolia, and anvil.

| Layer | In this repo | Responsibility |
| --- | --- | --- |
| **Protocol core** | `contracts/`, `deployments/` | `TaskEscrow`, MockUSDC, ERC-8004 registries, JCS `specHash` |
| **NegotiationChannel** | `relay/` (+ future `agents/` adapters) | `guild.negotiate/v0.1` over HTTPS; public [`guild-relay`](relay/README.md) holds webhook keys so creators share only `/guild-relay/<botId>` |
| **ExecutionRuntime** | `agents/` | Buyer / expert / verifier skills → viem txs via a wallet adapter |

**Hackathon demo (2026-10-13):** cross-bot negotiate via the public relay, then Monad testnet order
**2** released (5 USDC, `ApproveForMe`). Record, tx hashes, and `specHash` notes:
[`docs/demos/2026-10-13-dfcb9220/`](docs/demos/2026-10-13-dfcb9220/). That run used an older
three-party layout. New orders do not.

**Path A demo is two wallets.** The shared Path A Privy app stays, but the buyer bot holds only
the buyer wallet id and the expert bot holds only the expert wallet id. After negotiate accept,
the buyer creates and later funds; the expert agrees and later delivers; the buyer releases or
fails. Pass the next step as a `guild.escrow/v0.1` cue (CLI file or `POST` to `guild-relay/<botId>`).
There is no verifier bot on this path. The Monad deployment's `defaultVerifier`
`0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8` is not used for new orders. Path B is the public
skill with two local EOAs. See [Wallet paths](#wallet-paths).

**Path A skills (no secrets in git):** [buyer](docs/skills/guild-negotiate-buyer/SKILL.md) and
[expert](docs/skills/guild-negotiate-expert/SKILL.md). Public `guild-relay` only (SendToAgent is
debug-only). Secret card → `_admin/register` → shared Privy app → create or reuse the role
wallet → faucet → role-split signing.

**Not done (MVP):** real delivery verification, cross-account human buyer, bot directory / friends,
Tunnel.

- Product spec (source of truth): [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md)
- Contracts, state machine, hashing, reputation format, and agent integration:
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- Off-chain signing with Privy server wallets (demo path: buyer and expert only):
  [`docs/PRIVY_NOTES.md`](docs/PRIVY_NOTES.md)
- Path A bot skills (relay, secret-card names, role-split commands):
  [`docs/skills/guild-negotiate-buyer/SKILL.md`](docs/skills/guild-negotiate-buyer/SKILL.md),
  [`docs/skills/guild-negotiate-expert/SKILL.md`](docs/skills/guild-negotiate-expert/SKILL.md)

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
| `script/Demo.s.sol` | Optional local Foundry replay (two keys, verifier = buyer). Not Path A |
| `script/demo-local.sh` | Optional one-command local replay on anvil (Foundry). Not Path A |
| `agents/` | TypeScript buyer / expert commands (viem + Privy or local keys) |
| `docs/skills/guild-negotiate-buyer/` | Path A buyer skill: public relay, buyer wallet, create / fund / release |
| `docs/skills/guild-negotiate-expert/` | Path A expert skill: public relay, expert wallet, agree / deliver |
| `templates/` | Path B public skills (local EOAs, no Path A Privy app secret). Verifier template is archived |
| `agents/script/demo-local.sh` | Deploy on anvil + run the logo demo via the agents CLI |
| `relay/` | Supabase Edge Function `guild-relay` (public delivery proxy; no secrets in git) |
| `docs/demos/` | Sanitized end-to-end demo records (negotiation + on-chain) |
| `test/` | Unit, fuzz, and invariant tests |

## Quickstart

Requires [Foundry](https://getfoundry.sh) (CI pins v1.8.5) and `jq` (for the demo script).

```bash
git clone --recursive https://github.com/yikedu7/pact && cd pact
# already cloned without --recursive?  git submodule update --init --recursive
forge build
forge test                    # 123 tests
forge test --network monad    # same suite with Monad execution semantics
```

## One-command local replay (not Path A)

```bash
./script/demo-local.sh
```

This Foundry script is an optional local replay. It is not the Path A critical path, which is
the split TypeScript commands below. The script starts anvil (unless something is already
listening on `:8545`) and deploys the stack. It then runs four orders with two keys (buyer and
expert). `createOrder.verifier` is the buyer address. The buyer signs `release` / `fail`.

1. **Pass, user approval:** `register` ×2 (expert, buyer) → `createOrder` → `agree` →
   `fund` → `submitDelivery` → buyer `release` → buyer `approve`.
2. **Pass, `approve_for_me`:** the buyer's `release` pays the expert in the same transaction.
3. **Fail:** the buyer's `fail` refunds the buyer.
4. **Timeout:** the order is funded but never delivered. The script advances anvil's clock past
   the deadline and calls `refundExpired`.

The run ends with the expert's ERC-8004 summary for `design.logo`: 4 fulfillments, pass rate 50%.
Output excerpt:

```
== Pass, user approval: Created > Agreed > Funded > Delivered > Verified > Released ==
  0x7f15…564c  IdentityRegistry.register (expert, then buyer)
  …
  0x070c…65ec  TaskEscrow.createOrder   (verifier = buyer)
  0xbb3f…e9b5  TaskEscrow.agree         (expert)
  0xb8fe…6910  TaskEscrow.fund          (buyer)
  0xf9a8…0aeb  TaskEscrow.submitDelivery (expert)
  0xad5a…e413  TaskEscrow.release       (buyer)
  0x445a…e9f6  TaskEscrow.approve       (buyer, user mode)
```

## Deploy

Deployments are configured with environment variables (see [`.env.example`](.env.example); Forge
loads `.env` automatically). The chain is selected by the RPC alias in `foundry.toml`:
`monad_testnet`, `base_sepolia`, or `anvil`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PRIVATE_KEY` | — | Deployer key. Prefer a keystore: `cast wallet import deployer --interactive`, then pass `--account deployer` and leave this unset. |
| `DEFAULT_VERIFIER` | deployer | Immutable fallback only when an order passes `verifier = 0`. Demo orders pass the buyer address. |
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

After deploying, the optional Foundry replay uses two distinct testnet keys with gas:
`BUYER_PRIVATE_KEY` and `EXPERT_PRIVATE_KEY`. The order's verifier is the buyer address, not
`DEFAULT_VERIFIER`. With MockUSDC the buyer mints its own tokens. With Circle USDC, fund the
buyer with at least 5 USDC first. Path A on a testnet uses the split commands in
[Wallet paths](#wallet-paths), not this one-process script.

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

Off-chain agents live in [`agents/`](agents/). The demo critical path is three commands, two
wallets: buyer `createOrder` + token approve, expert `agree`, buyer `fund`, expert
`submitDelivery`, buyer `release` or `fail` (and `approve` when `approval_mode` is `user`).
Criteria JSON is hashed with RFC 8785 (JCS), matching `TaskEscrow.hashSpec` and the pinned
vector in `test/Demo.t.sol`. `npm run demo` is an optional local-dev replay with local EOAs
only. It refuses to run when Privy app secrets are set.

**Signing** goes through a wallet adapter ([`agents/src/wallet/adapter.ts`](agents/src/wallet/adapter.ts)):
`getAddress()`, `sendEscrowStep` (today's `TxSender.send`), optional `createIfNeeded()`, and
`fundHint()` (a faucet link). Vendors: `PrivyShared` (path A), `LocalEoa` (path B),
`UserAaSession` (not built). Escrow should depend on that shape, not on one vendor. The CLI
still picks Privy when `PRIVY_APP_ID` and `PRIVY_APP_SECRET` are set, and local keys otherwise.
See [`docs/PRIVY_NOTES.md`](docs/PRIVY_NOTES.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

```bash
cd agents && npm ci && npm test && npm run typecheck
```

## Wallet paths

Two ways to sign. Both use the same two-wallet handoff. Neither path puts a Path A
`PRIVY_APP_SECRET` in the public template. Neither path requires a verifier wallet.

### Path A — official Pact demo (`PrivyShared`)

The hosted bots share one Privy **app** (Path A demo). **Users do not configure Privy.** Each bot
receives only its own wallet id: the buyer bot gets `PRIVY_WALLET_BUYER_ID`, the expert bot
gets `PRIVY_WALLET_EXPERT_ID`. A buyer process does not call Privy with the expert wallet id.
`PRIVY_WALLET_VERIFIER_*` is not part of this path. Operators bootstrap the two wallets
(`POST /v1/wallets`, `User-Agent: PrivyNodeJS/1.0`) and copy one id onto each bot. Do not
commit those secrets. See [`docs/PRIVY_NOTES.md`](docs/PRIVY_NOTES.md).

```bash
cd agents && npm run wallets:bootstrap
```

### Path B — public skill / self-hosted (`LocalEoa`)

[`templates/`](templates/) is this path. **Do not ship the Path A Privy app secret.** Generate two
throwaway testnet EOAs (buyer, expert). On chain `31337`, anvil's buyer and expert default
keys are used when the env vars are unset.

```bash
cast wallet new    # buyer, then expert. Never a key that holds real funds.
export BUYER_PRIVATE_KEY=0x…
export EXPERT_PRIVATE_KEY=0x…
cast wallet address --private-key "$BUYER_PRIVATE_KEY"
```

Leave `PRIVY_APP_ID` and `PRIVY_APP_SECRET` empty so the CLI stays on `LocalEoa`. Fund each
address with testnet gas, then run the handoff below:

| Chain | `fundHint` |
| --- | --- |
| Monad testnet `10143` | [faucet.monad.xyz](https://faucet.monad.xyz) |
| Base Sepolia `84532` | [Base Sepolia faucet](https://portal.cdp.coinbase.com/products/faucet) |
| anvil `31337` | Prefunded dev accounts |

Also fund the buyer with the payment token when it is not MockUSDC (the demo mints MockUSDC).

`UserAaSession` (social-login account abstraction) is a follow-up. ZeroDev / a paymaster is an
optional UX upgrade on that later path, not the self-host default.

### After accept (both paths)

Chain order is fixed, so each command does the step that role can sign and then stops. The
next bot receives a `guild.escrow/v0.1` cue (a JSON file, or `POST` to
`guild-relay/<botId>` when `GUILD_NEXT_RELAY_URL` is set). If the on-chain status is wrong,
the command stops and does not use the other role's key.

| Command | Wallet | What it signs | Next cue |
| --- | --- | --- | --- |
| `escrow:buyer-create-fund` on an accept | Buyer | token `approve` (+ mint on MockUSDC) and `createOrder` (`verifier` = buyer) | `expert-agree` |
| `escrow:expert-agree-deliver` | Expert | `agree` when status is Created | `buyer-fund` |
| `escrow:buyer-create-fund` on a `buyer-fund` cue | Buyer | `fund` when status is Agreed | `expert-deliver` (or `done` on timeout) |
| `escrow:expert-agree-deliver` | Expert | `submitDelivery` when status is Funded | `buyer-release` |
| `escrow:buyer-release` | Buyer | `release` or `fail`; `approve` as well when the order is `user` mode | `done` |

```bash
cd agents && npm run escrow:buyer-create-fund -- ../accept.json
cd agents && npm run escrow:expert-agree-deliver -- ../cue.json
cd agents && npm run escrow:buyer-create-fund -- ../cue.json
cd agents && npm run escrow:expert-agree-deliver -- ../cue.json
cd agents && npm run escrow:buyer-release -- ../cue.json
```

`accept.json` is the accept envelope or a negotiation record whose `latest` message is that
accept (`docs/demos/2026-10-13-dfcb9220/`). Approval mode comes from the frozen task.
`SCENARIO=pass|fail|timeout` is only a demo knob, and the cue carries it forward.
`npm run demo` and `script/Demo.s.sol` are optional local-dev replays, not this path.

Caps (USDC base units, 6 decimals) apply before any transaction:

| Variable | Default | Meaning |
| --- | --- | --- |
| `GUILD_TX_AMOUNT_CAP` | `100000000` (100 USDC) | Maximum one order can escrow |
| `GUILD_DAILY_AMOUNT_CAP` | `500000000` (500 USDC) | UTC-day cumulative funds |

A cap breach, an empty gas balance, or a failed simulation throws a short error and does not
broadcast. The 5 USDC logo demo fits the defaults.

### Wallet adapter

```ts
interface EscrowWallet {
  getAddress(): Address;
  sendEscrowStep(tx): Promise<Hex>;
  createIfNeeded?(): Promise<void>;
  fundHint(): string;
}
```

| Vendor | Path | In this PR |
| --- | --- | --- |
| `PrivyShared` | A, official demo bot | `createPrivySender` + `ensurePrivyRoleWallets` |
| `LocalEoa` | B, public skill | `createLocalSender` |
| `UserAaSession` | later | not implemented |

### Local anvil (optional replay, not Path A)

```bash
./agents/script/demo-local.sh
```

### Against a deployed testnet

1. Deploy with Foundry (`deployments/<chainId>.json` is written automatically). The source
   allows `verifier` to be the buyer. The Monad deployment already on chain
   (`defaultVerifier` `0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8`) still has the older check
   and will revert until it is replaced. The role commands simulate first and stop without
   broadcasting when the chain would revert. Do not pass `0x7E70…` on new orders.
2. Fund the buyer and expert wallets with native gas; mint or transfer MockUSDC to the buyer.
3. `createOrder` sets `verifier` to the buyer address. `DEFAULT_VERIFIER` is only the
   contract fallback when an order passes the zero address. The demo commands do not pass zero.

**Monad testnet** — chain id `10143`, CAIP-2 `eip155:10143` (verify in Privy before demo day):

```bash
export RPC_URL="$MONAD_TESTNET_RPC"
export CHAIN_ID=10143
export EXPERT_AGENT_ID=1
# Buyer bot: PRIVY_APP_ID, PRIVY_APP_SECRET, PRIVY_WALLET_BUYER_ID, PRIVY_WALLET_BUYER_ADDRESS
cd agents && npm run escrow:buyer-create-fund -- ../accept.json
# Expert bot, same app id/secret, only PRIVY_WALLET_EXPERT_*:
cd agents && npm run escrow:expert-agree-deliver -- ../cue.json
```

**Base Sepolia fallback** — chain id `84532`, CAIP-2 `eip155:84532`:

```bash
export RPC_URL="$BASE_SEPOLIA_RPC"
export CHAIN_ID=84532
export PRIVY_CAIP2=eip155:84532
```

CI runs `agents` typecheck and unit tests without live Privy. Set `EXPERT_AGENT_ID` and
`BUYER_AGENT_ID` to reuse agents from a previous run. `BUYER_AGENT_ID` may be `0`.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#wallets-privy-server-wallets) for the full
role-to-call mapping.
