import type { Address, Hex } from "viem";
import type { TxRequest } from "./types.js";

/**
 * Supplier id for escrow signing. Same split as NegotiationChannel:
 * orchestration depends on {@link EscrowWallet}, not on a vendor module.
 *
 * - `PrivyShared` — official Guild demo bot (`agents/src/wallet/privy.ts`). Path A.
 * - `LocalEoa` — public skill / self-host (`agents/src/wallet/local.ts`). Path B.
 * - `UserAaSession` — social-login account abstraction. Not implemented.
 *
 * ZeroDev / a paymaster is an optional later UX upgrade on an AA path, not the
 * self-host default.
 */
export type WalletVendor = "PrivyShared" | "LocalEoa" | "UserAaSession";

export interface EscrowWallet {
  getAddress(): Address;
  /** Sign and broadcast one escrow (or token) step. Today's `TxSender.send`. */
  sendEscrowStep(tx: TxRequest): Promise<Hex>;
  /** PrivyShared creates server wallets when ids are missing. LocalEoa omits this. */
  createIfNeeded?(): Promise<void>;
  /** Where to get testnet gas for {@link getAddress}. */
  fundHint(): string;
}

export function walletVendor(signing: "privy" | "local"): WalletVendor {
  return signing === "privy" ? "PrivyShared" : "LocalEoa";
}

/** Faucet (or prefunded anvil) hint for the address that must send the next transaction. */
export function fundHint(chainId: number, address?: Address): string {
  const who = address ? ` for ${address}` : "";
  if (chainId === 10143) {
    return `Fund native MON${who} from the Monad testnet faucet: https://faucet.monad.xyz`;
  }
  if (chainId === 84532) {
    return `Fund native ETH${who} from a Base Sepolia faucet: https://portal.cdp.coinbase.com/products/faucet`;
  }
  if (chainId === 31337) {
    return `Anvil dev accounts are prefunded${who}. No faucet.`;
  }
  return `Fund native gas${who} from a testnet faucet for chain ${chainId}.`;
}
