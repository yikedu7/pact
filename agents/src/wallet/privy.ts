import {
  createPublicClient,
  http,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import type { ChainConfig } from "../chain.js";
import { PRIVY_API, WALLET_ADDRESS_ENV, WALLET_ID_ENV, privyAuthHeaders } from "./bootstrap.js";
import { assertSendable, explainSendFailure } from "./errors.js";
import type { Role, TxRequest, TxSender } from "./types.js";

export interface PrivyConfig {
  appId: string;
  appSecret: string;
  /** Only the wallets this process is allowed to sign with. */
  wallets: Partial<Record<Role, { walletId: string; address?: Address }>>;
}

type Env = Record<string, string | undefined>;

/**
 * One role only. Does not read the other roles' wallet id env vars, so a buyer
 * process cannot attach the expert or verifier wallet even if those vars exist.
 */
export function privyRoleConfigFromEnv(role: Role, env: Env = process.env): PrivyConfig {
  const appId = env.PRIVY_APP_ID?.trim();
  const appSecret = env.PRIVY_APP_SECRET?.trim();
  if (!appId || !appSecret) {
    throw new Error("PRIVY_APP_ID and PRIVY_APP_SECRET are required for Privy signing.");
  }
  const idKey = WALLET_ID_ENV[role];
  const id = env[idKey]?.trim();
  if (!id) {
    throw new Error(
      `This ${role} process signs only with ${idKey}. It is unset. Do not add another role's wallet id to this bot.`,
    );
  }
  const address = env[WALLET_ADDRESS_ENV[role]]?.trim() as Address | undefined;
  return {
    appId,
    appSecret,
    wallets: { [role]: { walletId: id, address } },
  };
}

export async function privySendTransaction(
  cfg: PrivyConfig,
  role: Role,
  tx: TxRequest,
  chain: ChainConfig,
  publicClient: PublicClient,
): Promise<Hex> {
  const wallet = cfg.wallets[role];
  if (!wallet) {
    throw new Error(
      `This process is not configured to sign as ${role}. It will not call Privy with another role's wallet id.`,
    );
  }
  const { walletId, address: expectedAddress } = wallet;
  const from = expectedAddress;
  if (!from) {
    throw new Error(
      `Set PRIVY_WALLET_${role.toUpperCase()}_ADDRESS for gas estimation (Privy path)`,
    );
  }

  const gas = await assertSendable(publicClient, { role, from, tx, chain });
  const nonce = await publicClient.getTransactionCount({ address: from, blockTag: "pending" });

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

  const res = await fetch(`${PRIVY_API}/v1/wallets/${walletId}/rpc`, {
    method: "POST",
    headers: privyAuthHeaders(cfg.appId, cfg.appSecret),
    body: JSON.stringify(body),
  });

  const json = (await res.json()) as { data?: { hash?: Hex }; hash?: Hex; error?: { message?: string } };
  if (!res.ok) {
    const hint =
      res.status === 403
        ? " Privy often returns 403 without User-Agent PrivyNodeJS/1.0, or when PRIVY_APP_ID / PRIVY_APP_SECRET do not match the shared Guild app."
        : "";
    throw new Error(`Privy RPC failed (${res.status}): ${JSON.stringify(json)}.${hint}`);
  }
  const hash = json.data?.hash ?? json.hash;
  if (!hash) throw new Error(`Privy response missing tx hash: ${JSON.stringify(json)}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    throw new Error(`Transaction reverted: ${hash}`);
  }
  return hash;
}

/** PrivyShared (path A, official Guild demo bot). End users do not set these secrets. */
export function createPrivySender(
  role: Role,
  cfg: PrivyConfig,
  chain: ChainConfig,
): TxSender {
  const publicClient = createPublicClient({
    transport: http(chain.rpcUrl),
  });
  const address = cfg.wallets[role]?.address;
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
          try {
            return await privySendTransaction(cfg, role, tx, chain, publicClient);
          } catch (retryErr) {
            throw explainSendFailure(role, address, chain, retryErr);
          }
        }
        throw explainSendFailure(role, address, chain, e);
      }
    },
  };
}
