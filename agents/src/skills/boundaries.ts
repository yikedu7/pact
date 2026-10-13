import type { Role } from "../wallet/types.js";

/** On-chain escrow steps. Expert signs agree + deliver; verifier signs release or fail. */
export type EscrowSignStep =
  | "createOrder"
  | "agree"
  | "fund"
  | "submitDelivery"
  | "release"
  | "fail"
  | "approve";

const SIGNER: Record<EscrowSignStep, Role> = {
  createOrder: "buyer",
  agree: "expert",
  fund: "buyer",
  submitDelivery: "expert",
  release: "verifier",
  fail: "verifier",
  approve: "buyer",
};

export const EXPERT_SIGN_STEPS: readonly EscrowSignStep[] = ["agree", "submitDelivery"];
export const VERIFIER_SIGN_STEPS: readonly EscrowSignStep[] = ["release", "fail"];
export const BUYER_SIGN_STEPS: readonly EscrowSignStep[] = ["createOrder", "fund", "approve"];

export function signerFor(step: EscrowSignStep): Role {
  return SIGNER[step];
}

/**
 * Buyer orchestration may sequence every step, but each transaction is signed
 * only by that step's role wallet.
 */
export function assertEscrowSigner(role: Role, step: EscrowSignStep): void {
  const expected = SIGNER[step];
  if (role === expected) return;
  const allowed =
    role === "expert" ? EXPERT_SIGN_STEPS : role === "verifier" ? VERIFIER_SIGN_STEPS : BUYER_SIGN_STEPS;
  throw new Error(
    `${role} skill cannot sign ${step}. That step is signed by the ${expected} wallet. ` +
      `The ${role} wallet only signs ${allowed.join(", ")}.`,
  );
}
