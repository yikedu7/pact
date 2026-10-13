import type { Hex } from "viem";
import { hashJcs, hashUtf8 } from "./hash.js";

export const TASK_TYPE = "design.logo";
export const PRICE_AMOUNT = "5";
export const PRICE_UNITS = 5_000_000n; // 6 decimals
export const REVIEW_WINDOW_SEC = 3600;

/** Pinned JCS vector from `test/utils/BaseTest.sol` (`approval_mode: user`, fixed deadline). */
export const PINNED_SPEC_JSON =
  '{"acceptance_criteria":[{"check":"file_format == png && size >= 1024","id":"c1","type":"auto"},{"check":"包含文字 \'Guild\'，风格简洁","id":"c2","type":"llm"}],"approval_mode":"user","deadline":"2023-11-15T22:13:20Z","deliverables":[{"count":3,"kind":"image/png","min_size":"1024x1024"}],"price":{"amount":"5","token":"USDC"},"revisions":1,"task_type":"design.logo","title":"Guild logo"}';

export const PINNED_SPEC_HASH =
  "0xf17141832feb6a9f4c7f33ea2cc83f40f40d4f6ef18fe8445a2cd6a5fc7f83ac" as Hex;

export type ApprovalModeLabel = "user" | "approve_for_me";

export interface TaskSpec {
  task_type: string;
  title: string;
  price: { token: string; amount: string };
  deadline: string;
  deliverables: Array<{ kind: string; min_size: string; count: number }>;
  acceptance_criteria: Array<{ id: string; type: string; check: string }>;
  approval_mode: ApprovalModeLabel;
  revisions: number;
}

export function isoTimestampUnix(unixSeconds: number): string {
  const d = new Date(unixSeconds * 1000);
  const pad = (n: number) => n.toString().padStart(2, "0");
  return (
    `${d.getUTCFullYear()}-` +
    `${pad(d.getUTCMonth() + 1)}-` +
    `${pad(d.getUTCDate())}T` +
    `${pad(d.getUTCHours())}:` +
    `${pad(d.getUTCMinutes())}:` +
    `${pad(d.getUTCSeconds())}Z`
  );
}

/** Mirrors `Demo.specJsonFor` / `script/Demo.s.sol` template assembly. */
export function buildLogoSpec(approvalMode: ApprovalModeLabel, deliverByUnix: number): TaskSpec {
  return {
    acceptance_criteria: [
      { id: "c1", type: "auto", check: "file_format == png && size >= 1024" },
      { id: "c2", type: "llm", check: "包含文字 'Guild'，风格简洁" },
    ],
    approval_mode: approvalMode,
    deadline: isoTimestampUnix(deliverByUnix),
    deliverables: [{ kind: "image/png", min_size: "1024x1024", count: 3 }],
    price: { amount: PRICE_AMOUNT, token: "USDC" },
    revisions: 1,
    task_type: TASK_TYPE,
    title: "Guild logo",
  };
}

export function specHash(spec: TaskSpec): Hex {
  return hashJcs(spec);
}

export function toDataUri(json: string): string {
  return `data:application/json;base64,${Buffer.from(json, "utf8").toString("base64")}`;
}

export const DELIVERY_MANIFEST =
  '{"files":["ipfs://guild-logo-1.png","ipfs://guild-logo-2.png","ipfs://guild-logo-3.png"]}';

export const RESULT_PASS_JSON =
  '{"passed":true,"results":[{"id":"c1","passed":true},{"id":"c2","passed":true}]}';

export const RESULT_FAIL_JSON =
  '{"passed":false,"results":[{"id":"c1","passed":true},{"id":"c2","passed":false,"reason":"missing Guild text"}]}';

export function deliveryHash(): Hex {
  return hashUtf8(DELIVERY_MANIFEST);
}

export function resultHash(passed: boolean): Hex {
  return hashUtf8(passed ? RESULT_PASS_JSON : RESULT_FAIL_JSON);
}

export function resultUri(passed: boolean): string {
  return toDataUri(passed ? RESULT_PASS_JSON : RESULT_FAIL_JSON);
}

export function approvalModeToContract(mode: ApprovalModeLabel): 0 | 1 {
  return mode === "approve_for_me" ? 1 : 0;
}

const USDC_SCALE = 1_000_000n;

/** Parse a USDC decimal string (6 dp) into base units. `"5"` → `5000000`. */
export function usdcAmountToUnits(amount: string): bigint {
  if (!/^\d+(\.\d{1,6})?$/.test(amount)) {
    throw new Error(
      `USDC amount must be a positive decimal with at most 6 places, got ${JSON.stringify(amount)}.`,
    );
  }
  const [whole, frac = ""] = amount.split(".");
  const units = BigInt(whole) * USDC_SCALE + BigInt(frac.padEnd(6, "0"));
  if (units === 0n) {
    throw new Error("USDC amount must be greater than 0.");
  }
  return units;
}

/** `2026-10-20T14:51:26Z` → unix seconds. Does not rewrite the spec string. */
export function deadlineUnix(deadline: string): bigint {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(deadline)) {
    throw new Error(
      `Task deadline must be an ISO8601 UTC timestamp like 2026-10-20T14:51:26Z, got ${JSON.stringify(deadline)}.`,
    );
  }
  const ms = Date.parse(deadline);
  if (Number.isNaN(ms)) {
    throw new Error(`Task deadline is not a valid time: ${deadline}.`);
  }
  return BigInt(Math.floor(ms / 1000));
}

export function formatUsdc(units: bigint): string {
  const neg = units < 0n;
  const v = neg ? -units : units;
  const whole = v / USDC_SCALE;
  const frac = (v % USDC_SCALE).toString().padStart(6, "0").replace(/0+$/, "");
  const text = frac.length > 0 ? `${whole}.${frac}` : whole.toString();
  return neg ? `-${text}` : text;
}
