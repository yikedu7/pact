import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname } from "node:path";
import { formatUsdc } from "./spec.js";

/** Default 100 USDC and 500 USDC (6 decimals). The 5 USDC demo fits; raise via env for larger tests. */
export const DEFAULT_TX_AMOUNT_CAP = 100_000_000n;
export const DEFAULT_DAILY_AMOUNT_CAP = 500_000_000n;

export interface SpendPolicy {
  txAmountCap: bigint;
  dailyAmountCap: bigint;
}

export interface SpendLedger {
  spentOn(day: string): bigint;
  record(day: string, amount: bigint): void;
}

export class GuildPolicyError extends Error {
  readonly code = "cap_exceeded" as const;

  constructor(message: string) {
    super(message);
    this.name = "GuildPolicyError";
  }
}

export function utcDay(now = new Date()): string {
  return now.toISOString().slice(0, 10);
}

function parseCap(raw: string | undefined, fallback: bigint, name: string): bigint {
  if (raw === undefined || raw.trim() === "") return fallback;
  if (!/^\d+$/.test(raw.trim())) {
    throw new Error(`${name} must be a non-negative integer of USDC base units (6 decimals), got ${JSON.stringify(raw)}.`);
  }
  return BigInt(raw.trim());
}

export function policyFromEnv(env: Record<string, string | undefined> = process.env): SpendPolicy {
  return {
    txAmountCap: parseCap(env.GUILD_TX_AMOUNT_CAP, DEFAULT_TX_AMOUNT_CAP, "GUILD_TX_AMOUNT_CAP"),
    dailyAmountCap: parseCap(env.GUILD_DAILY_AMOUNT_CAP, DEFAULT_DAILY_AMOUNT_CAP, "GUILD_DAILY_AMOUNT_CAP"),
  };
}

export function memorySpendLedger(initial: Record<string, bigint> = {}): SpendLedger {
  const book: Record<string, bigint> = { ...initial };
  return {
    spentOn(day) {
      return book[day] ?? 0n;
    },
    record(day, amount) {
      book[day] = (book[day] ?? 0n) + amount;
    },
  };
}

function readLedger(filePath: string): Record<string, bigint> {
  if (!existsSync(filePath)) return {};
  const raw = JSON.parse(readFileSync(filePath, "utf8")) as Record<string, string>;
  const out: Record<string, bigint> = {};
  for (const [day, value] of Object.entries(raw)) {
    out[day] = BigInt(value);
  }
  return out;
}

/** UTC-day totals in USDC base units. Path should stay under gitignored `wallets/`. */
export function fileSpendLedger(filePath: string): SpendLedger {
  return {
    spentOn(day) {
      return readLedger(filePath)[day] ?? 0n;
    },
    record(day, amount) {
      const all = readLedger(filePath);
      all[day] = (all[day] ?? 0n) + amount;
      mkdirSync(dirname(filePath), { recursive: true });
      const json = Object.fromEntries(Object.entries(all).map(([k, v]) => [k, v.toString()]));
      writeFileSync(filePath, `${JSON.stringify(json, null, 2)}\n`);
    },
  };
}

/**
 * Reject an escrow fund that would break the per-transaction or UTC-day cap.
 * Call before any transaction. Record the amount only after `fund` succeeds.
 */
export function assertFundWithinCaps(
  amount: bigint,
  policy: SpendPolicy,
  ledger: SpendLedger,
  now = new Date(),
): { day: string } {
  if (amount > policy.txAmountCap) {
    throw new GuildPolicyError(
      `Per-transaction cap exceeded: this order escrows ${formatUsdc(amount)} USDC ` +
        `(${amount} base units) but GUILD_TX_AMOUNT_CAP is ${formatUsdc(policy.txAmountCap)} USDC ` +
        `(${policy.txAmountCap}). Lower the price or raise the cap. Nothing was broadcast.`,
    );
  }
  const day = utcDay(now);
  const spent = ledger.spentOn(day);
  const next = spent + amount;
  if (next > policy.dailyAmountCap) {
    throw new GuildPolicyError(
      `Daily cap exceeded: today's escrowed total would be ${formatUsdc(next)} USDC ` +
        `(${next} base units), above GUILD_DAILY_AMOUNT_CAP of ${formatUsdc(policy.dailyAmountCap)} USDC ` +
        `(${policy.dailyAmountCap}). Nothing was broadcast.`,
    );
  }
  return { day };
}
