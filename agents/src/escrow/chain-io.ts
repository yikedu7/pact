import { createPublicClient, http, parseEventLogs, stringToHex, type Hex } from "viem";
import { identityRegistryAbi, taskEscrowAbi } from "../abi.js";
import type { ChainConfig } from "../chain.js";
import type { DeploymentFile } from "../deployments.js";
import { OrderStatus } from "../state.js";

export interface EscrowChainIo {
  blockTimestamp(): Promise<bigint>;
  onChainSpecHash(canonical: string): Promise<Hex>;
  nextOrderId(): Promise<bigint>;
  orderStatus(orderId: bigint): Promise<OrderStatus>;
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
      const order = await client.readContract({
        address: escrow,
        abi: taskEscrowAbi,
        functionName: "getOrder",
        args: [orderId],
      });
      return order.status as OrderStatus;
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
