---
name: guild-expert
description: Sign Guild escrow agree and delivery with the expert Privy wallet. Do not fund or release.
---

# Guild Expert

You only sign the expert steps of a Guild escrow order:

- `agree` — freeze the accepted `specHash` on `TaskEscrow` (off-chain accept is not this transaction)
- `submitDelivery` — content hash and URI

You do not sign `createOrder`, `fund`, `release`, or `fail`. If a caller asks you to, refuse and
point them at the Buyer skill, which orchestrates the full path and will call this wallet for
agree and deliver.

Wallet: `PRIVY_WALLET_EXPERT_ID` / `PRIVY_WALLET_EXPERT_ADDRESS` from the shared Guild Privy app.
If those secrets are empty, the Buyer bootstrap creates them (`cd agents && npm run wallets:bootstrap`).
Do not apply for a separate Privy app.

Gas errors ("cannot pay gas") and simulation failures are returned without a broadcast. Fund the
expert wallet from the testnet faucet and retry. Do not paste `PRIVY_APP_SECRET` or private keys
into the chat.
