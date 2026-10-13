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
