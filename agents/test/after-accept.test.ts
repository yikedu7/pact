import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeFunctionData, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";
import { erc20Abi, taskEscrowAbi } from "../src/abi.js";
import { ANVIL_KEYS, type ChainConfig } from "../src/chain.js";
import { repoRootFromAgents, type DeploymentFile } from "../src/deployments.js";
import { runEscrowAfterAccept } from "../src/escrow/after-accept.js";
import type { EscrowChainIo } from "../src/escrow/chain-io.js";
import { hashJcs } from "../src/hash.js";
import { memorySpendLedger } from "../src/policy.js";
import { assertEscrowSigner } from "../src/skills/boundaries.js";
import { OrderStatus } from "../src/state.js";
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

function chainIo(status: OrderStatus, time = 1_700_000_000n): EscrowChainIo & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    async blockTimestamp() {
      calls.push("blockTimestamp");
      return time;
    },
    async onChainSpecHash(canonical) {
      calls.push("onChainSpecHash");
      return hashJcs(JSON.parse(canonical) as unknown);
    },
    async nextOrderId() {
      calls.push("nextOrderId");
      return 2n;
    },
    async orderStatus(orderId) {
      calls.push(`orderStatus:${orderId}`);
      return status;
    },
    async agentIdFromRegisterReceipt() {
      calls.push("registerReceipt");
      return 1n;
    },
  };
}

const agentIds = { expert: 1n, buyer: 2n, verifier: 3n };

