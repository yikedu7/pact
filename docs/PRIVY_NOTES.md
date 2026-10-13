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

## Three roles for escrow demo

Escrow needs **three distinct addresses** (Buyer funds, Expert delivers, Verifier releases). Map to three Privy server wallets under the **same demo app**:

| Role | Needs to sign | Suggested env map |
|------|---------------|-------------------|
| Buyer | `agree` / `fund` (approve USDC + escrow fund) | `PRIVY_WALLET_BUYER_ID` + address |
| Expert | `deliver` (content hash + URI) | `PRIVY_WALLET_EXPERT_ID` + address |
| Verifier | `verify` → `release` (or refund path) | `PRIVY_WALLET_VERIFIER_ID` + address |

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

Do **not** expose one shared wallet that impersonates all three — judges will ask who holds funds.

## Creating the three wallets

Privy dashboard / API: create three **server wallets** (Ethereum) in the demo app. Record `id` + `address` for each. Fund Buyer (and maybe Verifier if gas-only roles need native) with faucet native gas; fund Buyer with MockUSDC after deploy.

If Privy cannot create wallets on Monad testnet yet: create wallets as EVM addresses (same ECDSA), fund on the chain that works, point `caip2` + RPC at Base Sepolia fallback. Addresses stay stable across EVM chains.

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
4. Script: mint MockUSDC → Buyer; approve escrow; fund → deliver → verify → release  
5. If Monad Privy/RPC fails: flip env to Base Sepolia, same wallets/addresses  

Questions / wiring after 颗粒 lands: continue in RH 1:1 (room cannot do secret forms or box sign-in).
