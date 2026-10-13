import type { Address, Hex } from "viem";

export type Role = "buyer" | "expert" | "verifier";

export interface TxRequest {
  to: Address;
  data: Hex;
  value?: bigint;
}

/**
 * Current send surface. `address` is `EscrowWallet.getAddress`, `send` is
 * `sendEscrowStep`. New vendors should implement `EscrowWallet` in `adapter.ts`
 * instead of growing this type.
 */
export interface TxSender {
  role: Role;
  address: Address;
  send(tx: TxRequest): Promise<Hex>;
}
