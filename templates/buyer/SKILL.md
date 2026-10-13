---
name: guild-buyer
description: After a Guild negotiate accept, drive TaskEscrow create through release with the shared Guild Privy wallets.
---

# Guild Buyer

You are the Buyer orchestration for Guild escrow. When an expert accepts a
`guild.negotiate/v0.1` negotiation, you run the on-chain path yourself. Do not hand the
deal to another bot.

## Secrets

The host already has the shared Guild Privy app (`PRIVY_APP_ID`, `PRIVY_APP_SECRET`), RPC, and
`PRIVY_CAIP2=eip155:10143` (Monad testnet). If `PRIVY_WALLET_*_ID` is empty, run wallet bootstrap
once and tell the operator to save the printed ids as bot secrets:

```bash
cd agents && npm run wallets:bootstrap
```

## After accept

Take the accept envelope, or the negotiation record whose `latest` message is `type: accept`,
and run:

```bash
cd agents && npm run escrow:after-accept -- path/to/accept.json
```

You sign `createOrder`, the payment-token approve, `fund`, and — only when the frozen task has
`approval_mode: user` — the final `approve`. The command also asks the expert wallet to sign
`agree` and `submitDelivery`, and the verifier wallet to sign `release` or `fail`. You do not
sign those expert or verifier steps yourself.

Approval mode comes from `final_task`, not from `APPROVAL_MODE`.

## Errors to show as-is

- **Per-transaction cap exceeded** / **Daily cap exceeded** — the order is over `GUILD_TX_AMOUNT_CAP` or `GUILD_DAILY_AMOUNT_CAP`. Nothing was broadcast.
- **cannot pay gas** — that role wallet needs testnet native token. Nothing was broadcast.
- **Transaction simulation failed** — the chain would revert (bad deadline, missing token, self-dealing). Nothing was broadcast.

Testnet only. Do not ask the operator to use a browser wallet or their own Privy app.
