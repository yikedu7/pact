import {
  createPublicClient,
  http,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import type { ChainConfig } from "../chain.js";
import type { Role, TxRequest, TxSender } from "./types.js";

const PRIVY_API = "https://api.privy.io";

export interface PrivyConfig {
  appId: string;
  appSecret: string;
  wallets: Record<Role, { walletId: string; address?: Address }>;
}

export function privyConfigFromEnv(): PrivyConfig | null {
  const appId = process.env.PRIVY_APP_ID;
  const appSecret = process.env.PRIVY_APP_SECRET;
  if (!appId || !appSecret) return null;

  const walletId = (role: Role) => {
    const key =
      role === "buyer"
        ? "PRIVY_WALLET_BUYER_ID"
        : role === "expert"
          ? "PRIVY_WALLET_EXPERT_ID"
          : "PRIVY_WALLET_VERIFIER_ID";
    const id = process.env[key];
    if (!id) throw new Error(`Missing ${key} for Privy signing`);
    const addrKey =
      role === "buyer"
        ? "PRIVY_WALLET_BUYER_ADDRESS"
        : role === "expert"
          ? "PRIVY_WALLET_EXPERT_ADDRESS"
          : "PRIVY_WALLET_VERIFIER_ADDRESS";
    const address = process.env[addrKey] as Address | undefined;
    return { walletId: id, address };
  };

  return {
    appId,
    appSecret,
    wallets: {
      buyer: walletId("buyer"),
      expert: walletId("expert"),
      verifier: walletId("verifier"),
    },
  };
}

async function privySendTransaction(
  cfg: PrivyConfig,
  role: Role,
  tx: TxRequest,
  chain: ChainConfig,
  publicClient: PublicClient,
): Promise<Hex> {
  const { walletId, address: expectedAddress } = cfg.wallets[role];
  const from = expectedAddress;
  if (!from) {
    throw new Error(
      `Set PRIVY_WALLET_${role.toUpperCase()}_ADDRESS for gas estimation (Privy path)`,
    );
  }

  const nonce = await publicClient.getTransactionCount({ address: from, blockTag: "pending" });
  const gas = await publicClient.estimateGas({
    account: from,
    to: tx.to,
    data: tx.data,
    value: tx.value ?? 0n,
  });

  const body = {
    method: "eth_sendTransaction",
    caip2: chain.caip2,
    params: {
      transaction: {
        to: tx.to,
        value: `0x${(tx.value ?? 0n).toString(16)}`,
        data: tx.data,
        chain_id: chain.chainId,
        gas_limit: `0x${gas.toString(16)}`,
        nonce,
      },
    },
  };

  const auth = Buffer.from(`${cfg.appId}:${cfg.appSecret}`).toString("base64");
  const res = await fetch(`${PRIVY_API}/v1/wallets/${walletId}/rpc`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "privy-app-id": cfg.appId,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const json = (await res.json()) as { data?: { hash?: Hex }; hash?: Hex; error?: { message?: string } };
  if (!res.ok) {
    throw new Error(`Privy RPC failed (${res.status}): ${JSON.stringify(json)}`);
  }
  const hash = json.data?.hash ?? json.hash;
  if (!hash) throw new Error(`Privy response missing tx hash: ${JSON.stringify(json)}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new Error(`Transaction reverted: ${hash}`);
  }
  return hash;
}

export function createPrivySender(
  role: Role,
  cfg: PrivyConfig,
  chain: ChainConfig,
): TxSender {
  const publicClient = createPublicClient({
    transport: http(chain.rpcUrl),
  });
  const address = cfg.wallets[role].address;
  if (!address) {
    throw new Error(`PRIVY_WALLET_${role.toUpperCase()}_ADDRESS is required`);
  }
  return {
    role,
    address,
    send: async (tx) => {
      try {
        return await privySendTransaction(cfg, role, tx, chain, publicClient);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (msg.includes("nonce too low")) {
          return await privySendTransaction(cfg, role, tx, chain, publicClient);
        }
        throw e;
      }
    },
  };
}
