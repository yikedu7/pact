import { createPublicClient, createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ANVIL_KEYS, type ChainConfig } from "../chain.js";
import type { Role, TxRequest, TxSender } from "./types.js";

function keyForRole(role: Role, chainId: number): Hex {
  const envKey =
    role === "buyer"
      ? process.env.BUYER_PRIVATE_KEY
      : role === "expert"
        ? process.env.EXPERT_PRIVATE_KEY
        : process.env.VERIFIER_PRIVATE_KEY;
  if (envKey) return envKey as Hex;
  if (chainId === 31337) {
    return ANVIL_KEYS[role];
  }
  throw new Error(`Missing ${role} private key (set ${role.toUpperCase()}_PRIVATE_KEY)`);
}

export function createLocalSender(role: Role, chain: ChainConfig): TxSender {
  const account = privateKeyToAccount(keyForRole(role, chain.chainId));
  const publicClient = createPublicClient({ transport: http(chain.rpcUrl) });
  const walletClient = createWalletClient({
    account,
    transport: http(chain.rpcUrl),
  });

  return {
    role,
    address: account.address,
    send: async (tx) => {
      const hash = await walletClient.sendTransaction({
        chain: null,
        account,
        to: tx.to,
        data: tx.data,
        value: tx.value ?? 0n,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") {
        throw new Error(`Transaction reverted: ${hash}`);
      }
      return hash;
    },
  };
}

export function localAddress(role: Role, chainId: number): Address {
  return privateKeyToAccount(keyForRole(role, chainId)).address;
}
