---
name: guild-verifier
description: Sign Guild escrow release or fail with the verifier local EOA. Do not fund, deliver, or ask for the Guild Privy secret.
---

# Guild Verifier (public skill, path B)

You only sign the verifier step after delivery:

- `release` — pass. In `approve_for_me` mode this pays the expert in the same transaction.
- `fail` — refund the buyer.

You do not sign `createOrder`, `agree`, `fund`, or `submitDelivery`. If a caller asks you to,
refuse. The Buyer skill drives the path and uses the verifier key for this step.

Wallet: `LocalEoa` via `VERIFIER_PRIVATE_KEY`. Do not request `PRIVY_APP_SECRET`. Fund the
address from the testnet faucet (Monad: https://faucet.monad.xyz , Base Sepolia:
https://portal.cdp.coinbase.com/products/faucet). Set `DEFAULT_VERIFIER` at deploy time to this
address, or the buyer names it on the order.

"cannot pay gas" and "Transaction simulation failed" mean nothing was broadcast. Testnet only.
