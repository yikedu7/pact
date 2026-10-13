import { createPublicClient, http, parseEventLogs, stringToHex, type Address, type Hex } from "viem";
import { identityRegistryAbi, taskEscrowAbi } from "../abi.js";
import type { ChainConfig } from "../chain.js";
import type { DeploymentFile } from "../deployments.js";
import { OrderStatus } from "../state.js";

/** Fields the role commands read before they sign. */
export interface OnChainOrder {
  status: OrderStatus;
  buyer: Address;
  verifier: Address;
  amount: bigint;
  specHash: Hex;
  /** 0 = user, 1 = approve_for_me. */
  approvalMode: number;
  deliverBy: bigint;
}

export interface EscrowChainIo {
  blockTimestamp(): Promise<bigint>;
  onChainSpecHash(canonical: string): Promise<Hex>;
  nextOrderId(): Promise<bigint>;
  orderStatus(orderId: bigint): Promise<OrderStatus>;
  getOrder(orderId: bigint): Promise<OnChainOrder>;
  agentIdFromRegisterReceipt(txHash: Hex): Promise<bigint>;
}

export function viemEscrowChain(chain: ChainConfig, deployment: DeploymentFile): EscrowChainIo {
  const client = createPublicClient({ transport: http(chain.rpcUrl) });
  const escrow = deployment.taskEscrow;
  return {
    async blockTimestamp() {
      const block = await client.getBlock();
      return block.timestamp;
    },
    async onChainSpecHash(canonical) {
      return client.readContract({
        address: escrow,
        abi: taskEscrowAbi,
        functionName: "hashSpec",
        args: [stringToHex(canonical)],
      });
    },
    async nextOrderId() {
      return client.readContract({
        address: escrow,
        abi: taskEscrowAbi,
        functionName: "nextOrderId",
      });
    },
    async orderStatus(orderId) {
      const order = await this.getOrder(orderId);
      return order.status;
    },
    async getOrder(orderId) {
      const order = await client.readContract({
        address: escrow,
        abi: taskEscrowAbi,
        functionName: "getOrder",
        args: [orderId],
      });
      return {
        status: Number(order.status) as OrderStatus,
        buyer: order.buyer,
        verifier: order.verifier,
        amount: order.amount,
        specHash: order.specHash,
        approvalMode: Number(order.approvalMode),
        deliverBy: order.deliverBy,
      };
    },
    async agentIdFromRegisterReceipt(txHash) {
      const receipt = await client.getTransactionReceipt({ hash: txHash });
      const logs = parseEventLogs({ abi: identityRegistryAbi, logs: receipt.logs });
      const reg = logs.find((l) => l.eventName === "Registered");
      if (!reg || reg.args.agentId === undefined) {
        throw new Error(`Register transaction ${txHash} did not emit Registered.`);
      }
      return reg.args.agentId;
    },
  };
}
