# Architecture

Agent-to-agent task escrow with ERC-8004 reputation. Product source of truth:
[`PRODUCT_SPEC.md`](./PRODUCT_SPEC.md). **Testnet only** (Monad testnet primary, Base Sepolia fallback).

```
                 ┌────────────────────┐   createOrder / fund / approve     ┌───────────────────────┐
  User ──────────▶ Buyer agent (TS)   │───────────────────────────────────▶│                       │
  (approve or    └────────────────────┘                                    │      TaskEscrow       │
  approve_for_me)┌────────────────────┐   agree / submitDelivery           │  (state machine,      │
                 │ Expert bot (TS)    │───────────────────────────────────▶│   ERC-20 custody)     │
                 └────────────────────┘                                    │                       │
                 ┌────────────────────┐   release / fail                   │                       │
                 │ Verifier bot (TS)  │───────────────────────────────────▶│                       │
                 └────────────────────┘                                    └──────────┬────────────┘
                          ▲  reads spec + delivery (IPFS / HTTPS / data:)             │ giveFeedback
                          │  watches events                                           ▼
                 ┌────────┴───────────┐   ownerOf / getAgentWallet  ┌──────────────────────────────┐
                 │ IdentityRegistry   │◀────────────────────────────│      ReputationRegistry       │
                 │ (ERC-8004, ERC-721)│                             │      (ERC-8004)               │
                 └────────────────────┘                             └──────────────────────────────┘
```

## Contracts

| Contract | Path | Role |
| --- | --- | --- |
| `TaskEscrow` | `contracts/TaskEscrow.sol` | Order state machine, ERC-20 custody, writes ERC-8004 feedback on settlement. No admin, fees, or upgradeability. |
| `IdentityRegistry` | `contracts/registries/IdentityRegistry.sol` | ERC-8004 Identity Registry: ERC-721 agent ids (from 1), agent URI, metadata, EIP-712/ERC-1271-verified `agentWallet` (cleared on transfer). |
| `ReputationRegistry` | `contracts/registries/ReputationRegistry.sol` | ERC-8004 Reputation Registry: `giveFeedback`, `revokeFeedback`, `appendResponse`, `getSummary`, `readFeedback`, `getClients`, `getLastIndex`, `getResponseCount`. |
| `FulfillmentFeedback` | `contracts/libraries/FulfillmentFeedback.sol` | Builds the ERC-8004 feedback file JSON on-chain (data URI + keccak256). |
| `MockUSDC` | `contracts/mocks/MockUSDC.sol` | 6-decimal ERC-20 with open `mint`, for testnets without USDC. |

The registries follow the ERC-8004 draft interfaces (`contracts/interfaces/`) with these deliberate
deviations: constructors instead of `initialize` (no proxies), no `readAllFeedback` (unbounded
array returns; indexers should use events), and no Validation Registry (the verifier verdict lives
in the escrow).

## Order lifecycle

```
             createOrder          agree(specHash)        fund
  (None) ──────────────▶ Created ────────────────▶ Agreed ──────▶ Funded ─────────────────────┐
           buyer                   expert                buyer        │ submitDelivery         │ refundExpired
                                   (spec frozen)                      ▼ expert                 │ now > deliverBy
                                                                 Delivered ────────────────────┤ (NotDelivered)
                                                   release (pass)     │   │ fail               │
                                                   verifier           │   │ verifier           │ refundExpired
                                                                      ▼   ▼                    │ now > deliveredAt
                                                        Verified(pass)   Verified(fail) ───────┤ + reviewWindow
                                                         │       │                             │ (NotVerified)
                                   approve (buyer)       │       │ approval_mode =             ▼
                                   or releaseExpired     │       │ approve_for_me          Refunded
                                   (anyone, after window)▼       ▼ (same tx)
                                                         Released

  Disputed: reserved in the enum, never entered.
```

