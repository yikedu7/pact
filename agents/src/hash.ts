import { createRequire } from "node:module";
import { keccak256, toBytes, type Hex } from "viem";

const require = createRequire(import.meta.url);
const serialize = require("canonicalize") as (input: unknown) => string | undefined;

/** RFC 8785 (JCS) canonical JSON string for hashing. */
export function jcsCanonicalize(value: unknown): string {
  const out = serialize(value);
  if (out === undefined) {
    throw new Error("JCS canonicalize returned undefined (non-JSON value)");
  }
  return out;
}

/** `keccak256(utf8(JCS(value)))` — matches `TaskEscrow.hashSpec` for spec documents. */
export function hashJcs(value: unknown): Hex {
  return keccak256(toBytes(jcsCanonicalize(value)));
}

/** Raw UTF-8 bytes hash (used for delivery manifest / verifier result in the Foundry demo). */
export function hashUtf8(json: string): Hex {
  return keccak256(toBytes(json));
}
