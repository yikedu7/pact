import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  GuildPolicyError,
  assertFundWithinCaps,
  fileSpendLedger,
  memorySpendLedger,
  policyFromEnv,
} from "../src/policy.js";
import { formatUsdc, usdcAmountToUnits } from "../src/spec.js";

describe("USDC amounts", () => {
  it("parses whole and fractional demo prices", () => {
    expect(usdcAmountToUnits("5")).toBe(5_000_000n);
    expect(usdcAmountToUnits("5.5")).toBe(5_500_000n);
    expect(usdcAmountToUnits("0.000001")).toBe(1n);
    expect(formatUsdc(5_000_000n)).toBe("5");
    expect(formatUsdc(5_500_000n)).toBe("5.5");
  });

  it("rejects junk amounts", () => {
    expect(() => usdcAmountToUnits("5.1234567")).toThrow(/at most 6 places/);
    expect(() => usdcAmountToUnits("0")).toThrow(/greater than 0/);
    expect(() => usdcAmountToUnits("-1")).toThrow(/positive decimal/);
  });
});

describe("spend caps", () => {
  const now = new Date("2026-10-13T16:00:00Z");

  it("allows the 5 USDC demo under the default caps", () => {
    const ledger = memorySpendLedger();
    const { day } = assertFundWithinCaps(5_000_000n, policyFromEnv({}), ledger, now);
    expect(day).toBe("2026-10-13");
    ledger.record(day, 5_000_000n);
    expect(ledger.spentOn(day)).toBe(5_000_000n);
  });

  it("explains a per-transaction cap breach", () => {
    const ledger = memorySpendLedger();
    expect(() =>
      assertFundWithinCaps(10_000_000n, { txAmountCap: 5_000_000n, dailyAmountCap: 50_000_000n }, ledger, now),
    ).toThrow(GuildPolicyError);
    try {
      assertFundWithinCaps(10_000_000n, { txAmountCap: 5_000_000n, dailyAmountCap: 50_000_000n }, ledger, now);
    } catch (err) {
      expect(err).toBeInstanceOf(GuildPolicyError);
      expect((err as Error).message).toMatch(/Per-transaction cap exceeded/);
      expect((err as Error).message).toMatch(/10 USDC/);
      expect((err as Error).message).toMatch(/GUILD_TX_AMOUNT_CAP is 5 USDC/);
      expect((err as Error).message).toMatch(/Nothing was broadcast/);
    }
    expect(ledger.spentOn("2026-10-13")).toBe(0n);
  });

  it("explains a daily cap breach and persists the ledger", () => {
    const dir = mkdtempSync(join(tmpdir(), "guild-spend-"));
    const ledger = fileSpendLedger(join(dir, "spend-ledger.json"));
    const policy = { txAmountCap: 100_000_000n, dailyAmountCap: 6_000_000n };
    const { day } = assertFundWithinCaps(5_000_000n, policy, ledger, now);
    ledger.record(day, 5_000_000n);
    expect(() => assertFundWithinCaps(5_000_000n, policy, ledger, now)).toThrow(/Daily cap exceeded/);
    const reloaded = fileSpendLedger(join(dir, "spend-ledger.json"));
    expect(reloaded.spentOn(day)).toBe(5_000_000n);
  });

  it("reads cap env as base units", () => {
    expect(policyFromEnv({ GUILD_TX_AMOUNT_CAP: "5000000", GUILD_DAILY_AMOUNT_CAP: "10000000" })).toEqual({
      txAmountCap: 5_000_000n,
      dailyAmountCap: 10_000_000n,
    });
    expect(() => policyFromEnv({ GUILD_TX_AMOUNT_CAP: "5 USDC" })).toThrow(/GUILD_TX_AMOUNT_CAP/);
  });
});
