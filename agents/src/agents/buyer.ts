import type { Address } from "viem";
import {
  encodeApprove,
  encodeCreateOrder,
  encodeFund,
  encodeMint,
  encodeApproveOrder,
} from "../encode.js";
import type { ApprovalModeLabel, TaskSpec } from "../spec.js";
import { PRICE_UNITS, specHash, usdcAmountToUnits } from "../spec.js";
import type { TxSender } from "../wallet/types.js";

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
  amount: bigint = PRICE_UNITS,
): Promise<string[]> {
  const txs: string[] = [];
  if (mockPaymentToken) {
    const mintAmount = amount > 100_000_000n ? amount : 100_000_000n;
    txs.push(await buyer.send(encodeMint(paymentToken, buyer.address, mintAmount)));
  }
  txs.push(await buyer.send(encodeApprove(paymentToken, escrow, amount)));
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
      amount: usdcAmountToUnits(p.spec.price.amount),
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
