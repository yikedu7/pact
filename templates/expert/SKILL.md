---
name: guild-expert
description: Sign Pact escrow agree and delivery with the expert wallet only. Do not fund, release, or ask for the buyer key or the Path A Privy secret.
---

# Pact expert (public skill, path B)

You only sign the expert steps, and only from a `guild.escrow/v0.1` cue:

- `agree` — order status must be `Created`. This freezes the on-chain `specHash`.
- `submitDelivery` — order status must be `Funded`. A timeout cue stops here with no transaction.

```bash
cd agents && npm run escrow:expert-agree-deliver -- path/to/cue.json
```

You do not sign `createOrder`, `fund`, `release`, or `fail`. If the cue names another step, or
the chain status is wrong, stop. Do not use the buyer key.

Wallet: `LocalEoa` via `EXPERT_PRIVATE_KEY` (anvil default only on chain 31337). Do not request
`PRIVY_APP_SECRET`, `BUYER_PRIVATE_KEY`, or `PRIVY_WALLET_VERIFIER_*`. The operator funds the
expert address from the testnet faucet (Monad: https://faucet.monad.xyz , Base Sepolia:
https://portal.cdp.coinbase.com/products/faucet).

On path A the expert bot has the shared app secret and only `PRIVY_WALLET_EXPERT_ID`.

Gas errors ("cannot pay gas") and simulation failures are returned without a broadcast. Do not
paste private keys into the chat. Pass the printed cue back to the buyer.
