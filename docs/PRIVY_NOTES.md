# Privy notes for agent-escrow (RH reference)

Audience: Engineering Lead / acceptance bot.  
Source of truth for RH ops: fund-harness `packages/evm/wallets/custodial/*` (and RH agent `lib/evm_ops` mirror).  
**Do not reuse RH mainnet follow-trade wallet for hackathon demo.** Spin a separate Privy app (or at least separate wallets) for Monad testnet / Base Sepolia.

## What RH actually uses

Split is **exec ⊥ wallet**:

1. Ops layer builds `TxRequest{to, data, value, chain_id, gas_limit?, nonce?}`.
2. Custodial wallet fills gas/nonce from RPC, then Privy backend signs+broadcasts.
3. Private keys never touch disk as plaintext in our code paths — only Privy `app_id` / `app_secret` + `wallet_id`.

### Secrets / env (RH shape)

| Item | Where RH keeps it | Demo suggestion |
|------|-------------------|-----------------|
| `app_id`, `app_secret` | `privy.json` (connector secrets) | `PRIVY_APP_ID`, `PRIVY_APP_SECRET` |
| RPC URL | `alchemy.json` → `rpc_url` | `MONAD_TESTNET_RPC` / `BASE_SEPOLIA_RPC` |
| Wallet metadata | `wallet.json`: `{id, address, chain_type}` | one file **per role** or a map |

Never commit these. Never paste into chat / group.

### Sign RPC (what code calls)

```
POST https://api.privy.io/v1/wallets/{wallet_id}/rpc
Authorization: Basic base64(app_id:app_secret)
privy-app-id: {app_id}
Content-Type: application/json
User-Agent: PrivyNodeJS/1.0

{
  "method": "eth_sendTransaction",
  "caip2": "<CAIP-2 for target chain>",
  "params": {
    "transaction": {
      "to": "0x…",
      "value": "0x…",
      "data": "0x…",
      "chain_id": <number>,
      "gas_limit": "0x…",   // optional but RH always sets
      "nonce": <number>     // optional; RH sets from pending
    }
  }
}
```

Response hash: prefer `data.hash`, fallback `hash`. Then poll `eth_getTransactionReceipt`.

CAIP-2 examples (confirm against Privy + chain docs before ship):

- Base Sepolia: `eip155:84532`
- Monad testnet: use whatever Privy lists for that chain id (do **not** invent; if unsupported, demo falls back to Base Sepolia)

RH mainnet today is Robinhood `eip155:4663` — irrelevant to escrow demo except as pattern.

## Two wallets for the escrow demo

Path A uses **two addresses** under the **same Guild Privy app**. The buyer bot holds only the
buyer wallet id. The expert bot holds only the expert wallet id. `createOrder.verifier` is the
buyer address, so the buyer also signs `release` / `fail`. Do not require
`PRIVY_WALLET_VERIFIER_*`. The Monad `defaultVerifier` `0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8`
is unused for new orders.

| Role | Needs to sign | Env on that bot only |
|------|---------------|-------------------|
| Buyer | token approve, `createOrder`, `fund`, `release` / `fail`, `approve` in user mode | `PRIVY_WALLET_BUYER_ID` + address |
| Expert | `agree`, `submitDelivery` | `PRIVY_WALLET_EXPERT_ID` + address |

Minimal TypeScript shape for acceptance bot / demo:

```ts
type Role = "buyer" | "expert" | "verifier";

interface RoleWallet {
  role: Role;
  walletId: string;   // Privy wallet id
  address: `0x${string}`;
}

async function sendAs(
  role: Role,
  tx: { to: `0x${string}`; data: `0x${string}`; value?: bigint },
  opts: { chainId: number; caip2: string; rpcUrl: string }
): Promise<`0x${string}`> {
  // 1) eth_estimateGas + eth_getTransactionCount(pending) via rpcUrl
  // 2) POST Privy wallets/{walletId}/rpc eth_sendTransaction
  // 3) wait for receipt; throw if status != 1
}
```

Do **not** put both wallet ids in one process, and do **not** add a third verifier wallet for the demo.

## Creating the three wallets

This section is **path A only** (the official Guild demo bot, vendor `PrivyShared`). End users of
that bot do not configure Privy. Guild operators hold `PRIVY_APP_ID` and `PRIVY_APP_SECRET` on
the bot host, outside git.

The public skill ([`templates/`](../templates/)) is **path B** (`LocalEoa`). Do not put the Guild
app secret in that template. Operators generate three local EOAs and use a testnet faucet.
`UserAaSession` is a follow-up. ZeroDev / a paymaster is an optional later UX upgrade, not the
self-host default. Bring-your-own Privy is also a follow-up.

Official-bot operators (not public-skill installers) create the buyer and expert wallets:

```bash
cd agents && npm run wallets:bootstrap
```

That is `POST https://api.privy.io/v1/wallets` with `{"chain_type":"ethereum"}` and header
`User-Agent: PrivyNodeJS/1.0` (Privy often returns 403 without it). Each role sends a stable
`privy-idempotency-key` (`guild-escrow-server-wallet:buyer|expert`). Ids and addresses
are cached in gitignored `wallets/guild-roles.json` and printed as:

- `PRIVY_WALLET_BUYER_ID` / `PRIVY_WALLET_BUYER_ADDRESS` — buyer bot only
- `PRIVY_WALLET_EXPERT_ID` / `PRIVY_WALLET_EXPERT_ADDRESS` — expert bot only

`PRIVY_WALLET_VERIFIER_ID` / `PRIVY_WALLET_VERIFIER_ADDRESS` are not printed and are not part
of the demo. Save the two ids as separate bot secrets and reuse them. A later run with the ids
unset and the cache gone creates another set. Never commit the app secret, wallet ids, or `wallets/`.

Fund Buyer (and Expert / Verifier, who also send transactions) with faucet native gas; fund
Buyer with MockUSDC after deploy when the token is not mintable by the buyer.

If Privy cannot broadcast on Monad testnet: the same EVM addresses work on Base Sepolia.
Point `PRIVY_CAIP2` and `RPC_URL` at `eip155:84532`. The agents default Monad CAIP-2 is
`eip155:10143`.

## What to reuse vs rewrite

Reuse from RH / fund-harness:

- Privy Basic-auth + `/v1/wallets/{id}/rpc` call pattern
- dry-run first (estimate + encode only), then `--send` / live flag
- nonce from `pending`; on `nonce too low`, refresh and retry once

Rewrite for escrow:

- multi-wallet registry (role → wallet id)
- chain config for Monad testnet + Base Sepolia (not Robinhood)
- no Kyber / meme follow-trade paths

## Safety for hackathon

- Testnet only; mock ERC-20 OK if no USDC faucet
- Keep RH production Privy app_secret off this repo and off demo hosts
- Deploy key for contracts can be a **fourth** throwaway EOA or another Privy wallet — not Buyer
- Group chat: never paste secrets; wire secrets in 1:1 with RH or Engineering Lead after landing

## Checklist for Engineering Lead

1. New Privy app (or sandbox) + 3 server wallets → env map above  
2. RPC + caip2 for Monad testnet; verify Privy accepts that caip2 once before demo day  
3. Bot: `sendAs(role, tx)` wrapping the RH RPC shape  
4. Handoff: buyer create → expert agree → buyer fund → expert deliver → buyer release. One wallet per process.  
5. If Monad Privy/RPC fails: flip env to Base Sepolia, same wallets/addresses  

Questions / wiring after 颗粒 lands: continue in RH 1:1 (room cannot do secret forms or box sign-in).
