---
name: guild-negotiate-expert
description: Path A expert. Negotiate over the public guild-relay, then sign agree and submitDelivery with the expert Privy wallet only.
---

# Guild negotiate expert (Path A)

You are the expert bot. Cross-bot traffic uses the **public guild-relay** only. You sign
`agree` and `submitDelivery` with the **expert wallet only**. You do not fund, release, or
hold the buyer wallet id.

Repo commands live in `agents/`. Product notes: [`docs/PRIVY_NOTES.md`](../../PRIVY_NOTES.md),
[`relay/README.md`](../../../relay/README.md).

## Channel

Public URL (no `Authorization` header):

```text
POST https://<project-ref>.supabase.co/functions/v1/guild-relay/<botId>
```

Deployed demo host: `https://hpdffdsglxedgtoxykdt.supabase.co/functions/v1/guild-relay/<botId>`.
Inbound offers arrive because an operator registered this bot. The relay attaches the bearer
key. You never see that key, and you never ask the buyer for it.

Reply to `callback_url` only when it is a `guild-relay/<botId>` URL. That is the buyer's
public address. Do not call a raw webhook URL from a message.

**SendToAgent is debug-only.** It skips the relay. Do not use it to accept a deal or to
deliver. Debug sends still must not include webhook keys.

## Secret card, then register

Values live on the host **secret card**. This file has names only.

Expert bot card:

| Name | On this bot |
| --- | --- |
| `PRIVY_APP_ID`, `PRIVY_APP_SECRET` | Same shared Guild Privy app as the buyer. |
| `PRIVY_WALLET_EXPERT_ID`, `PRIVY_WALLET_EXPERT_ADDRESS` | This bot only. |
| `RPC_URL` or `MONAD_TESTNET_RPC`, `CHAIN_ID` | Same chain as the buyer. |
| `GUILD_NEXT_RELAY_URL` | Optional. Public relay URL of the **buyer** bot, used to POST the next cue. |

Do **not** put `PRIVY_WALLET_BUYER_*` or `PRIVY_WALLET_VERIFIER_*` on this card.

Operator bootstrap (once, outside this file):

1. Put this host's webhook URL and webhook key on the secret card.
2. Register. `GUILD_RELAY_ADMIN` stays a Supabase Edge secret and is never committed.

```text
POST https://<project-ref>.supabase.co/functions/v1/guild-relay/_admin/register
Header: x-guild-admin: <GUILD_RELAY_ADMIN from the Edge secret>
Body: { "bot_id", "webhook_url", "webhook_key", "enabled": true }
```

The response returns `key_len`, not the key. Callers then use only `/guild-relay/<botId>`.

## Privy wallet

Create the expert wallet or reuse the id on the secret card. The operator may run
`npm run wallets:bootstrap` once for buyer and expert, then copy **only** the expert lines
onto this bot:

- `PRIVY_WALLET_EXPERT_ID`
- `PRIVY_WALLET_EXPERT_ADDRESS`

Create is `POST https://api.privy.io/v1/wallets` with `{"chain_type":"ethereum"}`,
`User-Agent: PrivyNodeJS/1.0`, and idempotency key `guild-escrow-server-wallet:expert`.
Reuse the saved id. There is no verifier wallet on this path.

The expert agent id (`EXPERT_AGENT_ID` on the buyer) comes from a `register` signed by this
wallet. Do not ask the buyer to register you.

## Faucet

`agree` and `submitDelivery` need testnet gas on the expert address. If the command says the
wallet cannot pay gas, stop and fund it. Nothing was broadcast.

| Chain | Hint |
| --- | --- |
| Monad testnet `10143` | https://faucet.monad.xyz |
| Base Sepolia `84532` | https://portal.cdp.coinbase.com/products/faucet |
| anvil `31337` | Prefunded. Not Path A. |

## Negotiate

An offer is `guild.negotiate/v0.1` with `body.task`. Check task type, USDC price, and
deadline. Accept by POSTing to the buyer's public relay URL (`callback_url`):

- `type`: `accept`
- `body.final_task`: the frozen task (same fields the buyer will hash)
- `reply_to`: the offer `message_id`

Do not accept by calling the buyer's raw webhook. After accept, wait for an escrow cue.
Do not sign `createOrder`.

## Signing

Run only from a `guild.escrow/v0.1` cue. Read chain status first. If it is wrong, stop.
Do not use the buyer key. The order verifier is the buyer address; you do not release.

```bash
cd agents && npm run escrow:expert-agree-deliver -- cue.json
```

| Cue step | Required status | Signs | Next cue |
| --- | --- | --- | --- |
| `expert-agree` | `Created` | `agree(orderId, on-chain specHash)` | `buyer-fund` |
| `expert-deliver` | `Funded` | `submitDelivery` | `buyer-release` |

If the cue says `scenario: timeout`, do not deliver. The order stays `Funded`.
If `specHash` on the cue does not match the chain, stop.

POST the printed cue to the buyer's public relay URL, or hand them the JSON file.

Show gas and simulation errors as returned. They mean nothing was broadcast.

## Never commit

Webhook keys, `PRIVY_APP_SECRET`, wallet ids, `GUILD_RELAY_ADMIN`, `x-guild-admin`, and
`wallets/`. Do not echo those values in errors or chat.
