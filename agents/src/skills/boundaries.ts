import type { Role } from "../wallet/types.js";

/**
 * Demo path signers. Buyer signs create, fund, and release/fail (verifier = buyer).
 * Expert signs agree and submitDelivery. There is no required third wallet.
 */
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
  release: "buyer",
  fail: "buyer",
  approve: "buyer",
};

export const EXPERT_SIGN_STEPS: readonly EscrowSignStep[] = ["agree", "submitDelivery"];
export const BUYER_SIGN_STEPS: readonly EscrowSignStep[] = ["createOrder", "fund", "release", "fail", "approve"];

export function signerFor(step: EscrowSignStep): Role {
  return SIGNER[step];
}

/** Refuse a signature from the wrong role. Does not fall back to another wallet. */
export function assertEscrowSigner(role: Role, step: EscrowSignStep): void {
  const expected = SIGNER[step];
  if (role === expected) return;
  const allowed = role === "expert" ? EXPERT_SIGN_STEPS : BUYER_SIGN_STEPS;
  throw new Error(
    `${role} wallet cannot sign ${step}. The demo path signs ${step} with the ${expected} wallet. ` +
      `The ${role} wallet only signs ${allowed.join(", ")}. Nothing was broadcast.`,
  );
}
