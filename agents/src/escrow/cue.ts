import type { DemoScenario } from "../state.js";
import type { ApprovalModeLabel } from "../spec.js";

/** Handoff between the buyer bot and the expert bot. Same idea as guild.negotiate. */
export const ESCROW_PROTOCOL = "guild.escrow/v0.1";

/**
 * Monad deployment `defaultVerifier`. New orders do not use this address.
 * createOrder sets verifier to the buyer wallet.
 */
export const ARCHIVED_DEFAULT_VERIFIER = "0x7E70cCAB3c6862005988E1B2e31D76C35EFaC8A8";

export type CueStep = "expert-agree" | "buyer-fund" | "expert-deliver" | "buyer-release" | "done";

export interface EscrowCueBody {
  step: CueStep;
  orderId?: string;
  specHash?: string;
  approval_mode?: ApprovalModeLabel;
  amount?: string;
  sellerAgentId?: string;
  buyerAgentId?: string;
  verifier?: string;
  scenario?: DemoScenario;
  reason?: string;
}

export interface EscrowCue {
  protocol: typeof ESCROW_PROTOCOL;
  type: "next";
  body: EscrowCueBody;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

const STEPS: readonly CueStep[] = ["expert-agree", "buyer-fund", "expert-deliver", "buyer-release", "done"];

export function isArchivedVerifier(address: string): boolean {
  return address.toLowerCase() === ARCHIVED_DEFAULT_VERIFIER.toLowerCase();
}

export function isEscrowCue(message: unknown): boolean {
  return isRecord(message) && message.protocol === ESCROW_PROTOCOL;
}

export function parseEscrowCue(message: unknown): EscrowCue {
  if (!isRecord(message) || message.protocol !== ESCROW_PROTOCOL || message.type !== "next" || !isRecord(message.body)) {
    throw new Error(
      `Escrow handoff must be a ${ESCROW_PROTOCOL} "next" cue. Nothing was broadcast.`,
    );
  }
  const raw: Record<string, unknown> = message.body;
  const step = raw.step;
  if (typeof step !== "string" || !STEPS.includes(step as CueStep)) {
    throw new Error(`Unknown escrow cue step ${JSON.stringify(step)}. Nothing was broadcast.`);
  }
  const scenario = raw.scenario;
  if (scenario !== undefined && scenario !== "pass" && scenario !== "fail" && scenario !== "timeout") {
    throw new Error(`Cue scenario must be pass, fail, or timeout, got ${JSON.stringify(scenario)}.`);
  }
  const approval = raw.approval_mode;
  if (approval !== undefined && approval !== "user" && approval !== "approve_for_me") {
    throw new Error(`Cue approval_mode must be user or approve_for_me, got ${JSON.stringify(approval)}.`);
  }
  const body: EscrowCueBody = { step: step as CueStep };
  const copy = (
    key: "orderId" | "specHash" | "amount" | "sellerAgentId" | "buyerAgentId" | "verifier" | "reason",
  ) => {
    const value = raw[key];
    if (typeof value === "string") body[key] = value;
  };
  copy("orderId");
  copy("specHash");
  copy("amount");
  copy("sellerAgentId");
  copy("buyerAgentId");
  copy("verifier");
  copy("reason");
  if (approval === "user" || approval === "approve_for_me") body.approval_mode = approval;
  if (scenario === "pass" || scenario === "fail" || scenario === "timeout") body.scenario = scenario;
  return { protocol: ESCROW_PROTOCOL, type: "next", body };
}

export function makeCue(body: EscrowCueBody): EscrowCue {
  return { protocol: ESCROW_PROTOCOL, type: "next", body };
}

/**
 * POST the cue to a guild-relay URL when `GUILD_NEXT_RELAY_URL` is set.
 * The chain step has already succeeded; a relay failure is reported and the cue is still printed.
 */
export async function publishCue(
  cue: EscrowCue,
  env: Record<string, string | undefined> = process.env,
  fetchImpl: typeof fetch = fetch,
): Promise<string | undefined> {
  const url = env.GUILD_NEXT_RELAY_URL?.trim();
  if (!url) return undefined;
  const res = await fetchImpl(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(cue),
  });
  if (!res.ok) {
    return `Relay handoff failed (HTTP ${res.status}). The chain step succeeded. Pass the cue JSON on the CLI.`;
  }
  return `Posted cue to ${url}.`;
}
