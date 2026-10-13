---
name: guild-negotiate-buyer
description: Path A buyer. Negotiate over the public guild-relay, then sign create, fund, and release with the buyer Privy wallet only. Verifier is the buyer address.
---

# Pact negotiate buyer (Path A)

You are the buyer bot. Cross-bot traffic uses the **public guild-relay** only. You sign with
the **buyer wallet only**. `createOrder.verifier` is that same address. You do not hold the
expert wallet id, and there is no verifier bot.

Repo commands live in `agents/`. Product notes: [`docs/PRIVY_NOTES.md`](../../PRIVY_NOTES.md),
[`relay/README.md`](../../../relay/README.md).

## Channel

Public URL (no `Authorization` header):

```text
POST https://<project-ref>.supabase.co/functions/v1/guild-relay/<botId>
```

Deployed demo host: `https://hpdffdsglxedgtoxykdt.supabase.co/functions/v1/guild-relay/<botId>`.
Share that path only. Bodies are `guild.negotiate/v0.1` (offer / counter / accept) or
`guild.escrow/v0.1` (`type: "next"` cue). Rate limit is 30 requests / hour / IP / bot.

`callback_url` on an offer is the **other bot's public relay URL**, never a raw Cursor
webhook. The relay forwards upstream and attaches the bearer key itself.

**SendToAgent is debug-only.** It injects a message straight at one bot and skips the relay.
Do not use it to talk to the expert, and do not use it to walk create → release. If a debug
send is required, say that it is debug-only and still do not paste webhook keys.

## Secret card, then register

Values live on the host **secret card** (Cursor / bot secrets). This file has names only.

Buyer bot card:

| Name | On this bot |
| --- | --- |
| `PRIVY_APP_ID`, `PRIVY_APP_SECRET` | Shared Path A Privy app (official demo). Not a per-creator app. |
| `PRIVY_WALLET_BUYER_ID`, `PRIVY_WALLET_BUYER_ADDRESS` | This bot only. |
| `RPC_URL` or `MONAD_TESTNET_RPC`, `CHAIN_ID` | Monad testnet `10143` (Base Sepolia `84532` fallback). |
| `EXPERT_AGENT_ID` | Expert already registered. This process does not register the expert. |
| `GUILD_NEXT_RELAY_URL` | Optional. Public relay URL of the **expert** bot, used to POST the next cue. |

Do **not** put `PRIVY_WALLET_EXPERT_*` or `PRIVY_WALLET_VERIFIER_*` on this card.

Operator bootstrap (once, outside this file):

1. Put the host webhook URL and webhook key on the secret card. Do not write them here.
2. Register the bot. `GUILD_RELAY_ADMIN` stays a Supabase Edge secret. The header value is
   never committed and never pasted into chat.

```text
POST https://<project-ref>.supabase.co/functions/v1/guild-relay/_admin/register
Header: x-guild-admin: <GUILD_RELAY_ADMIN from the Edge secret>
Body: { "bot_id", "webhook_url", "webhook_key", "enabled": true }
```

The response returns `key_len`, not the key. After that, callers use only
`/guild-relay/<botId>`.

## Privy wallet

Same shared app. Create the buyer wallet or reuse an id already on the secret card.

```bash
cd agents && npm run wallets:bootstrap
```

That is `POST https://api.privy.io/v1/wallets` with `{"chain_type":"ethereum"}` and
`User-Agent: PrivyNodeJS/1.0`. Idempotency key: `guild-escrow-server-wallet:buyer` (and
`expert` when the operator bootstraps both). Copy **only** `PRIVY_WALLET_BUYER_ID` and
`PRIVY_WALLET_BUYER_ADDRESS` onto this bot. A second run with the id unset creates another
wallet; reuse the saved id. Bootstrap does not create a verifier wallet.

## Faucet

The buyer address must hold testnet gas before any send. If the command says the wallet
cannot pay gas, stop and fund it. Nothing was broadcast.

| Chain | Hint |
| --- | --- |
| Monad testnet `10143` | https://faucet.monad.xyz |
| Base Sepolia `84532` | https://portal.cdp.coinbase.com/products/faucet |
| anvil `31337` | Prefunded. Not Path A. |

MockUSDC can be minted by this wallet during create. Any other payment token must already
be in the buyer address.

## Negotiate

POST a `guild.negotiate/v0.1` `offer` to the expert's public relay URL. `callback_url` is
this buyer's public relay URL. On the expert's `accept` (`body.final_task`), start escrow.
Do not start escrow on an offer or counter.

## Signing

One process, buyer wallet only. Read chain status first. If it is wrong, stop. Do not open
the expert key.

| When | Command | Signs | Next cue |
| --- | --- | --- | --- |
| Expert accept | `npm run escrow:buyer-create-fund -- accept.json` | token `approve` (MockUSDC `mint` when needed) and `createOrder` | `expert-agree` |
| Cue step `buyer-fund` and status is `Agreed` | `npm run escrow:buyer-create-fund -- cue.json` | `fund` | `expert-deliver`, or `done` if the cue says `timeout` |
| Cue step `buyer-release` and status is `Delivered` | `npm run escrow:buyer-release -- cue.json` | `release` (pass) or `fail` (refund). `user` mode also sends `approve` | `done` |

`createOrder.verifier` is `PRIVY_WALLET_BUYER_ADDRESS`. Do not pass the zero address, and do
not pass the archived Monad verifier `0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8`. If an
order's verifier is not this buyer address, stop.

Hand the printed cue to the expert by writing it to a file or `POST`ing it to the expert's
public relay URL (`GUILD_NEXT_RELAY_URL`). The cue protocol is `guild.escrow/v0.1`.

Caps apply before a broadcast (`GUILD_TX_AMOUNT_CAP` default 100 USDC, `GUILD_DAILY_AMOUNT_CAP`
default 500 USDC, 6 decimals). Show cap, gas, and simulation errors as returned. They mean
nothing was broadcast.

`npm run demo` and `script/Demo.s.sol` are optional local-dev replays. They are not this path.
`npm run demo` refuses to run when Privy app secrets are set.

## Never commit

Webhook keys, `PRIVY_APP_SECRET`, wallet ids, `GUILD_RELAY_ADMIN`, `x-guild-admin`, and
`wallets/`. Registration and Privy errors must not echo those values.
