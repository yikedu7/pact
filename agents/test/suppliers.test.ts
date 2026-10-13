import { decodeFunctionData, type Address, type Hex } from "viem";
import { describe, expect, it } from "vitest";
import { erc20Abi, identityRegistryAbi, taskEscrowAbi } from "../src/abi.js";
import type { ChainConfig } from "../src/chain.js";
import { buildLogoSpec } from "../src/spec.js";
import {
  assertNegotiateEnvelope,
  createInMemoryChannel,
  negotiateEnvelope,
  type NegotiateEnvelope,
} from "../src/suppliers/channel.js";
import { createExecutionRuntime, createReferenceRuntime } from "../src/suppliers/runtime.js";
import { localAddress } from "../src/wallet/local.js";
import type { Role, TxRequest, TxSender } from "../src/wallet/types.js";

const ESCROW = "0x00000000000000000000000000000000000000aa" as Address;
const TOKEN = "0x00000000000000000000000000000000000000bb" as Address;
const REGISTRY = "0x00000000000000000000000000000000000000cc" as Address;
const ZERO = "0x0000000000000000000000000000000000000001" as Address;

const TX_HASH =
  "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex;

function fakeSender(role: Role): TxSender & { txs: TxRequest[] } {
  const txs: TxRequest[] = [];
  return {
    role,
    address: ZERO,
    txs,
    async send(tx) {
      txs.push(tx);
      return TX_HASH;
    },
  };
}

describe("NegotiationChannel", () => {
  it("delivers guild.negotiate/v0.1 envelopes to subscribers", async () => {
    const channel = createInMemoryChannel();
    const got: NegotiateEnvelope[] = [];
    channel.onMessage((envelope) => {
      got.push(envelope);
    });

    const envelope = negotiateEnvelope({ kind: "propose" });
    await channel.send(envelope);

    expect(got).toEqual([envelope]);
    expect(envelope.schema).toBe("guild.negotiate/v0.1");
  });

  it("stops delivery after unsubscribe", async () => {
    const channel = createInMemoryChannel();
    const got: unknown[] = [];
    const unsubscribe = channel.onMessage((envelope) => {
      got.push(envelope.payload);
    });

    await channel.send(negotiateEnvelope("one"));
    unsubscribe();
    await channel.send(negotiateEnvelope("two"));

    expect(got).toEqual(["one"]);
  });

  it("rejects a different schema", async () => {
    const channel = createInMemoryChannel();
    const bad = { schema: "other", payload: {} } as unknown as NegotiateEnvelope;
    await expect(channel.send(bad)).rejects.toThrow(/guild\.negotiate\/v0\.1/);
    expect(() => assertNegotiateEnvelope(null)).toThrow(/empty/);
  });
});

describe("ExecutionRuntime", () => {
  it("delegates escrow calls to the existing role clients", async () => {
    const buyer = fakeSender("buyer");
    const expert = fakeSender("expert");
    const verifier = fakeSender("verifier");
    const runtime = createExecutionRuntime({ buyer, expert, verifier }, "local");

    await runtime.buyer.register(REGISTRY, "ipfs://guild-buyer-agent.json");
    await runtime.buyer.preparePayment(TOKEN, ESCROW, true);
    await runtime.buyer.fund(ESCROW, 7n);
    const specHash =
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as Hex;
    const deliveryHash =
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as Hex;
    await runtime.expert.agree(ESCROW, 7n, specHash);
    await runtime.expert.deliver(ESCROW, 7n, deliveryHash, "ipfs://delivery");
    await runtime.verifier.fail(
      ESCROW,
      7n,
      "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "ipfs://result",
    );

    expect(decodeFunctionData({ abi: identityRegistryAbi, data: buyer.txs[0]!.data }).functionName).toBe(
      "register",
    );
    expect(decodeFunctionData({ abi: erc20Abi, data: buyer.txs[1]!.data }).functionName).toBe("mint");
    expect(decodeFunctionData({ abi: erc20Abi, data: buyer.txs[2]!.data }).functionName).toBe("approve");
    const fund = decodeFunctionData({ abi: taskEscrowAbi, data: buyer.txs[3]!.data });
    expect(fund.functionName).toBe("fund");
    expect(fund.args[0]).toBe(7n);
    expect(buyer.txs[2]!.to).toBe(TOKEN);
    expect(buyer.txs[3]!.to).toBe(ESCROW);

    expect(decodeFunctionData({ abi: taskEscrowAbi, data: expert.txs[0]!.data }).functionName).toBe(
      "agree",
    );
    expect(
      decodeFunctionData({ abi: taskEscrowAbi, data: expert.txs[1]!.data }).functionName,
    ).toBe("submitDelivery");
    expect(decodeFunctionData({ abi: taskEscrowAbi, data: verifier.txs[0]!.data }).functionName).toBe(
      "fail",
    );
    expect(runtime.verifier.evaluateCriteria(buildLogoSpec("user", 1_700_086_400), false)).toBe(false);
    expect(runtime.signingBackend).toBe("local");
  });

  it("uses anvil role addresses when Privy is unset", () => {
    const savedId = process.env.PRIVY_APP_ID;
    const savedSecret = process.env.PRIVY_APP_SECRET;
    delete process.env.PRIVY_APP_ID;
    delete process.env.PRIVY_APP_SECRET;
    try {
      const chain: ChainConfig = {
        chainId: 31337,
        caip2: "eip155:31337",
        rpcUrl: "http://127.0.0.1:8545",
        name: "anvil",
      };
      const runtime = createReferenceRuntime(chain);
      expect(runtime.signingBackend).toBe("local");
      expect(runtime.buyer.sender.address).toBe(localAddress("buyer", 31337));
      expect(runtime.expert.sender.address).toBe(localAddress("expert", 31337));
      expect(runtime.verifier.sender.address).toBe(localAddress("verifier", 31337));
      expect(runtime.buyer.sender.role).toBe("buyer");
    } finally {
      if (savedId === undefined) delete process.env.PRIVY_APP_ID;
      else process.env.PRIVY_APP_ID = savedId;
      if (savedSecret === undefined) delete process.env.PRIVY_APP_SECRET;
      else process.env.PRIVY_APP_SECRET = savedSecret;
    }
  });
});
