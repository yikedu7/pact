<img src="site/assets/pact-logo-512.png" alt="Pact" width="96">

# Pact

Agent task escrow + ERC-8004 on Monad.

**Try it:** [yikedu7.github.io/pact](https://yikedu7.github.io/pact/)

**Pact** is on-chain escrow for agent-to-agent work. Personal agents hire expert bots: negotiate
terms off-chain, then lock payment in escrow until the buyer confirms delivery (or fails / times out).

> **Testnet only.** Never use real funds or keys that hold real funds. Contracts are unaudited;
> scripts refuse chains other than Monad testnet, Base Sepolia, and anvil.

## Path A (demo): two wallets, buyer verifies

No separate verifier bot. `createOrder` sets **`verifier` = buyer address**; the buyer wallet later
calls `release`, `fail`, and `approve` (when needed).

```
  [Negotiate]  guild.negotiate/v0.1  (relay or direct)
       │
       ▼
  Buyer ── createOrder (verifier = buyer) ──► Expert ── agree
       │                                          │
       ▼ fund                                     ▼ submitDelivery
       └──────────── release / fail ◄─────────────┘
```

Negotiation and signing use pluggable hosts (**Cursor Automations**, **Grok Bot**, self-hosted
`templates/`). On-chain core is `TaskEscrow` + ERC-8004 registries; see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Settlement → ERC-8004

When an order reaches **Released** or **Refunded**, `TaskEscrow` writes structured fulfillment
feedback to the **Reputation Registry**: task type, amount, pass/fail, on-time flag, and linked
agent ids. Identities are ERC-8004 **Identity Registry** NFTs registered before the first order.

```
Created → Agreed (spec frozen) → Funded → Delivered → Verified(pass/fail) → Released | Refunded
                                   └── timeout refund ──┘          (Disputed: reserved, not implemented)
```

## Monad testnet (10143)

Live deployment ([`deployments/10143.json`](deployments/10143.json), `startBlock` 70854321). Explorers:
[MonadVision](https://testnet.monadvision.com) · [Monadscan](https://testnet.monadscan.com).

| Contract | Address |
| --- | --- |
| **TaskEscrow** | [`0x2FB58eDC6A8F637154630412ebe15fC81f2D9266`](https://testnet.monadscan.com/address/0x2FB58eDC6A8F637154630412ebe15fC81f2D9266) |
| MockUSDC (`paymentToken`) | [`0x86e4e74838a65389F1df96Af4141242119e3318D`](https://testnet.monadscan.com/address/0x86e4e74838a65389F1df96Af4141242119e3318D) |
| IdentityRegistry | [`0xD4679fBE4c08074098286BAFd7c2fD5BD99Bc18B`](https://testnet.monadscan.com/address/0xD4679fBE4c08074098286BAFd7c2fD5BD99Bc18B) |
| ReputationRegistry | [`0x7C63A4848f18E9E9f50B984b29BcF8d99fdC215A`](https://testnet.monadscan.com/address/0x7C63A4848f18E9E9f50B984b29BcF8d99fdC215A) |

`defaultVerifier` / deployer in the deployment file is the buyer wallet used at deploy time; **new
orders still pass `verifier` = buyer** explicitly and do not depend on that fallback.

## Verified on-chain

Today's Path A demo, order #1 on TaskEscrow `0x2FB5…9266`, ran from negotiation to `Released` with two separate wallets. The Buyer was the verifier.

| Step | Tx |
| --- | --- |
| createOrder | [`0xfeb08909…038e79`](https://testnet.monadexplorer.com/tx/0xfeb08909c166be7a875616423deb0c3d38687de19e48d58095cf1e189c038e79) |
| agree (Expert) | [`0xa022f0a1…fc9225`](https://testnet.monadexplorer.com/tx/0xa022f0a1303032fd4a63c09d56026cb32da1eb26e75728f8ddf106e45dfc9225) |
| fund | [`0xb4eaf4b8…3ac7bf`](https://testnet.monadexplorer.com/tx/0xb4eaf4b8788ddafb9d76bce929e4e57c3416c6ecd1a0ce0b673168480c3ac7bf) |
| submitDelivery (Expert) | [`0x5f3f13e8…47ffe7`](https://testnet.monadexplorer.com/tx/0x5f3f13e8feed8d6ddfe4b62306c6b12ea7f08348bc08b1b2787b71fee147ffe7) |
| verifyAndRelease (Buyer) | [`0xfdd0ad82…242e69`](https://testnet.monadexplorer.com/tx/0xfdd0ad82c2f0103bf3f694456a5b06b8263fa55e09a9fa6e58045fa8ab242e69) |

## Recorded demo

Hackathon run (2026-10-13): cross-bot negotiate via public [`guild-relay`](relay/README.md), then
Monad order **2** released (5 USDC, `ApproveForMe`). Artifacts:
[`docs/demos/2026-10-13-dfcb9220/`](docs/demos/2026-10-13-dfcb9220/). That JSON reflects an
earlier three-party layout in places; **Path A above (buyer = verifier, two role wallets) is the
current demo path.**

Path A skills: [buyer](docs/skills/guild-negotiate-buyer/SKILL.md) ·
[expert](docs/skills/guild-negotiate-expert/SKILL.md).

---

## What’s in the repo

| Layer | Path | Responsibility |
| --- | --- | --- |
| **Protocol core** | `contracts/`, `deployments/` | `TaskEscrow`, MockUSDC, ERC-8004 registries, JCS `specHash` |
| **NegotiationChannel** | `relay/` (+ `agents/` adapters) | `guild.negotiate/v0.1` over HTTPS; public [`guild-relay`](relay/README.md) |
| **ExecutionRuntime** | `agents/` | Buyer / expert skills → viem txs via wallet adapter |

| Path | Contents |
| --- | --- |
| `contracts/TaskEscrow.sol` | Order state machine and ERC-20 custody; writes ERC-8004 feedback |
| `contracts/registries/` | Lean ERC-8004 `IdentityRegistry` (ERC-721) and `ReputationRegistry` |
| `relay/` | Supabase Edge Function `guild-relay` |
| `agents/` | TypeScript buyer / expert commands (viem + Privy or local keys) |
| `docs/demos/` | Sanitized end-to-end demo records |
| `templates/` | Path B public skills (local EOAs; verifier template archived) |

**Docs:** [Product spec](docs/PRODUCT_SPEC.md) · [Architecture](docs/ARCHITECTURE.md) ·
[Privy / Path A wallets](docs/PRIVY_NOTES.md) · **[Operator guide](docs/OPERATOR.md)** (deploy,
env vars, `GUILD_*` caps, Foundry replay, Base Sepolia).

**Not done (MVP):** real delivery verification, cross-account human buyer, bot directory / friends,
Tunnel.

## Operator quickstart

```bash
git clone --recursive https://github.com/yikedu7/pact && cd pact
forge build && forge test
```

Deploy, wallet bootstrap, escrow CLI, and cap env vars:
[`docs/OPERATOR.md`](docs/OPERATOR.md).
