import { afterEach, describe, expect, it, vi } from "vitest";
import type { PublicClient } from "viem";
import type { ChainConfig } from "../src/chain.js";
import { assertSendable, explainSendFailure, GuildTxError } from "../src/wallet/errors.js";
import { privySendTransaction, type PrivyConfig } from "../src/wallet/privy.js";

const chain: ChainConfig = {
  chainId: 10143,
  caip2: "eip155:10143",
  rpcUrl: "http://127.0.0.1:8545",
  name: "monad-testnet",
};
const from = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const tx = {
  to: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9" as const,
  data: "0x1234" as const,
};

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("send failures", () => {
  it("turns an empty balance into a no-gas error", async () => {
    const client = {
      getBalance: async () => 0n,
      estimateGas: async () => {
        throw new Error("should not estimate");
      },
    } as unknown as PublicClient;
    await expect(assertSendable(client, { role: "buyer", from, tx, chain })).rejects.toThrow(GuildTxError);
    await expect(assertSendable(client, { role: "buyer", from, tx, chain })).rejects.toThrow(
      /Buyer wallet .* cannot pay gas on monad-testnet \(chain 10143\)/,
    );
  });

  it("turns an estimate revert into a simulation error and leaves post-broadcast reverts alone", () => {
    const sim = explainSendFailure("expert", from, chain, {
      shortMessage: "The contract function reverted",
      message: "execution reverted: InvalidDeadline",
    });
    expect(sim).toBeInstanceOf(GuildTxError);
    expect(sim.message).toMatch(/Transaction simulation failed for the Expert wallet/);
    expect(sim.message).toMatch(/Nothing was broadcast/);

    const mined = explainSendFailure("expert", from, chain, new Error(`Transaction reverted: 0x${"ab".repeat(32)}`));
    expect(mined).not.toBeInstanceOf(GuildTxError);
    expect(mined.message).toMatch(/Transaction reverted: 0x/);
  });

  it("does not call Privy when the buyer has no gas", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const cfg: PrivyConfig = {
      appId: "app",
      appSecret: "secret",
      wallets: {
        buyer: { walletId: "buyer-wallet", address: from },
        expert: { walletId: "expert-wallet", address: from },
        verifier: { walletId: "verifier-wallet", address: from },
      },
    };
    const client = {
      getBalance: async () => 0n,
      estimateGas: async () => 21_000n,
      getTransactionCount: async () => 0,
    } as unknown as PublicClient;
    await expect(privySendTransaction(cfg, "buyer", tx, chain, client)).rejects.toThrow(/cannot pay gas/);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("sends eth_sendTransaction with the PrivyNodeJS user agent", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ data: { hash: `0x${"cd".repeat(32)}` } }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const cfg: PrivyConfig = {
      appId: "guild-app",
      appSecret: "guild-secret",
      wallets: {
        buyer: { walletId: "buyer-wallet", address: from },
        expert: { walletId: "e", address: from },
        verifier: { walletId: "v", address: from },
      },
    };
    const client = {
      getBalance: async () => 1_000_000_000_000_000n,
      estimateGas: async () => 50_000n,
      getTransactionCount: async () => 4,
      waitForTransactionReceipt: async () => ({ status: "success" }),
    } as unknown as PublicClient;
    const hash = await privySendTransaction(cfg, "buyer", tx, chain, client);
    expect(hash).toBe(`0x${"cd".repeat(32)}`);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://api.privy.io/v1/wallets/buyer-wallet/rpc");
    const headers = init.headers as Record<string, string>;
    expect(headers["User-Agent"]).toBe("PrivyNodeJS/1.0");
    expect(headers.Authorization).toBe(`Basic ${Buffer.from("guild-app:guild-secret").toString("base64")}`);
    const body = JSON.parse(String(init.body)) as { caip2: string; method: string };
    expect(body.method).toBe("eth_sendTransaction");
    expect(body.caip2).toBe("eip155:10143");
  });
});
