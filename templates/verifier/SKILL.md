---
name: guild-verifier
description: Archived. The demo path has no verifier bot. Buyer release uses the buyer wallet.
---

# Pact verifier (archived, not the demo path)

The demo critical path does not use a verifier bot or `PRIVY_WALLET_VERIFIER_*`.

`createOrder.verifier` is the buyer address. The buyer command `escrow:buyer-release` signs
`release` or `fail`. The Monad deployment address `0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8`
is not used for new orders.

Do not ask for a verifier private key. Do not create a third Privy wallet for the demo.
If an old order's `verifier` is not the buyer, stop. Do not sign it with another key.
