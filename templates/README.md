# Pact buyer / expert templates (path B)

Public skill for a self-hosted bot. After a negotiate accept, the buyer and the expert each
sign only their own steps and pass a `guild.escrow/v0.1` cue to the other. There is no
verifier bot on this path.

Path A (shared Privy app, public guild-relay, secret card) is documented in
[`docs/skills/guild-negotiate-buyer/SKILL.md`](../docs/skills/guild-negotiate-buyer/SKILL.md)
and [`docs/skills/guild-negotiate-expert/SKILL.md`](../docs/skills/guild-negotiate-expert/SKILL.md).
Those files name secrets. They do not contain them.

This template does **not** include the Path A Privy app secret. Signing is `LocalEoa`: two
keys you generate (buyer and expert). The official demo (path A, `PrivyShared`) uses the same
handoff with the shared Path A Privy app, and each bot receives only its own wallet id.

## Configure

Leave `PRIVY_APP_ID` and `PRIVY_APP_SECRET` unset. Do not set `PRIVY_WALLET_VERIFIER_*`.

```bash
cast wallet new    # buyer, then expert. Testnet keys only.
export BUYER_PRIVATE_KEY=0x…
export EXPERT_PRIVATE_KEY=0x…
cast wallet address --private-key "$BUYER_PRIVATE_KEY"
```

Also set `RPC_URL` (or `MONAD_TESTNET_RPC` / `BASE_SEPOLIA_RPC`), `CHAIN_ID`, and
`EXPERT_AGENT_ID` (the expert registers its own agent; the buyer does not).

| Chain | Gas |
| --- | --- |
| Monad testnet `10143` | https://faucet.monad.xyz |
| Base Sepolia `84532` | https://portal.cdp.coinbase.com/products/faucet |
| anvil `31337` | Prefunded. Buyer and expert keys may be omitted; the CLI uses the anvil defaults. |

Send faucet funds to both addresses. If the payment token is not MockUSDC, fund the buyer
with that token too. MockUSDC can be minted by the buyer during create.

`UserAaSession` (social-login smart accounts) is not in this template. ZeroDev / a paymaster
is an optional later upgrade on that path, not what you set up here.

Optional caps (USDC base units, 6 decimals): `GUILD_TX_AMOUNT_CAP` (default `100000000`),
`GUILD_DAILY_AMOUNT_CAP` (default `500000000`).

## Handoff

When the expert **accepts** (`guild.negotiate/v0.1`), the buyer runs create. Each command
prints the next cue. Give that JSON to the other bot (file, stdin `-`, or
`POST` `guild-relay/<botId>`). `createOrder.verifier` is the buyer address. The archived
Monad verifier `0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8` is not used.

```bash
cd agents && npm run escrow:buyer-create-fund -- path/to/accept.json
cd agents && npm run escrow:expert-agree-deliver -- path/to/cue.json
cd agents && npm run escrow:buyer-create-fund -- path/to/cue.json
cd agents && npm run escrow:expert-agree-deliver -- path/to/cue.json
cd agents && npm run escrow:buyer-release -- path/to/cue.json
```

| Skill | Signs |
| --- | --- |
| [Buyer](buyer/SKILL.md) | `createOrder` (verifier = buyer), token `approve` / `fund`, `release` or `fail`, and `approve` in user mode. |
| [Expert](expert/SKILL.md) | `agree` and `submitDelivery` only. |

`npm run demo` is optional local-dev only. It is not this path.

Show cap, gas, and simulation errors to the operator as returned. They mean nothing was broadcast.
A gas error should include the faucet for that chain (`fundHint` in `agents/src/wallet/adapter.ts`).
