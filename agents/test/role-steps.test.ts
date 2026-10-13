import { decodeFunctionData, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";
import { erc20Abi, taskEscrowAbi } from "../src/abi.js";
import { ANVIL_KEYS, type ChainConfig } from "../src/chain.js";
import type { DeploymentFile } from "../src/deployments.js";
import { ARCHIVED_DEFAULT_VERIFIER } from "../src/escrow/cue.js";
import type { EscrowChainIo, OnChainOrder } from "../src/escrow/chain-io.js";
import { runBuyerCreateOrFund, runBuyerRelease, runExpertAgreeOrDeliver } from "../src/escrow/role-steps.js";
import { hashJcs } from "../src/hash.js";
import { memorySpendLedger } from "../src/policy.js";
import { assertEscrowSigner } from "../src/skills/boundaries.js";
import { OrderStatus } from "../src/state.js";
import { createRoleSenders } from "../src/wallet/index.js";
import { privyRoleConfigFromEnv } from "../src/wallet/privy.js";
import type { Role, TxRequest, TxSender } from "../src/wallet/types.js";

const chain: ChainConfig = {
  chainId: 31337,
  caip2: "eip155:31337",
  rpcUrl: "http://127.0.0.1:8545",
  name: "anvil",
};

const deployment: DeploymentFile = {
  chainId: 31337,
  startBlock: 0,
  deployer: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  paymentToken: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  mockPaymentToken: true,
  identityRegistry: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  reputationRegistry: "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  defaultVerifier: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
  taskEscrow: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
};

const buyerAddress = privateKeyToAccount(ANVIL_KEYS.buyer).address;

function trackingSender(role: Role): TxSender & { sent: TxRequest[] } {
  const sent: TxRequest[] = [];
  return {
    role,
    address: privateKeyToAccount(ANVIL_KEYS[role]).address,
    sent,
    async send(tx) {
      sent.push(tx);
      return `0x${"11".repeat(32)}`;
    },
  };
}

function fnName(data: Hex): string {
  for (const abi of [taskEscrowAbi, erc20Abi]) {
    try {
      return decodeFunctionData({ abi, data }).functionName;
    } catch {
      // try the other abi
    }
  }
  throw new Error(`unrecognized calldata ${data}`);
}

function createVerifier(data: Hex): Address {
  const decoded = decodeFunctionData({ abi: taskEscrowAbi, data });
  if (decoded.functionName !== "createOrder") throw new Error(decoded.functionName);
  return (decoded.args[0] as { verifier: Address }).verifier;
}

function chainIo(script: Array<Partial<OnChainOrder> & { status: OrderStatus }>, time = 1_700_000_000n): EscrowChainIo {
  let i = 0;
  return {
    async blockTimestamp() {
      return time;
    },
    async onChainSpecHash(canonical) {
      return hashJcs(JSON.parse(canonical) as unknown);
    },
    async nextOrderId() {
      return 2n;
    },
    async getOrder() {
      const next = script[Math.min(i, script.length - 1)] ?? { status: OrderStatus.Created };
      i += 1;
      return {
        status: next.status,
        buyer: next.buyer ?? buyerAddress,
        verifier: next.verifier ?? buyerAddress,
        amount: next.amount ?? 5_000_000n,
        specHash: next.specHash ?? (`0x${"ab".repeat(32)}` as Hex),
        approvalMode: next.approvalMode ?? 1,
        deliverBy: next.deliverBy ?? 4_000_000_000n,
      };
    },
    async orderStatus() {
      return OrderStatus.Created;
    },
    async agentIdFromRegisterReceipt() {
      return 1n;
    },
  };
}

const accept = {
  protocol: "guild.negotiate/v0.1",
  type: "accept",
  body: {
    final_task: {
      task_type: "design.logo",
      title: "Guild logo",
      price: { token: "USDC", amount: "5" },
      deadline: "2099-01-01T00:00:00Z",
      approval_mode: "approve_for_me",
      revisions: 1,
    },
  },
};

const env = { EXPERT_AGENT_ID: "1", BUYER_AGENT_ID: "2" };
const policy = { txAmountCap: 100_000_000n, dailyAmountCap: 500_000_000n };

function base(sender: TxSender, io: EscrowChainIo, message: unknown = accept) {
  return {
    message,
    chain,
    deployment,
    sender,
    chainIo: io,
    ledger: memorySpendLedger(),
    now: new Date("2026-10-13T12:00:00Z"),
    env,
    policy,
    scenario: "pass" as const,
  };
}

describe("buyer create and fund", () => {
  it("creates an order with verifier equal to the buyer and does not sign expert steps", async () => {
    const buyer = trackingSender("buyer");
    const result = await runBuyerCreateOrFund(base(buyer, chainIo([{ status: OrderStatus.Created }])));
    expect(result.orderId).toBe(2n);
    expect(result.verifier).toBe(buyerAddress);
    expect(result.cue.body.step).toBe("expert-agree");
    expect(result.cue.body.verifier?.toLowerCase()).toBe(buyerAddress.toLowerCase());
    expect(result.cue.body.verifier?.toLowerCase()).not.toBe(ARCHIVED_DEFAULT_VERIFIER.toLowerCase());
    expect(result.steps.map((s) => `${s.role}:${s.step}`)).toEqual([
      "buyer:mint",
      "buyer:approveToken",
      "buyer:createOrder",
    ]);
    const create = buyer.sent.find((tx) => fnName(tx.data) === "createOrder");
    expect(create).toBeTruthy();
    expect(createVerifier(create!.data).toLowerCase()).toBe(buyerAddress.toLowerCase());
    expect(createVerifier(create!.data).toLowerCase()).not.toBe(deployment.defaultVerifier.toLowerCase());
    expect(createVerifier(create!.data).toLowerCase()).not.toBe(ARCHIVED_DEFAULT_VERIFIER.toLowerCase());
  });

  it("funds only when the order is Agreed", async () => {
    const buyer = trackingSender("buyer");
    const ledger = memorySpendLedger();
    const result = await runBuyerCreateOrFund({
      ...base(
        buyer,
        chainIo([
          { status: OrderStatus.Agreed, amount: 5_000_000n },
          { status: OrderStatus.Funded, amount: 5_000_000n },
        ]),
        {
          protocol: "guild.escrow/v0.1",
          type: "next",
          body: { step: "buyer-fund", orderId: "2", scenario: "pass" },
        },
      ),
      ledger,
    });
    expect(buyer.sent.map((tx) => fnName(tx.data))).toEqual(["fund"]);
    expect(result.cue.body.step).toBe("expert-deliver");
    expect(ledger.spentOn("2026-10-13")).toBe(5_000_000n);
  });

  it("stops when fund is requested before agree", async () => {
    const buyer = trackingSender("buyer");
    await expect(
      runBuyerCreateOrFund(
        base(buyer, chainIo([{ status: OrderStatus.Created }]), {
          protocol: "guild.escrow/v0.1",
          type: "next",
          body: { step: "buyer-fund", orderId: "2" },
        }),
      ),
    ).rejects.toThrow(/expected Agreed/);
    expect(buyer.sent).toHaveLength(0);
  });

  it("stops before any send when the cap or the message is wrong", async () => {
    const buyer = trackingSender("buyer");
    await expect(
      runBuyerCreateOrFund({
        ...base(buyer, chainIo([{ status: OrderStatus.Created }])),
        policy: { txAmountCap: 1n, dailyAmountCap: 1n },
      }),
    ).rejects.toThrow(/Per-transaction cap exceeded/);
    expect(buyer.sent).toHaveLength(0);

    await expect(
      runBuyerCreateOrFund(
        base(buyer, chainIo([{ status: OrderStatus.Created }]), {
          protocol: "guild.negotiate/v0.1",
          type: "offer",
          body: {},
        }),
      ),
    ).rejects.toThrow(/expert accept/);
    expect(buyer.sent).toHaveLength(0);
  });

  it("refuses a deadline that createOrder would reject", async () => {
    const buyer = trackingSender("buyer");
    await expect(
      runBuyerCreateOrFund(
        base(buyer, chainIo([{ status: OrderStatus.Created }], 1_700_000_000n), {
          protocol: "guild.negotiate/v0.1",
          type: "accept",
          body: {
            final_task: {
              ...accept.body.final_task,
              deadline: "2020-01-01T00:00:00Z",
            },
          },
        }),
      ),
    ).rejects.toThrow(/not in the future/);
    expect(buyer.sent).toHaveLength(0);
  });
});

describe("expert agree and deliver", () => {
  it("signs agree on Created and deliver on Funded", async () => {
    const expert = trackingSender("expert");
    const agreed = await runExpertAgreeOrDeliver(
      base(expert, chainIo([{ status: OrderStatus.Created }, { status: OrderStatus.Agreed }]), {
        protocol: "guild.escrow/v0.1",
        type: "next",
        body: { step: "expert-agree", orderId: "2", specHash: `0x${"ab".repeat(32)}` },
      }),
    );
    expect(expert.sent.map((tx) => fnName(tx.data))).toEqual(["agree"]);
    expect(agreed.cue.body.step).toBe("buyer-fund");

    expert.sent.length = 0;
    const delivered = await runExpertAgreeOrDeliver(
      base(expert, chainIo([{ status: OrderStatus.Funded }, { status: OrderStatus.Delivered }]), {
        protocol: "guild.escrow/v0.1",
        type: "next",
        body: { step: "expert-deliver", orderId: "2", scenario: "pass" },
      }),
    );
    expect(expert.sent.map((tx) => fnName(tx.data))).toEqual(["submitDelivery"]);
    expect(delivered.cue.body.step).toBe("buyer-release");
  });

  it("does not deliver on a timeout cue", async () => {
    const expert = trackingSender("expert");
    await expect(
      runExpertAgreeOrDeliver(
        base(expert, chainIo([{ status: OrderStatus.Funded }]), {
          protocol: "guild.escrow/v0.1",
          type: "next",
          body: { step: "expert-deliver", orderId: "2", scenario: "timeout" },
        }),
      ),
    ).rejects.toThrow(/timeout/);
    expect(expert.sent).toHaveLength(0);
  });
});

describe("buyer release", () => {
  it("releases with the buyer wallet when the order verifier is the buyer", async () => {
    const buyer = trackingSender("buyer");
    const result = await runBuyerRelease(
      base(
        buyer,
        chainIo([
          { status: OrderStatus.Delivered, approvalMode: 1 },
          { status: OrderStatus.Released, approvalMode: 1 },
          { status: OrderStatus.Released, approvalMode: 1 },
        ]),
        {
          protocol: "guild.escrow/v0.1",
          type: "next",
          body: { step: "buyer-release", orderId: "2", scenario: "pass" },
        },
      ),
    );
    expect(buyer.sent.map((tx) => fnName(tx.data))).toEqual(["release"]);
    expect(result.cue.body.step).toBe("done");
    expect(result.status).toBe(OrderStatus.Released);
  });

  it("fails the order with the buyer wallet", async () => {
    const buyer = trackingSender("buyer");
    const result = await runBuyerRelease(
      base(
        buyer,
        chainIo([
          { status: OrderStatus.Delivered, approvalMode: 1 },
          { status: OrderStatus.Refunded, approvalMode: 1 },
        ]),
        {
          protocol: "guild.escrow/v0.1",
          type: "next",
          body: { step: "buyer-release", orderId: "2", scenario: "fail" },
        },
      ),
    );
    expect(buyer.sent.map((tx) => fnName(tx.data))).toEqual(["fail"]);
    expect(result.status).toBe(OrderStatus.Refunded);
  });

  it("approves after release in user mode", async () => {
    const buyer = trackingSender("buyer");
    const result = await runBuyerRelease(
      base(
        buyer,
        chainIo([
          { status: OrderStatus.Delivered, approvalMode: 0 },
          { status: OrderStatus.Verified, approvalMode: 0 },
          { status: OrderStatus.Released, approvalMode: 0 },
        ]),
        {
          protocol: "guild.escrow/v0.1",
          type: "next",
          body: { step: "buyer-release", orderId: "2", scenario: "pass", approval_mode: "user" },
        },
      ),
    );
    expect(buyer.sent.map((tx) => fnName(tx.data))).toEqual(["release", "approve"]);
    expect(result.approvalMode).toBe("user");
  });

  it("stops when the order still names the archived verifier", async () => {
    const buyer = trackingSender("buyer");
    await expect(
      runBuyerRelease(
        base(buyer, chainIo([{ status: OrderStatus.Delivered, verifier: ARCHIVED_DEFAULT_VERIFIER as Address }]), {
          protocol: "guild.escrow/v0.1",
          type: "next",
          body: { step: "buyer-release", orderId: "2", scenario: "pass" },
        }),
      ),
    ).rejects.toThrow(/archived verifier/);
    expect(buyer.sent).toHaveLength(0);
  });
});

describe("role signing boundaries", () => {
  it("lets the buyer sign release and the expert sign agree and deliver", () => {
    expect(() => assertEscrowSigner("buyer", "createOrder")).not.toThrow();
    expect(() => assertEscrowSigner("buyer", "fund")).not.toThrow();
    expect(() => assertEscrowSigner("buyer", "release")).not.toThrow();
    expect(() => assertEscrowSigner("buyer", "fail")).not.toThrow();
    expect(() => assertEscrowSigner("expert", "agree")).not.toThrow();
    expect(() => assertEscrowSigner("expert", "submitDelivery")).not.toThrow();
    expect(() => assertEscrowSigner("expert", "fund")).toThrow(/expert wallet cannot sign fund/);
    expect(() => assertEscrowSigner("expert", "release")).toThrow(/buyer wallet/);
    expect(() => assertEscrowSigner("verifier", "release")).toThrow(/buyer wallet/);
    expect(() => assertEscrowSigner("buyer", "submitDelivery")).toThrow(/buyer wallet cannot sign submitDelivery/);
  });

  it("refuses to open every role wallet in one process", () => {
    expect(() => createRoleSenders()).toThrow(/one wallet per command/);
  });

  it("does not put expert or verifier wallet ids on a buyer Privy config", () => {
    const cfg = privyRoleConfigFromEnv("buyer", {
      PRIVY_APP_ID: "guild-app",
      PRIVY_APP_SECRET: "guild-secret",
      PRIVY_WALLET_BUYER_ID: "wallet-buyer",
      PRIVY_WALLET_BUYER_ADDRESS: buyerAddress,
      PRIVY_WALLET_EXPERT_ID: "expert-wallet-id-should-not-appear",
      PRIVY_WALLET_VERIFIER_ID: "verifier-wallet-id-should-not-appear",
    });
    const encoded = JSON.stringify(cfg);
    expect(cfg.wallets.buyer?.walletId).toBe("wallet-buyer");
    expect(cfg.wallets.expert).toBeUndefined();
    expect(cfg.wallets.verifier).toBeUndefined();
    expect(encoded).not.toContain("expert-wallet-id-should-not-appear");
    expect(encoded).not.toContain("verifier-wallet-id-should-not-appear");
  });
});
