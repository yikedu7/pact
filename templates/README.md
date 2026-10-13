# Guild Buyer / Expert / Verifier templates (path B)

Public skill for a self-hosted bot. Escrow runs in this repo after negotiate accept. Do not
hand the accepted deal to a separate escrow chat bot.

This template does **not** include the Guild Privy app secret. Signing is `LocalEoa`: three
keys you generate. The official Guild demo bot (path A, `PrivyShared`) is a different host;
people using that bot do not configure wallets or Privy.

## Configure

Leave `PRIVY_APP_ID` and `PRIVY_APP_SECRET` unset.

```bash
cast wallet new    # buyer, then expert, then verifier. Testnet keys only.
export BUYER_PRIVATE_KEY=0x…
export EXPERT_PRIVATE_KEY=0x…
export VERIFIER_PRIVATE_KEY=0x…
cast wallet address --private-key "$BUYER_PRIVATE_KEY"
```

Also set `RPC_URL` (or `MONAD_TESTNET_RPC` / `BASE_SEPOLIA_RPC`) and `CHAIN_ID`.

| Chain | Gas |
| --- | --- |
| Monad testnet `10143` | https://faucet.monad.xyz |
| Base Sepolia `84532` | https://portal.cdp.coinbase.com/products/faucet |
| anvil `31337` | Prefunded. Keys may be omitted; the CLI uses the anvil defaults. |

Send faucet funds to each of the three addresses. If the payment token is not MockUSDC, fund
the buyer with that token too. MockUSDC can be minted by the buyer during the run.

`UserAaSession` (social-login smart accounts) is not in this template. ZeroDev / a paymaster
is an optional later upgrade on that path, not what you set up here.

Optional caps (USDC base units, 6 decimals): `GUILD_TX_AMOUNT_CAP` (default `100000000`),
`GUILD_DAILY_AMOUNT_CAP` (default `500000000`).

## Self-run

When the expert **accepts** (`guild.negotiate/v0.1`), the Buyer skill runs:

```bash
cd agents && npm run escrow:after-accept -- path/to/accept.json
```

| Skill | Signs |
| --- | --- |
| [Buyer](buyer/SKILL.md) | Orchestrates the path. Signs `createOrder`, token `approve` / `fund`, and `approve` in user mode. |
| [Expert](expert/SKILL.md) | `agree` and `submitDelivery` only. |
| [Verifier](verifier/SKILL.md) | `release` (pass) or `fail` (refund) only. |

Show cap, gas, and simulation errors to the operator as returned. They mean nothing was broadcast.
A gas error should include the faucet for that chain (`fundHint` in `agents/src/wallet/adapter.ts`).
