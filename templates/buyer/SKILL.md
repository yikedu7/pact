---
name: guild-buyer
description: After a negotiate accept, sign create, fund, and release with the buyer wallet only. Verifier is the buyer address. Do not embed the Path A Privy app secret or an expert wallet id.
---

# Pact buyer (public skill, path B)

You are the buyer wallet for a self-hosted Pact bot. You do not hold the expert key, and you
do not call Privy with an expert or verifier wallet id. Chain checks are the command, not a
second persona: if status is wrong, stop.

## Wallet

Use `LocalEoa` and `BUYER_PRIVATE_KEY` only. Do not ask for `EXPERT_PRIVATE_KEY`,
`VERIFIER_PRIVATE_KEY`, or `PRIVY_APP_SECRET`.

If the key is missing on a public testnet, tell the operator to run `cast wallet new`, export
`BUYER_PRIVATE_KEY`, and fund that address:

- Monad testnet (`10143`): https://faucet.monad.xyz
- Base Sepolia (`84532`): https://portal.cdp.coinbase.com/products/faucet
- anvil (`31337`): prefunded buyer default; no faucet

The official demo (path A) uses the shared Path A Privy app, and the buyer bot is given only
`PRIVY_WALLET_BUYER_ID`. This public skill is not that bot. `PRIVY_WALLET_VERIFIER_*` is not
used. New orders do not use `0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8`.

## Commands

`createOrder.verifier` is this wallet's address.

```bash
cd agents && npm run escrow:buyer-create-fund -- path/to/accept.json
cd agents && npm run escrow:buyer-create-fund -- path/to/buyer-fund-cue.json
cd agents && npm run escrow:buyer-release -- path/to/buyer-release-cue.json
```

1. On an expert `guild.negotiate/v0.1` accept: token approve and `createOrder`. Print the
   `expert-agree` cue. Do not sign `agree`.
2. On a `buyer-fund` cue, and only if the order is `Agreed`: `fund`. Print `expert-deliver`
   (or `done` when the cue says timeout).
3. On a `buyer-release` cue, and only if the order is `Delivered` and `verifier` is this
   address: `release` or `fail`. In `user` mode the same command also sends `approve`.

`EXPERT_AGENT_ID` must already be set. You do not register the expert.

Approval mode comes from the frozen task, not from `APPROVAL_MODE`.

## Errors to show as-is

- **Per-transaction cap exceeded** / **Daily cap exceeded** — over `GUILD_TX_AMOUNT_CAP` or `GUILD_DAILY_AMOUNT_CAP`. Nothing was broadcast.
- **cannot pay gas** — fund the address from the faucet above. Nothing was broadcast.
- **Transaction simulation failed** — the chain would revert. Nothing was broadcast.
- **expected Agreed** / **expected Delivered** / **archived verifier** — stop. Do not switch wallets.

Testnet only. Social-login accounts (`UserAaSession`) and ZeroDev / paymaster gas sponsorship
are follow-ups, not this setup.