describe("buyer escrow after accept", () => {
  it("drives create → agree → fund → deliver → release on the role wallets", async () => {
    const record = JSON.parse(
      readFileSync(join(repoRootFromAgents(), "docs/demos/2026-10-13-dfcb9220/NEGOTIATION_dfcb9220.json"), "utf8"),
    ) as { final_task: { deadline: string } };
    record.final_task.deadline = "2099-01-01T00:00:00Z";
    const senders = {
      buyer: trackingSender("buyer"),
      expert: trackingSender("expert"),
      verifier: trackingSender("verifier"),
    };
    const io = chainIo(OrderStatus.Released);
    const ledger = memorySpendLedger();
    const result = await runEscrowAfterAccept({
      message: record,
      chain,
      deployment,
      scenario: "pass",
      senders,
      chainIo: io,
      ledger,
      now: new Date("2026-10-13T12:00:00Z"),
      agentIds,
      env: {},
      policy: { txAmountCap: 100_000_000n, dailyAmountCap: 500_000_000n },
    });

    expect(result.orderId).toBe(2n);
    expect(result.approvalMode).toBe("approve_for_me");
    expect(result.amount).toBe(5_000_000n);
    expect(result.steps.map((s) => `${s.role}:${s.step}`)).toEqual([
      "buyer:mint",
      "buyer:approveToken",
      "buyer:createOrder",
      "expert:agree",
      "buyer:fund",
      "expert:submitDelivery",
      "verifier:release",
    ]);
    expect(senders.buyer.sent.map((tx) => fnName(tx.data))).toEqual(["mint", "approve", "createOrder", "fund"]);
    expect(senders.expert.sent.map((tx) => fnName(tx.data))).toEqual(["agree", "submitDelivery"]);
    expect(senders.verifier.sent.map((tx) => fnName(tx.data))).toEqual(["release"]);
    expect(ledger.spentOn("2026-10-13")).toBe(5_000_000n);
    expect(senders.expert.sent.every((tx) => tx.to === deployment.taskEscrow)).toBe(true);
    expect(senders.verifier.sent.every((tx) => tx.to === deployment.taskEscrow)).toBe(true);
  });

  it("uses verifier fail and does not release when the scenario fails", async () => {
    const senders = {
      buyer: trackingSender("buyer"),
      expert: trackingSender("expert"),
      verifier: trackingSender("verifier"),
    };
    const result = await runEscrowAfterAccept({
      message: {
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
      },
      chain,
      deployment,
      scenario: "fail",
      senders,
      chainIo: chainIo(OrderStatus.Refunded),
      ledger: memorySpendLedger(),
      agentIds,
      env: {},
    });
    expect(result.steps.map((s) => `${s.role}:${s.step}`)).toContain("verifier:fail");
    expect(result.steps.map((s) => s.step)).not.toContain("release");
    expect(senders.verifier.sent.map((tx) => fnName(tx.data))).toEqual(["fail"]);
    expect(result.status).toBe(OrderStatus.Refunded);
  });

  it("asks the buyer to approve only in user mode", async () => {
    const senders = {
      buyer: trackingSender("buyer"),
      expert: trackingSender("expert"),
      verifier: trackingSender("verifier"),
    };
    const result = await runEscrowAfterAccept({
      message: {
        protocol: "guild.negotiate/v0.1",
        type: "accept",
        body: {
          final_task: {
            task_type: "design.logo",
            title: "Guild logo",
            price: { token: "USDC", amount: "5" },
            deadline: "2099-01-01T00:00:00Z",
            approval_mode: "user",
            revisions: 1,
          },
        },
      },
      chain,
      deployment,
      scenario: "pass",
      senders,
      chainIo: chainIo(OrderStatus.Released),
      ledger: memorySpendLedger(),
      agentIds,
      env: {},
    });
    expect(result.steps.map((s) => s.step)).toContain("approve");
    expect(senders.buyer.sent.map((tx) => fnName(tx.data))).toContain("approve");
    expect(senders.verifier.sent.map((tx) => fnName(tx.data))).toEqual(["release"]);
  });

  it("stops before any send when the cap is exceeded or the message is not an accept", async () => {
    const senders = {
      buyer: trackingSender("buyer"),
      expert: trackingSender("expert"),
      verifier: trackingSender("verifier"),
    };
    const message = {
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
    await expect(
      runEscrowAfterAccept({
        message,
        chain,
        deployment,
        senders,
        chainIo: chainIo(OrderStatus.Funded),
        ledger: memorySpendLedger(),
        agentIds,
        env: {},
        policy: { txAmountCap: 1n, dailyAmountCap: 1n },
      }),
    ).rejects.toThrow(/Per-transaction cap exceeded/);
    expect(senders.buyer.sent).toHaveLength(0);

    await expect(
      runEscrowAfterAccept({
        message: { protocol: "guild.negotiate/v0.1", type: "offer", body: {} },
        chain,
        deployment,
        senders,
        chainIo: chainIo(OrderStatus.Created),
        ledger: memorySpendLedger(),
        agentIds,
        env: {},
      }),
    ).rejects.toThrow(/expert accept/);
    expect(senders.expert.sent).toHaveLength(0);
  });

  it("refuses a deadline that createOrder would reject", async () => {
    const senders = {
      buyer: trackingSender("buyer"),
      expert: trackingSender("expert"),
      verifier: trackingSender("verifier"),
    };
    await expect(
      runEscrowAfterAccept({
        message: {
          protocol: "guild.negotiate/v0.1",
          type: "accept",
          body: {
            final_task: {
              task_type: "design.logo",
              title: "Guild logo",
              price: { token: "USDC", amount: "5" },
              deadline: "2020-01-01T00:00:00Z",
              approval_mode: "approve_for_me",
              revisions: 1,
            },
          },
        },
        chain,
        deployment,
        senders,
        chainIo: chainIo(OrderStatus.Created, 1_700_000_000n),
        ledger: memorySpendLedger(),
        agentIds,
        env: {},
      }),
    ).rejects.toThrow(/not in the future/);
    expect(senders.buyer.sent).toHaveLength(0);
  });
});

describe("role signing boundaries", () => {
  it("lets expert sign agree and deliver, and verifier sign release or fail", () => {
    expect(() => assertEscrowSigner("expert", "agree")).not.toThrow();
    expect(() => assertEscrowSigner("expert", "submitDelivery")).not.toThrow();
    expect(() => assertEscrowSigner("verifier", "release")).not.toThrow();
    expect(() => assertEscrowSigner("verifier", "fail")).not.toThrow();
    expect(() => assertEscrowSigner("expert", "fund")).toThrow(/expert skill cannot sign fund/);
    expect(() => assertEscrowSigner("verifier", "createOrder")).toThrow(/verifier skill cannot sign createOrder/);
    expect(() => assertEscrowSigner("buyer", "submitDelivery")).toThrow(/buyer skill cannot sign submitDelivery/);
  });

  it("uses three distinct addresses", () => {
    const addresses = (["buyer", "expert", "verifier"] as const).map(
      (role) => privateKeyToAccount(ANVIL_KEYS[role]).address,
    );
    expect(new Set(addresses.map((a: Address) => a.toLowerCase())).size).toBe(3);
  });
});
