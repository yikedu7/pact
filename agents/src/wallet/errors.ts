import type { Address, PublicClient } from "viem";
import type { ChainConfig } from "../chain.js";
import type { Role, TxRequest } from "./types.js";

export class GuildTxError extends Error {
  readonly code: "no_gas" | "simulation_failed";

  constructor(code: "no_gas" | "simulation_failed", message: string) {
    super(message);
    this.name = "GuildTxError";
    this.code = code;
  }
}

function roleLabel(role: Role): string {
  return role.charAt(0).toUpperCase() + role.slice(1);
}

export function noGasMessage(role: Role, address: Address, chain: ChainConfig): string {
  return (
    `${roleLabel(role)} wallet ${address} cannot pay gas on ${chain.name} ` +
    `(chain ${chain.chainId}): the native balance is too low. ` +
    `Fund it from the testnet faucet, then retry. Nothing was broadcast.`
  );
}

export function simulationMessage(role: Role, address: Address, detail: string): string {
  const why = detail.trim() || "execution reverted";
  return (
    `Transaction simulation failed for the ${roleLabel(role)} wallet (${address}): ${why}. ` +
    `Nothing was broadcast.`
  );
}

function errorBlob(err: unknown): string {
  const parts: string[] = [];
  let cur: unknown = err;
  const seen = new Set<unknown>();
  while (cur && typeof cur === "object" && !seen.has(cur)) {
    seen.add(cur);
    if (cur instanceof Error) parts.push(cur.message);
    if ("shortMessage" in cur && typeof cur.shortMessage === "string") parts.push(cur.shortMessage);
    if ("details" in cur && typeof cur.details === "string") parts.push(cur.details);
    cur = "cause" in cur ? cur.cause : undefined;
  }
  if (parts.length === 0) parts.push(String(err));
  return parts.join("\n");
}

function errorDetail(err: unknown): string {
  if (err && typeof err === "object" && "shortMessage" in err && typeof err.shortMessage === "string") {
    return err.shortMessage;
  }
  if (err instanceof Error) return err.message.split("\n")[0] ?? err.message;
  return String(err);
}

const NO_GAS = /insufficient funds|exceeds the balance|gas required exceeds|insufficient balance/i;
const SIMULATION =
  /execution reverted|estimate ?gas|simulation failed|contract function .*reverted|ContractFunctionExecutionError/i;

/** Map RPC/estimate failures to operator-facing text. Post-broadcast reverts stay as-is. */
export function explainSendFailure(
  role: Role,
  address: Address,
  chain: ChainConfig,
  err: unknown,
): Error {
  if (err instanceof GuildTxError) return err;
  const text = errorBlob(err);
  if (/Transaction reverted: 0x/i.test(text)) {
    return err instanceof Error ? err : new Error(text);
  }
  if (NO_GAS.test(text)) return new GuildTxError("no_gas", noGasMessage(role, address, chain));
  if (SIMULATION.test(text)) {
    return new GuildTxError("simulation_failed", simulationMessage(role, address, errorDetail(err)));
  }
  return err instanceof Error ? err : new Error(text);
}

type GasClient = Pick<PublicClient, "getBalance" | "estimateGas">;

/** Balance + estimateGas before any broadcast. Returns the gas limit to submit. */
export async function assertSendable(
  publicClient: GasClient,
  args: { role: Role; from: Address; tx: TxRequest; chain: ChainConfig },
): Promise<bigint> {
  const balance = await publicClient.getBalance({ address: args.from });
  if (balance === 0n) {
    throw new GuildTxError("no_gas", noGasMessage(args.role, args.from, args.chain));
  }
  try {
    return await publicClient.estimateGas({
      account: args.from,
      to: args.tx.to,
      data: args.tx.data,
      value: args.tx.value ?? 0n,
    });
  } catch (err) {
    throw explainSendFailure(args.role, args.from, args.chain, err);
  }
}
