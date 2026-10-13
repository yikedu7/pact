import { encodeFunctionData, type Address, type Hex } from "viem";
import { erc20Abi, identityRegistryAbi, taskEscrowAbi } from "./abi.js";
import type { ApprovalModeLabel, TaskSpec } from "./spec.js";
import { approvalModeToContract, specHash } from "./spec.js";
import type { TxRequest } from "./wallet/types.js";

export function encodeRegister(agentUri: string, registry: Address): TxRequest {
  return {
    to: registry,
    data: encodeFunctionData({
      abi: identityRegistryAbi,
      functionName: "register",
      args: [agentUri],
    }),
  };
}

export function encodeMint(token: Address, to: Address, amount: bigint): TxRequest {
  return {
    to: token,
    data: encodeFunctionData({
      abi: erc20Abi,
      functionName: "mint",
      args: [to, amount],
    }),
  };
}

export function encodeApprove(token: Address, spender: Address, amount: bigint): TxRequest {
  return {
    to: token,
    data: encodeFunctionData({
      abi: erc20Abi,
      functionName: "approve",
      args: [spender, amount],
    }),
  };
}

export function encodeCreateOrder(args: {
  escrow: Address;
  sellerAgentId: bigint;
  buyerAgentId: bigint;
  verifier: Address;
  amount: bigint;
  spec: TaskSpec;
  specUri: string;
  deliverBy: bigint;
  reviewWindow: number;
  approvalMode: ApprovalModeLabel;
}): TxRequest {
  const hash = specHash(args.spec);
  return {
    to: args.escrow,
    data: encodeFunctionData({
      abi: taskEscrowAbi,
      functionName: "createOrder",
      args: [
        {
          sellerAgentId: args.sellerAgentId,
          buyerAgentId: args.buyerAgentId,
          verifier: args.verifier,
          amount: args.amount,
          specHash: hash,
          specURI: args.specUri,
          taskType: args.spec.task_type,
          deliverBy: args.deliverBy,
          reviewWindow: args.reviewWindow,
          approvalMode: approvalModeToContract(args.approvalMode),
        },
      ],
    }),
  };
}

export function encodeAgree(escrow: Address, orderId: bigint, hash: Hex): TxRequest {
  return {
    to: escrow,
    data: encodeFunctionData({
      abi: taskEscrowAbi,
      functionName: "agree",
      args: [orderId, hash],
    }),
  };
}

export function encodeFund(escrow: Address, orderId: bigint): TxRequest {
  return {
    to: escrow,
    data: encodeFunctionData({
      abi: taskEscrowAbi,
      functionName: "fund",
      args: [orderId],
    }),
  };
}

export function encodeSubmitDelivery(
  escrow: Address,
  orderId: bigint,
  deliveryHash: Hex,
  deliveryUri: string,
): TxRequest {
  return {
    to: escrow,
    data: encodeFunctionData({
      abi: taskEscrowAbi,
      functionName: "submitDelivery",
      args: [orderId, deliveryHash, deliveryUri],
    }),
  };
}

export function encodeRelease(
  escrow: Address,
  orderId: bigint,
  resultHash: Hex,
  resultUri: string,
): TxRequest {
  return {
    to: escrow,
    data: encodeFunctionData({
      abi: taskEscrowAbi,
      functionName: "release",
      args: [orderId, resultHash, resultUri],
    }),
  };
}

export function encodeFail(
  escrow: Address,
  orderId: bigint,
  resultHash: Hex,
  resultUri: string,
): TxRequest {
  return {
    to: escrow,
    data: encodeFunctionData({
      abi: taskEscrowAbi,
      functionName: "fail",
      args: [orderId, resultHash, resultUri],
    }),
  };
}

export function encodeApproveOrder(escrow: Address, orderId: bigint): TxRequest {
  return {
    to: escrow,
    data: encodeFunctionData({
      abi: taskEscrowAbi,
      functionName: "approve",
      args: [orderId],
    }),
  };
}
