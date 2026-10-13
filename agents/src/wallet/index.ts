import type { ChainConfig } from "../chain.js";
import { createLocalSender } from "./local.js";
import { createPrivySender, privyRoleConfigFromEnv } from "./privy.js";
import type { Role, TxSender } from "./types.js";

export type { Role, TxRequest, TxSender } from "./types.js";

/**
 * Open exactly one role wallet. Privy calls use that role's wallet id only.
 * A buyer process must not call this with `"expert"` or `"verifier"`.
 */
export async function createRoleSender(
  chain: ChainConfig,
  role: Role,
  env: Record<string, string | undefined> = process.env,
): Promise<TxSender> {
  if (signingBackend(env) === "privy") {
    return createPrivySender(role, privyRoleConfigFromEnv(role, env), chain);
  }
  return createLocalSender(role, chain);
}

/**
 * All-in-one signing is not the demo path. Path A runs one wallet per process.
 */
export function createRoleSenders(): never {
  throw new Error(
    "Refusing to open Buyer and Expert wallets in one process. " +
      "Path A signs with one wallet per command: escrow:buyer-create-fund, escrow:expert-agree-deliver, escrow:buyer-release. " +
      "There is no required verifier wallet.",
  );
}

/** `"privy"` is PrivyShared (path A). `"local"` is LocalEoa (path B). See `adapter.ts`. */
export function signingBackend(env: Record<string, string | undefined> = process.env): "privy" | "local" {
  const appId = env.PRIVY_APP_ID?.trim();
  const appSecret = env.PRIVY_APP_SECRET?.trim();
  return appId && appSecret ? "privy" : "local";
}
