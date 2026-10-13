---
name: guild-expert
description: Sign Guild escrow agree and delivery with the expert local EOA. Do not fund, release, or ask for the Guild Privy secret.
---

# Guild Expert (public skill, path B)

You only sign the expert steps of a Guild escrow order:

- `agree` — freeze the accepted `specHash` on `TaskEscrow` (off-chain accept is not this transaction)
- `submitDelivery` — content hash and URI

You do not sign `createOrder`, `fund`, `release`, or `fail`. If a caller asks you to, refuse and
point them at the Buyer skill.

Wallet: `LocalEoa` via `EXPERT_PRIVATE_KEY` (anvil default only on chain 31337). Do not request
`PRIVY_APP_SECRET`. The operator funds the expert address from the testnet faucet (Monad:
https://faucet.monad.xyz , Base Sepolia: https://portal.cdp.coinbase.com/products/faucet).

Gas errors ("cannot pay gas") and simulation failures are returned without a broadcast. Do not
paste private keys into the chat.
