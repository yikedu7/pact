import type { ChainConfig } from "../chain.js";
import { ensurePrivyRoleWallets } from "./bootstrap.js";
import { createLocalSender } from "./local.js";
import { createPrivySender } from "./privy.js";
import type { Role, TxSender } from "./types.js";

export type { Role, TxRequest, TxSender } from "./types.js";

export async function createRoleSenders(chain: ChainConfig): Promise<Record<Role, TxSender>> {
  const privy = await ensurePrivyRoleWallets();
  if (privy) {
    return {
      buyer: createPrivySender("buyer", privy.config, chain),
      expert: createPrivySender("expert", privy.config, chain),
      verifier: createPrivySender("verifier", privy.config, chain),
    };
  }
  return {
    buyer: createLocalSender("buyer", chain),
    expert: createLocalSender("expert", chain),
    verifier: createLocalSender("verifier", chain),
  };
}

/** `"privy"` is PrivyShared (path A). `"local"` is LocalEoa (path B). See `adapter.ts`. */
export function signingBackend(env: Record<string, string | undefined> = process.env): "privy" | "local" {
  const appId = env.PRIVY_APP_ID?.trim();
  const appSecret = env.PRIVY_APP_SECRET?.trim();
  return appId && appSecret ? "privy" : "local";
}
