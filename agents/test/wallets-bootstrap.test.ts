import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ensurePrivyRoleWallets, formatWalletSecretLines, privyAuthHeaders } from "../src/wallet/bootstrap.js";

const APP_SECRET = "guild-app-secret-not-for-git";
const CREATED = {
  buyer: { id: "wallet-buyer", address: "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" },
  expert: { id: "wallet-expert", address: "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc" },
  verifier: { id: "wallet-verifier", address: "0x90f79bf6eb2c4f870365e785982e1f101e93b906" },
} as const;

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("ensurePrivyRoleWallets", () => {
  it("creates buyer and expert wallets when ids are missing", async () => {
    const dir = mkdtempSync(join(tmpdir(), "guild-wallets-"));
    const filePath = join(dir, "guild-roles.json");
    const seen: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl: typeof fetch = async (input, init) => {
      const url = String(input);
      seen.push({ url, init: init ?? {} });
      const role = url.endsWith("buyer") ? "buyer" : url.endsWith("expert") ? "expert" : "verifier";
      const key = (init?.headers as Record<string, string>)["privy-idempotency-key"];
      const created = key?.endsWith("buyer") ? CREATED.buyer : key?.endsWith("expert") ? CREATED.expert : CREATED.verifier;
      expect(role).toBeTruthy();
      return new Response(JSON.stringify(created), { status: 200 });
    };

    const result = await ensurePrivyRoleWallets({
      env: { PRIVY_APP_ID: "guild-app", PRIVY_APP_SECRET: APP_SECRET },
      fetchImpl,
      filePath,
    });
    expect(result).not.toBeNull();
    expect(result!.created).toEqual(["buyer", "expert"]);
    expect(result!.config.wallets.buyer?.walletId).toBe("wallet-buyer");
    expect(result!.config.wallets.buyer?.address).toBe("0x70997970C51812dc3A010C7d01b50e0d17dc79C8");
    expect(seen).toHaveLength(2);
    for (const call of seen) {
      expect(call.url).toBe("https://api.privy.io/v1/wallets");
      const headers = call.init.headers as Record<string, string>;
      expect(headers["User-Agent"]).toBe("PrivyNodeJS/1.0");
      expect(headers["privy-app-id"]).toBe("guild-app");
      expect(JSON.parse(String(call.init.body))).toEqual({ chain_type: "ethereum" });
    }
    expect(seen.map((c) => (c.init.headers as Record<string, string>)["privy-idempotency-key"])).toEqual([
      "guild-escrow-server-wallet:buyer",
      "guild-escrow-server-wallet:expert",
    ]);

    const stored = readFileSync(filePath, "utf8");
    expect(stored).not.toContain(APP_SECRET);
    expect(stored).not.toContain("PRIVY_APP_SECRET");
    expect(formatWalletSecretLines(result!)).toContain("PRIVY_WALLET_BUYER_ID=wallet-buyer");
    expect(formatWalletSecretLines(result!)).toContain("PRIVY_WALLET_EXPERT_ID=wallet-expert");
    expect(formatWalletSecretLines(result!)).not.toContain("PRIVY_WALLET_VERIFIER_ID");
    expect(formatWalletSecretLines(result!)).not.toContain(APP_SECRET);

    const fetchAgain = vi.fn<typeof fetch>();
    const again = await ensurePrivyRoleWallets({
      env: { PRIVY_APP_ID: "guild-app", PRIVY_APP_SECRET: APP_SECRET },
      fetchImpl: fetchAgain,
      filePath,
    });
    expect(fetchAgain).not.toHaveBeenCalled();
    expect(again!.created).toEqual([]);
    expect(again!.source).toEqual({ buyer: "file", expert: "file" });
  });

  it("reuses env ids and fetches a missing address", async () => {
    const dir = mkdtempSync(join(tmpdir(), "guild-wallets-"));
    const fetchImpl: typeof fetch = async (input) => {
      expect(String(input)).toBe("https://api.privy.io/v1/wallets/wallet-expert");
      return new Response(
        JSON.stringify({ id: "wallet-expert", address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" }),
        { status: 200 },
      );
    };
    const result = await ensurePrivyRoleWallets({
      env: {
        PRIVY_APP_ID: "guild-app",
        PRIVY_APP_SECRET: APP_SECRET,
        PRIVY_WALLET_BUYER_ID: "wallet-buyer",
        PRIVY_WALLET_BUYER_ADDRESS: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        PRIVY_WALLET_EXPERT_ID: "wallet-expert",
        PRIVY_WALLET_VERIFIER_ID: "wallet-verifier",
        PRIVY_WALLET_VERIFIER_ADDRESS: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
      },
      fetchImpl,
      filePath: join(dir, "guild-roles.json"),
    });
    expect(result!.created).toEqual([]);
    expect(result!.source.expert).toBe("env");
    expect(result!.config.wallets.expert?.address).toBe("0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC");
  });

  it("explains Privy 403 without echoing the app secret", async () => {
    const fetchImpl: typeof fetch = async () => new Response(JSON.stringify({ error: "forbidden" }), { status: 403 });
    await expect(
      ensurePrivyRoleWallets({
        env: { PRIVY_APP_ID: "guild-app", PRIVY_APP_SECRET: APP_SECRET },
        fetchImpl,
        filePath: join(mkdtempSync(join(tmpdir(), "guild-wallets-")), "guild-roles.json"),
      }),
    ).rejects.toThrow(/HTTP 403/);
    try {
      await ensurePrivyRoleWallets({
        env: { PRIVY_APP_ID: "guild-app", PRIVY_APP_SECRET: APP_SECRET },
        fetchImpl,
        filePath: join(mkdtempSync(join(tmpdir(), "guild-wallets-")), "guild-roles.json"),
      });
    } catch (err) {
      expect((err as Error).message).toMatch(/User-Agent PrivyNodeJS\/1\.0/);
      expect((err as Error).message).not.toContain(APP_SECRET);
    }
  });

  it("returns null when the shared app secrets are unset", async () => {
    const fetchImpl = vi.fn<typeof fetch>();
    await expect(ensurePrivyRoleWallets({ env: {}, fetchImpl, filePath: "/tmp/unused.json" })).resolves.toBeNull();
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("sets the user agent on every Privy call", () => {
    expect(privyAuthHeaders("id", "secret")["User-Agent"]).toBe("PrivyNodeJS/1.0");
  });
});
