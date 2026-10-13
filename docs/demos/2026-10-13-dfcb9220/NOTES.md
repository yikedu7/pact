# Guild MVP demo — 2026-10-13

End-to-end path exercised for hackathon submission: **cross-bot negotiation** through the public
delivery relay, then **Monad testnet (10143) escrow** to `Released` with Privy signing.

## Public relay

```text
https://hpdffdsglxedgtoxykdt.supabase.co/functions/v1/guild-relay/<botId>
```

Example from the offer message: `…/guild-relay/buyer-demo`. Outsiders POST `guild.negotiate/v0.1`
with no Authorization header; webhook keys stay in Supabase (`guild_bots`). See
[`relay/README.md`](../../../relay/README.md).

## Negotiation

| Field | Value |
| --- | --- |
| `negotiation_id` | `dfcb9220-03b2-4337-96d4-c1460c2a231f` |
| Task | `design.logo`, 5 USDC, Expert **accepted** |
| Negotiation JCS `specHash` | `0x1b43cd73e2242762c4e27c12cb5ee58f32f733bba1b2406a158be2f2abaeff1d` |

Full message history: [`NEGOTIATION_dfcb9220.json`](./NEGOTIATION_dfcb9220.json).

## On-chain (Monad 10143)

| Field | Value |
| --- | --- |
| `orderId` | **2** |
| Status | **Released** (`ApproveForMe`, 5 USDC) |
| On-chain `specHash` | `0xbb07aedad5722462d6d098bc605fe2868329acb6ecefb2caf703e8eedbc23a06` |

### Dual `specHash` (acceptable for this demo)

Negotiation freezes criteria with a fixed `deadline` in JCS (`2026-10-20T14:51:26Z`), yielding the
negotiation hash above. The live escrow run built the spec with a **dynamic deadline**
(`block.timestamp + 86400`), so `TaskEscrow` stored a different `specHash`. The negotiation hash
is still the canonical record of what the bots agreed; the chain hash reflects what was actually
submitted in `createOrder`. Production should align JCS input before `agree` / `createOrder`.

### Key transaction hashes (order 2)

| Step | Hash |
| --- | --- |
| `createOrder` | `0xd9528b0a255aea574f140a7c8244f78485ab7230f30a676f6b0f970159a172c4` |
| `agree` | `0xe538fc4237b273286d98bba65a1f94ffed552f1aeb507fcce501a1466e465709` |
| `fund` | `0x7c3c76b68d77d651a2feee5e9ef2bf54f581a964b6a02607966d6afcbdd38b69` |
| `submitDelivery` | `0x131777b25e8833dd3c3829b389e2b0e34fd20914b052134efa0c24275aa24e74` |
| `release` | `0x94a7c1e5486314f94c751d6e6db9dd95685779184e5ee929197562fedae99f10` |

Machine-readable run log: [`FULL_FLOW_10143_dfcb9220.json`](./FULL_FLOW_10143_dfcb9220.json).

The negotiation JSON also includes an earlier **local anvil** escrow attempt (`escrow_result` with
`orderId` 1) from the same session; the hackathon proof point is the Monad row above.
