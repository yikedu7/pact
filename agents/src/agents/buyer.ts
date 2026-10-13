import type { Address, Hex } from "viem";
import {
  encodeApprove,
  encodeApproveOrder,
  encodeCreateOrder,
  encodeFund,
  encodeMint,
  encodeRegister,
} from "../encode.js";
import type { ApprovalModeLabel, TaskSpec } from "../spec.js";
import { PRICE_UNITS, specHash } from "../spec.js";
import type { TxSender } from "../wallet/types.js";

export async function buyerRegister(
  buyer: TxSender,
  registry: Address,
  agentUri = "ipfs://guild-buyer-agent.json",
): Promise<Hex> {
  return buyer.send(encodeRegister(agentUri, registry));
}

export interface BuyerCreateParams {
  escrow: Address;
  paymentToken: Address;
  mockPaymentToken: boolean;
  sellerAgentId: bigint;
  buyerAgentId: bigint;
  verifier: Address;
  spec: TaskSpec;
  specUri: string;
  deliverBy: bigint;
  reviewWindow: number;
  approvalMode: ApprovalModeLabel;
}

export async function buyerPreparePayment(
  buyer: TxSender,
  paymentToken: Address,
  escrow: Address,
  mockPaymentToken: boolean,
): Promise<string[]> {
  const txs: string[] = [];
  if (mockPaymentToken) {
    txs.push(await buyer.send(encodeMint(paymentToken, buyer.address, 100_000_000n)));
  }
  txs.push(await buyer.send(encodeApprove(paymentToken, escrow, PRICE_UNITS)));
  return txs;
}

export async function buyerCreateOrder(
  buyer: TxSender,
  p: BuyerCreateParams,
): Promise<{ specHash: `0x${string}`; tx: string }> {
  const hash = specHash(p.spec);
  const tx = await buyer.send(
    encodeCreateOrder({
      escrow: p.escrow,
      sellerAgentId: p.sellerAgentId,
      buyerAgentId: p.buyerAgentId,
      verifier: p.verifier,
      amount: PRICE_UNITS,
      spec: p.spec,
      specUri: p.specUri,
      deliverBy: p.deliverBy,
      reviewWindow: p.reviewWindow,
      approvalMode: p.approvalMode,
    }),
  );
  return { specHash: hash, tx };
}

export async function buyerFund(buyer: TxSender, escrow: Address, orderId: bigint): Promise<string> {
  return buyer.send(encodeFund(escrow, orderId));
}

export async function buyerApproveOrder(
  buyer: TxSender,
  escrow: Address,
  orderId: bigint,
): Promise<string> {
  return buyer.send(encodeApproveOrder(escrow, orderId));
}
