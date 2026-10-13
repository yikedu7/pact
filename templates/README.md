# Guild Buyer / Expert / Verifier templates

Install these three skills on the bot host (Cursor Automations or Grok). Escrow runs in this
repo after negotiate accept. Do not hand the accepted deal to a separate escrow chat bot.

## Configure once

Set these **bot secrets** (names only — never commit values):

| Secret | Required | Purpose |
| --- | --- | --- |
| `PRIVY_APP_ID` | yes | Shared Guild Privy app |
| `PRIVY_APP_SECRET` | yes | Shared Guild Privy app |
| `RPC_URL` or `MONAD_TESTNET_RPC` | yes | Monad testnet (`10143`) or Base Sepolia (`84532`) or anvil |
| `CHAIN_ID` | yes for testnet | `10143` (Monad testnet) |
| `PRIVY_CAIP2` | yes for Privy sends | `eip155:10143` |
| `PRIVY_WALLET_BUYER_ID` | after first run | Buyer server wallet |
| `PRIVY_WALLET_BUYER_ADDRESS` | after first run | Buyer address |
| `PRIVY_WALLET_EXPERT_ID` | after first run | Expert server wallet |
| `PRIVY_WALLET_EXPERT_ADDRESS` | after first run | Expert address |
| `PRIVY_WALLET_VERIFIER_ID` | after first run | Verifier server wallet |
| `PRIVY_WALLET_VERIFIER_ADDRESS` | after first run | Verifier address |
| `GUILD_TX_AMOUNT_CAP` | no | Per-order USDC base units. Default `100000000` (100 USDC) |
| `GUILD_DAILY_AMOUNT_CAP` | no | UTC-day USDC base units. Default `500000000` (500 USDC) |

Creators use the shared Guild app. **Bring your own Privy app is a follow-up**, not this template.
End-user browser wallets and gas sponsorship are out of scope.

## Auto wallets

When the three `PRIVY_WALLET_*_ID` values are missing, the first configure creates them
(`POST /v1/wallets`, `chain_type: ethereum`, `User-Agent: PrivyNodeJS/1.0`):

```bash
cd agents && npm run wallets:bootstrap
```

Save the printed ids and addresses as the bot secrets above. The same values are cached in
gitignored `wallets/guild-roles.json`. Fund all three with testnet gas before the first order.

## Self-run

Negotiation still uses the public relay (`guild.negotiate/v0.1`). When the expert **accepts**,
the Buyer skill runs:

```bash
cd agents && npm run escrow:after-accept -- path/to/accept.json
```

That is create → agree → fund → deliver → verify → release (buyer `approve` only when the
frozen task says `approval_mode: user`).

| Skill | Signs |
| --- | --- |
| [Buyer](buyer/SKILL.md) | Orchestrates the path. Signs `createOrder`, token `approve` / `fund`, and `approve` in user mode. |
| [Expert](expert/SKILL.md) | `agree` and `submitDelivery` only. |
| [Verifier](verifier/SKILL.md) | `release` (pass) or `fail` (refund) only. |

Show cap, gas, and simulation errors to the operator as returned. They mean nothing was broadcast.
