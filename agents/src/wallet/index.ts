import type { ChainConfig } from "../chain.js";
import { createLocalSender } from "./local.js";
import { createPrivySender, privyConfigFromEnv } from "./privy.js";
import type { Role, TxSender } from "./types.js";

export type { Role, TxRequest, TxSender } from "./types.js";

export function createRoleSenders(chain: ChainConfig): Record<Role, TxSender> {
  const privy = privyConfigFromEnv();
  if (privy) {
    return {
      buyer: createPrivySender("buyer", privy, chain),
      expert: createPrivySender("expert", privy, chain),
      verifier: createPrivySender("verifier", privy, chain),
    };
  }
  return {
    buyer: createLocalSender("buyer", chain),
    expert: createLocalSender("expert", chain),
    verifier: createLocalSender("verifier", chain),
  };
}

export function signingBackend(): "privy" | "local" {
  return privyConfigFromEnv() ? "privy" : "local";
}
