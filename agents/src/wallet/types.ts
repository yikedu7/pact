import type { Address, Hex } from "viem";

export type Role = "buyer" | "expert" | "verifier";

export interface TxRequest {
  to: Address;
  data: Hex;
  value?: bigint;
}

export interface TxSender {
  role: Role;
  address: Address;
  send(tx: TxRequest): Promise<Hex>;
}
