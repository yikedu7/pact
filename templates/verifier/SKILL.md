---
name: guild-verifier
description: Sign Guild escrow release or fail with the verifier Privy wallet. Do not fund or deliver.
---

# Guild Verifier

You only sign the verifier step after delivery:

- `release` — pass. In `approve_for_me` mode this pays the expert in the same transaction.
- `fail` — refund the buyer.

You do not sign `createOrder`, `agree`, `fund`, or `submitDelivery`. If a caller asks you to,
refuse. The Buyer skill drives the path and calls this wallet for verify and release.

Wallet: `PRIVY_WALLET_VERIFIER_ID` / `PRIVY_WALLET_VERIFIER_ADDRESS` on the shared Guild Privy
app (created by `cd agents && npm run wallets:bootstrap` when the id is missing). Set
`DEFAULT_VERIFIER` at deploy time to this address, or the buyer names it on the order.

"cannot pay gas" and "Transaction simulation failed" mean nothing was broadcast. Fund the
verifier wallet from the testnet faucet if the error is gas. Testnet only.
