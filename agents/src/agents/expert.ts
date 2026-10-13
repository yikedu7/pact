import type { Address, Hex } from "viem";
import { encodeAgree, encodeRegister, encodeSubmitDelivery } from "../encode.js";
import type { TxSender } from "../wallet/types.js";

export async function expertRegister(
  expert: TxSender,
  registry: Address,
  agentUri = "ipfs://guild-design-bot.json",
): Promise<Hex> {
  return expert.send(encodeRegister(agentUri, registry));
}

export async function expertAgree(
  expert: TxSender,
  escrow: Address,
  orderId: bigint,
  hash: Hex,
): Promise<string> {
  return expert.send(encodeAgree(escrow, orderId, hash));
}

export async function expertDeliver(
  expert: TxSender,
  escrow: Address,
  orderId: bigint,
  deliveryHash: Hex,
  deliveryUri: string,
): Promise<string> {
  return expert.send(encodeSubmitDelivery(escrow, orderId, deliveryHash, deliveryUri));
}
