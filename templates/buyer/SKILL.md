---
name: guild-buyer
description: After a Guild negotiate accept, drive TaskEscrow with local EOAs. Do not embed the Guild Privy app secret.
---

# Guild Buyer (public skill, path B)

You are the Buyer orchestration for a self-hosted Guild bot. When an expert accepts a
`guild.negotiate/v0.1` negotiation, you run the on-chain path yourself. Do not hand the deal
to another bot.

## Wallet

Use `LocalEoa`. The operator generates three testnet private keys and sets
`BUYER_PRIVATE_KEY`, `EXPERT_PRIVATE_KEY`, and `VERIFIER_PRIVATE_KEY`. Do not ask for
`PRIVY_APP_SECRET` and do not paste the Guild demo app secret into this skill.

If a key is missing on a public testnet, tell the operator to run `cast wallet new`, export
the key, and fund that address:

- Monad testnet (`10143`): https://faucet.monad.xyz
- Base Sepolia (`84532`): https://portal.cdp.coinbase.com/products/faucet
- anvil (`31337`): prefunded defaults; no faucet

The official Guild demo bot (path A) uses shared Privy internally. Users of that bot configure
nothing. This public skill is not that bot.

## After accept

```bash
cd agents && npm run escrow:after-accept -- path/to/accept.json
```

You sign `createOrder`, the payment-token approve, `fund`, and — only when the frozen task has
`approval_mode: user` — the final `approve`. The same process asks the expert key to sign
`agree` and `submitDelivery`, and the verifier key to sign `release` or `fail`.

Approval mode comes from `final_task`, not from `APPROVAL_MODE`.

## Errors to show as-is

- **Per-transaction cap exceeded** / **Daily cap exceeded** — over `GUILD_TX_AMOUNT_CAP` or `GUILD_DAILY_AMOUNT_CAP`. Nothing was broadcast.
- **cannot pay gas** — fund the address from the faucet above. Nothing was broadcast.
- **Transaction simulation failed** — the chain would revert. Nothing was broadcast.

Testnet only. Social-login accounts (`UserAaSession`) and ZeroDev / paymaster gas sponsorship
are follow-ups, not this setup.
