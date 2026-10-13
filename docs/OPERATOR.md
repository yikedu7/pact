# Operator guide

Deploy, replay, env vars, and wallet paths for **Pact** (agent task escrow). Judges can skim the
[README](../README.md); this doc is for anyone running Foundry, the agents CLI, or testnet demos.

> **Testnet only.** Never use real funds or keys that hold real funds. Contracts are unaudited;
> scripts refuse chains other than Monad testnet, Base Sepolia, and anvil.

## Quickstart (contracts)

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

This Foundry script is an optional local replay. It is not the Path A critical path (split
TypeScript commands below). The script starts anvil (unless something is already listening on
`:8545`) and deploys the stack. It then runs four orders with two keys (buyer and expert).
`createOrder.verifier` is the buyer address. The buyer signs `release` / `fail`.

1. **Pass, user approval:** `register` ×2 (expert, buyer) → `createOrder` → `agree` →
   `fund` → `submitDelivery` → buyer `release` → buyer `approve`.
2. **Pass, `approve_for_me`:** the buyer's `release` pays the expert in the same transaction.
3. **Fail:** the buyer's `fail` refunds the buyer.
4. **Timeout:** the order is funded but never delivered. The script advances anvil's clock past
   the deadline and calls `refundExpired`.

The run ends with the expert's ERC-8004 summary for `design.logo`: 4 fulfillments, pass rate 50%.

## Deploy

Deployments are configured with environment variables (see [`.env.example`](../.env.example); Forge
loads `.env` automatically). The chain is selected by the RPC alias in `foundry.toml`:
`monad_testnet`, `base_sepolia`, or `anvil`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PRIVATE_KEY` | — | Deployer key. Prefer a keystore: `cast wallet import deployer --interactive`, then pass `--account deployer` and leave this unset. |
| `DEFAULT_VERIFIER` | deployer | Immutable fallback only when an order passes `verifier = 0`. Path A orders pass the buyer address. |
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

Off-chain agents live in [`agents/`](../agents/). The demo critical path is three commands, two
wallets: buyer `createOrder` + token approve, expert `agree`, buyer `fund`, expert
`submitDelivery`, buyer `release` or `fail` (and `approve` when `approval_mode` is `user`).
Criteria JSON is hashed with RFC 8785 (JCS), matching `TaskEscrow.hashSpec` and the pinned
vector in `test/Demo.t.sol`. `npm run demo` is an optional local-dev replay with local EOAs
only. It refuses to run when Privy app secrets are set.

**Signing** goes through a wallet adapter ([`agents/src/wallet/adapter.ts`](../agents/src/wallet/adapter.ts)):
`getAddress()`, `sendEscrowStep` (today's `TxSender.send`), optional `createIfNeeded()`, and
`fundHint()` (a faucet link). Vendors: `PrivyShared` (path A), `LocalEoa` (path B),
`UserAaSession` (not built). Escrow should depend on that shape, not on one vendor. The CLI
still picks Privy when `PRIVY_APP_ID` and `PRIVY_APP_SECRET` are set, and local keys otherwise.
See [`PRIVY_NOTES.md`](PRIVY_NOTES.md) and [`ARCHITECTURE.md`](ARCHITECTURE.md).

```bash
cd agents && npm ci && npm test && npm run typecheck
```

## Wallet paths

Two ways to sign. Both use the same two-wallet handoff. Neither path puts a Path A
`PRIVY_APP_SECRET` in the public template. Neither path requires a verifier wallet.

### Path A — official Pact demo (`PrivyShared`)

The hosted bots share one Privy **app** (Pact Path A demo). **Users do not configure Privy.** Each bot
receives only its own wallet id: the buyer bot gets `PRIVY_WALLET_BUYER_ID`, the expert bot
gets `PRIVY_WALLET_EXPERT_ID`. A buyer process does not call Privy with the expert wallet id.
`PRIVY_WALLET_VERIFIER_*` is not part of this path. Operators bootstrap the two wallets
(`POST /v1/wallets`, `User-Agent: PrivyNodeJS/1.0`) and copy one id onto each bot. Do not
commit those secrets. See [`PRIVY_NOTES.md`](PRIVY_NOTES.md).

```bash
cd agents && npm run wallets:bootstrap
```

Path A skills (no secrets in git): [buyer](skills/guild-negotiate-buyer/SKILL.md) and
[expert](skills/guild-negotiate-expert/SKILL.md). Public `guild-relay` only (SendToAgent is
debug-only). Secret card → `_admin/register` → shared Pact demo Privy app → create or reuse the role
wallet → faucet → role-split signing.

### Path B — public skill / self-hosted (`LocalEoa`)

[`templates/`](../templates/) is this path. **Do not ship the Path A Privy app secret.** Generate two
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
accept (`demos/2026-10-13-dfcb9220/`). Approval mode comes from the frozen task.
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

### Against the live Monad deployment

Canonical addresses for chain `10143` are in [`deployments/10143.json`](../deployments/10143.json)
(also summarized in the [README](../README.md#monad-testnet-10143)).

1. Fund the buyer and expert wallets with native gas; mint or transfer MockUSDC to the buyer.
2. `createOrder` sets `verifier` to the **buyer** address. `DEFAULT_VERIFIER` on the contract is
   only used when an order passes the zero address; Path A never relies on it for signing.

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

See [`ARCHITECTURE.md`](ARCHITECTURE.md#wallets-privy-server-wallets) for the full
role-to-call mapping.
