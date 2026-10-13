import type { Address, Hex } from "viem";
import { encodeFail, encodeRegister, encodeRelease } from "../encode.js";
import type { TaskSpec } from "../spec.js";
import type { TxSender } from "../wallet/types.js";

export async function verifierRegister(
  verifier: TxSender,
  registry: Address,
  agentUri = "ipfs://guild-verifier-bot.json",
): Promise<string> {
  return verifier.send(encodeRegister(agentUri, registry));
}

/** Demo verifier: trusts the scripted scenario; real checks would run auto/llm criteria. */
export function evaluateCriteria(_spec: TaskSpec, scenarioPass: boolean): boolean {
  return scenarioPass;
}

export async function verifierRelease(
  verifier: TxSender,
  escrow: Address,
  orderId: bigint,
  resultHash: Hex,
  resultUri: string,
): Promise<string> {
  return verifier.send(encodeRelease(escrow, orderId, resultHash, resultUri));
}

export async function verifierFail(
  verifier: TxSender,
  escrow: Address,
  orderId: bigint,
  resultHash: Hex,
  resultUri: string,
): Promise<string> {
  return verifier.send(encodeFail(escrow, orderId, resultHash, resultUri));
}