| From | Call | Caller | To | Notes |
| --- | --- | --- | --- | --- |
| — | `createOrder(params)` | buyer | Created | Validates amount, `specHash`, `taskType`, `deliverBy > now`, `reviewWindow > 0`. Snapshots payee (`agentWallet`, else owner) and verifier. |
| Created | `agree(orderId, specHash)` | expert | Agreed | `specHash` must equal the proposed hash: the criteria are frozen here. |
| Agreed | `fund(orderId)` | buyer | Funded | Pulls `amount`; balance-delta check rejects fee-on-transfer tokens. |
| Funded | `submitDelivery(orderId, deliveryHash, deliveryURI)` | expert | Delivered | Only hash + URI on-chain. Late delivery is accepted (recorded `on_time = false`) until someone calls `refundExpired`. |
| Delivered | `release(orderId, resultHash, resultURI)` | verifier | Verified(pass), or Released if `ApproveForMe` | Within `deliveredAt + reviewWindow`. |
| Delivered | `fail(orderId, resultHash, resultURI)` | verifier | Verified(fail), then Refunded | Same window. Buyer refunded in the same tx. |
| Verified(pass) | `approve(orderId)` | buyer | Released | `approval_mode = user`. Approval after the window still works but marks the buyer late. |
| Verified(pass) | `releaseExpired(orderId)` | anyone | Released | Buyer silent past `verifiedAt + reviewWindow`. |
| Funded | `refundExpired(orderId)` | anyone | Refunded | `now > deliverBy`, nothing delivered. |
| Delivered | `refundExpired(orderId)` | anyone | Refunded | Verifier silent past `deliveredAt + reviewWindow`. |

"Expert" means any of the seller agent's payee, owner, `agentWallet`, or ERC-721 operator. The
buyer is the `createOrder` caller. The verifier is `params.verifier`, or the immutable
`defaultVerifier` (the protocol's bot) when zero. Self-dealing is rejected: the buyer cannot be the
seller's payee or owner, and the verifier cannot be the buyer, payee, or seller owner.

Timeouts: `deliverBy` (absolute, from the spec's `deadline`) and `reviewWindow` (seconds, reused for
both the verifier's window after delivery and the buyer's approval window after a pass).

## Off-chain data and hashes

Nothing but hashes and URIs goes on-chain. URIs can be `ipfs://`, `https://`, or `data:` (the demo
uses `data:application/json;base64,…` so it needs no pinning service).

### Delivery criteria (`specHash`)

The spec JSON follows the template in `PRODUCT_SPEC.md`:

```json
{
  "task_type": "design.logo",
  "title": "Guild logo",
  "price": {"token": "USDC", "amount": "5"},
  "deadline": "2026-10-14T12:00:00Z",
  "deliverables": [{"kind": "image/png", "min_size": "1024x1024", "count": 3}],
  "acceptance_criteria": [
    {"id": "c1", "type": "auto", "check": "file_format == png && size >= 1024"},
    {"id": "c2", "type": "llm", "check": "包含文字 'Guild'，风格简洁"}
  ],
  "approval_mode": "user",
  "revisions": 1
}
```

`specHash = keccak256(utf8(JCS(spec)))`, where JCS is the
[RFC 8785 JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785) (keys sorted by
UTF-16 code units, no whitespace, ES6 number formatting, minimal string escaping, raw UTF-8). In
TypeScript: `keccak256(toBytes(canonicalize(spec)))` with the `canonicalize` npm package and viem.
`TaskEscrow.hashSpec(bytes)` exposes the same hash for cross-checking. The test suite pins a
vector produced that way (`SPEC_JSON` in `test/utils/BaseTest.sol` hashes to `0xf1714183…83ac`;
see `test_specHash_matchesOffChainJcsVector`).

Consistency rules the agents enforce off-chain (the contract only sees the hash):
`task_type` = `OrderParams.taskType`, `price.amount` × 10^decimals = `amount`,
`deadline` = `deliverBy`, and `approval_mode` matches `OrderParams.approvalMode`.
`task_type` is restricted to `[a-z0-9_.-]{1,32}` on-chain because it doubles as an ERC-8004 tag.

### Delivery (`deliveryHash`)

A manifest listing the artifacts, for example
`{"files":["ipfs://…/1.png","ipfs://…/2.png","ipfs://…/3.png"]}`. `deliveryHash` is keccak256 of
the canonicalized manifest. The artifacts themselves are only referenced.

### Verification result (`resultHash`)

The structured per-criterion result (required by the spec for future discovery):

```json
{"passed": false, "results": [{"id": "c1", "passed": true}, {"id": "c2", "passed": false, "reason": "..."}]}
```

`resultHash` is keccak256 of its JCS form; the URI is emitted in `OrderVerified`. Only the overall
pass/fail is enforced on-chain.

## Reputation (ERC-8004)

Every settlement writes feedback from the escrow (the escrow is the ERC-8004 `clientAddress`):

| Outcome | Expert feedback | Buyer feedback (if `buyerAgentId != 0`) |
| --- | --- | --- |
| Released | `passed = true`, `on_time = deliveredAt <= deliverBy` | `passed = true`, `on_time` = approved within the window (true for `approve_for_me`) |
| Refunded: verifier `fail` | `passed = false`, `on_time = deliveredAt <= deliverBy` | `passed = true`, `on_time = true` |
| Refunded: not delivered | `passed = false`, `on_time = false` | `passed = true`, `on_time = true` |
| Refunded: verifier silent | none (the expert is not at fault) | `passed = true`, `on_time = true` |

The `giveFeedback` arguments are:

- `value` = 100 if passed, 0 if not, with `valueDecimals = 0`. `getSummary` therefore returns a pass
  rate in percent.
- `tag1` = role (`"expert"` or `"buyer"`).
- `tag2` = `task_type`.
- `endpoint` is empty.
- `feedbackURI` = base64 `data:` URI of the feedback file below.
- `feedbackHash` = keccak256 of that file.

The feedback file is generated on-chain so no party can misstate it. It contains the ERC-8004
mandatory fields plus the product fields:

```json
{"agentRegistry":"eip155:10143:0x…","agentId":1,"clientAddress":"eip155:10143:0x…",
 "createdAt":"2026-10-13T08:00:00Z","value":100,"valueDecimals":0,"tag1":"expert","tag2":"design.logo",
 "role":"expert","task_type":"design.logo","amount":"5000000","token":"0x…","passed":true,"on_time":true,
 "outcome":"released","orderId":"1","specHash":"0x…","deliveryHash":"0x…","resultHash":"0x…"}
```

To read payment-backed reputation, query
`getSummary(agentId, [escrow], "expert", "design.logo")`. Filtering by the escrow as client ignores
feedback from arbitrary wallets, because every escrow entry is backed by a funded order. The
registry itself stays open, as ERC-8004 requires. `FulfillmentRecorded(orderId, agentId, role,
feedbackIndex, …)` links each order to its feedback, and `getOrder` stores both feedback indexes.

Reputation never blocks settlement. `giveFeedback` runs in `try/catch`. On failure the escrow
emits `ReputationWriteFailed` and the payment still moves. Feedback can fail, for example, if an
agent owner approves the escrow as an ERC-721 operator, which ERC-8004 treats as self-feedback.

## Suppliers

Negotiation and execution sit beside the contracts as vendor layers. Cursor Automations is the
negotiation host (HTTPS POST of `guild.negotiate/v0.1`). Grok Bot is the execution host (buyer,
expert, and verifier skills). Neither host client lives in this repository. The TypeScript
boundary those adapters implement is `agents/src/suppliers/`.

| Interface | File | In-repo adapter |
| --- | --- | --- |
| `NegotiationChannel` — `send(envelope)` / `onMessage` for `guild.negotiate/v0.1` | `agents/src/suppliers/channel.ts` | `createInMemoryChannel`. Same-process stand-in for a same-account `SendToAgent` demo. |
| `ExecutionRuntime` — buyer, expert, and verifier escrow calls | `agents/src/suppliers/runtime.ts` | `createReferenceRuntime`, over the viem + Privy or local-key clients in `agents/src/agents/`. |

If the channel or runtime host is down, new negotiations may fail. Funds already in `TaskEscrow`
stay reachable: release, refund, and timeout are contract calls.

## Off-chain agents (next PR: TypeScript + viem)

The logo demo runs the call sequence through `createReferenceRuntime`. The role functions below
are what that runtime delegates to.

All three agents are thin viem clients over the ABI in `out/` and the addresses in
`deployments/<chainId>.json` (`chainId`, `startBlock`, `paymentToken`, `identityRegistry`,
`reputationRegistry`, `defaultVerifier`, `taskEscrow`). Indexing starts at `startBlock`.

**Buyer agent** (acts for the user):

1. Picks an expert `agentId`. Discovery is out of scope, so the id is configured.
2. Fills the criteria template, pins it, computes `specHash`, and calls `createOrder`.
3. Waits for `OrderAgreed`, then calls `approve(escrow, amount)` on the token and `fund`.
4. In `user` mode, on `OrderVerified(passed = true)`, shows the result to the user and calls
   `approve(orderId)`.
5. Keeps a timer on `deliverBy` and calls `refundExpired` when `isRefundable` becomes true.

**Expert bot:**

1. Watches `OrderCreated` filtered by its `sellerAgentId` (indexed).
2. Fetches `specURI` and checks that `keccak256(JCS(spec)) == specHash` and that the price and
   deadline are acceptable.
3. Calls `agree(orderId, specHash)`.
4. On `OrderFunded`, produces the artifacts, pins the manifest, and calls `submitDelivery`.

**Verifier bot** (the protocol default, address = `defaultVerifier`, which is a Privy server
wallet):

1. Watches `OrderDelivered` where it is the order's verifier.
2. Re-checks the spec hash, then evaluates each acceptance criterion: `auto` checks run as code,
   `llm` checks go to a model.
3. Pins the result JSON and calls `release` or `fail` before `reviewDeadline(orderId)`.
4. Registers itself in the Identity Registry, as the spec requires. This is not enforced on-chain.
5. As a keeper, it can also call `releaseExpired` and `refundExpired`.

### Wallets (Privy server wallets)

The off-chain agents sign through Privy server wallets, following
[`PRIVY_NOTES.md`](./PRIVY_NOTES.md): `sendAs(role, tx)` over Privy's
`/v1/wallets/{id}/rpc` `eth_sendTransaction`, with gas and the pending nonce taken from the RPC. The
contracts know nothing about Privy. They only check `msg.sender` against addresses, so any wallet
that can send a transaction works, whether an EOA, a Privy wallet, or a smart account.

The note requires one wallet per role under a dedicated testnet Privy app, never one shared wallet.
The calls each role signs on `TaskEscrow`:

| Role | Privy env (per the note) | Signs | Address must be |
| --- | --- | --- | --- |
| Buyer | `PRIVY_WALLET_BUYER_ID` | `MockUSDC.approve(escrow)`, `createOrder`, `fund`, `approve` (user mode), `refundExpired` | the order's `buyer` (the `createOrder` sender) |
| Expert | `PRIVY_WALLET_EXPERT_ID` | `IdentityRegistry.register`, `agree`, `submitDelivery` | owner, `agentWallet` or operator of `sellerAgentId` |
| Verifier | `PRIVY_WALLET_VERIFIER_ID` | `IdentityRegistry.register`, `release` (pass), `fail` (refund), keeper calls | the order's `verifier`, by default `defaultVerifier` |
| Deployer | a fourth throwaway EOA or Privy wallet, not the buyer | `Deploy.s.sol` | — |

The note's "agree" for the buyer corresponds to `createOrder` + `fund`. It is the expert that calls
`agree(orderId, specHash)` to freeze the spec. The note's "verify → release" is a single
`release` call, plus a buyer `approve` in `user` mode.

Wiring notes:

- Deploy with `DEFAULT_VERIFIER` set to the Privy verifier wallet's address. `defaultVerifier` is
  immutable, so rotating that wallet means either redeploying `TaskEscrow` or having the buyer
  agent name the new address in `OrderParams.verifier` for each order.
- Payment goes to the expert agent's `agentWallet`, or its owner if none is set. Register the agent
  from the Privy expert wallet, or point `agentWallet` at it with `setAgentWallet`. Privy wallets
  can produce the EIP-712 signature that `setAgentWallet` needs.
- Chains: Base Sepolia is `eip155:84532`. For Monad testnet (chain id 10143), use the CAIP-2 that
  Privy lists. If Privy does not support it, the same addresses work on Base Sepolia, because the
  deployment is just a config switch.
- Privy credentials (`PRIVY_APP_ID`, `PRIVY_APP_SECRET`, and the wallet ids) belong to the
  TypeScript agents (next PR). They are not read by any Foundry script. Never commit them.
  `.gitignore` excludes `privy.json`, `wallet.json` and `wallets/`.
- `script/Demo.s.sol` signs with raw testnet keys (anvil keys locally) as a stand-in. The
  TypeScript demo replaces each `vm.broadcast(key)` with `sendAs(role, tx)`, in the same order.

**Events to index:** `OrderCreated`, `OrderAgreed`, `OrderFunded`, `OrderDelivered`,
`OrderVerified`, `OrderReleased`, `OrderRefunded`, `FulfillmentRecorded`, `ReputationWriteFailed`
(escrow), plus `Registered` and `NewFeedback` (registries). `script/Demo.s.sol` plays all three
roles in Solidity today and is the reference sequence for the TypeScript agents.

## Security notes

- Testnet MVP, unaudited. Deploy and Demo scripts refuse any chain other than Monad testnet (10143),
  Base Sepolia (84532), and anvil (31337).
- `nonReentrant` on every function that moves tokens. State is written before external calls, and
  the token transfer is the last call. Tests cover a reentrant token and fee-on-transfer rejection.
- The escrow balance always equals the sum of open (Funded/Delivered/Verified) orders, and tokens
  are conserved. Both are checked as invariants (`test/TaskEscrow.invariant.t.sol`).
- The verifier is trusted for the verdict. There is no dispute path (Disputed is reserved), so a
  malicious or compromised verifier can fail good work, pass bad work, or (by staying silent) force
  a refund after the review window.
- A USDC-style blacklist on the payee or buyer would make settlement revert, leaving funds stuck
  until the address is unblocked. `MockUSDC` has no blacklist.
- Gas: settlement with two on-chain feedback writes costs about 0.8–0.9M gas, and `createOrder`
  about 230k. Monad charges for the gas *limit*, so the agents should estimate gas instead of
  padding it heavily.

## Open questions

1. **Verifier trust and rotation.** Buyer-chosen or protocol-default, with no allowlist and no
   on-chain check that the verifier is registered. `defaultVerifier` is immutable.
2. **Reputation semantics.** On a verifier timeout, the expert gets no feedback. A buyer is always
   `passed = true`, and `on_time` is false only when the buyer approves late. Should a buyer that
   never approves get a negative entry?
3. **Sybil and wash trading.** Filtering by `clientAddress = escrow` proves payment, not
   independence: one person can fund orders to their own expert agent through two wallets.
4. **Late delivery** is accepted until someone triggers `refundExpired`. An alternative is a hard
   cutoff at `deliverBy`.
5. **`refundExpired` is permissionless.** The spec says the Buyer can reclaim. Anyone can trigger
   it, but funds always go to the buyer.
6. **No cancel for Created/Agreed orders.** No funds are at risk, but stale orders stay in the
   Created/Agreed state.
7. **Payee snapshot.** The payee is fixed at `createOrder`. Transferring the agent NFT afterwards
   does not redirect payment.
8. **`revisions`** from the template are not modelled on-chain. A fail refunds immediately.
9. **ERC-8004 is a draft.** Interfaces may change (for example `readAllFeedback` and the
   Validation Registry).
