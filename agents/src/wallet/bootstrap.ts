import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, isAddress, type Address } from "viem";
import type { PrivyConfig } from "./privy.js";
import type { Role } from "./types.js";

export const PRIVY_API = "https://api.privy.io";
/** Privy returns 403 on server-wallet calls that omit this User-Agent. */
export const PRIVY_USER_AGENT = "PrivyNodeJS/1.0";

export const ROLES: readonly Role[] = ["buyer", "expert", "verifier"];

export const WALLET_ID_ENV: Record<Role, string> = {
  buyer: "PRIVY_WALLET_BUYER_ID",
  expert: "PRIVY_WALLET_EXPERT_ID",
  verifier: "PRIVY_WALLET_VERIFIER_ID",
};

export const WALLET_ADDRESS_ENV: Record<Role, string> = {
  buyer: "PRIVY_WALLET_BUYER_ADDRESS",
  expert: "PRIVY_WALLET_EXPERT_ADDRESS",
  verifier: "PRIVY_WALLET_VERIFIER_ADDRESS",
};

const IDEMPOTENCY_KEY: Record<Role, string> = {
  buyer: "guild-escrow-server-wallet:buyer",
  expert: "guild-escrow-server-wallet:expert",
  verifier: "guild-escrow-server-wallet:verifier",
};

export type WalletSource = "env" | "file" | "created";

export interface EnsureWalletsResult {
  config: PrivyConfig;
  created: Role[];
  source: Partial<Record<Role, WalletSource>>;
}

interface StoredRole {
  walletId: string;
  address?: string;
}

type Env = Record<string, string | undefined>;

export function privyAuthHeaders(
  appId: string,
  appSecret: string,
  extra?: Record<string, string>,
): Record<string, string> {
  const auth = Buffer.from(`${appId}:${appSecret}`).toString("base64");
  return {
    Authorization: `Basic ${auth}`,
    "privy-app-id": appId,
    "Content-Type": "application/json",
    "User-Agent": PRIVY_USER_AGENT,
    ...extra,
  };
}

export function defaultRoleWalletsPath(): string {
  if (process.env.GUILD_ROLE_WALLETS_FILE) return process.env.GUILD_ROLE_WALLETS_FILE;
  const here = dirname(fileURLToPath(import.meta.url));
  return join(here, "..", "..", "..", "wallets", "guild-roles.json");
}

function envValue(env: Env, key: string): string | undefined {
  const value = env[key];
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readStore(filePath: string): Partial<Record<Role, StoredRole>> {
  if (!existsSync(filePath)) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    throw new Error(`Could not read Guild wallet file ${filePath}. It must be JSON with buyer, expert, and verifier.`);
  }
  if (!parsed || typeof parsed !== "object") return {};
  return parsed as Partial<Record<Role, StoredRole>>;
}

function writeStore(filePath: string, wallets: Partial<PrivyConfig["wallets"]>): void {
  const existing = readStore(filePath);
  const body: Record<string, StoredRole> = {};
  for (const role of ROLES) {
    const next = wallets[role] ?? existing[role];
    if (!next?.walletId) continue;
    body[role] = { walletId: next.walletId, address: next.address };
  }
  mkdirSync(dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(body, null, 2)}\n`);
}

function asAddress(role: Role, raw: string): Address {
  if (!isAddress(raw)) {
    throw new Error(`Privy wallet ${role} returned an invalid address: ${raw}.`);
  }
  return getAddress(raw);
}

function walletFromJson(role: Role, json: unknown): { walletId: string; address: Address } {
  const record =
    json && typeof json === "object" && "data" in json && json.data && typeof json.data === "object"
      ? (json.data as Record<string, unknown>)
      : (json as Record<string, unknown>);
  const id = record?.id ?? record?.wallet_id;
  const address = record?.address;
  if (typeof id !== "string" || typeof address !== "string") {
    throw new Error(`Privy wallet response for ${role} is missing id or address.`);
  }
  return { walletId: id, address: asAddress(role, address) };
}

async function privyJson(
  fetchImpl: typeof fetch,
  appId: string,
  appSecret: string,
  path: string,
  init: { method: string; body?: string; headers?: Record<string, string> },
  role: Role,
): Promise<unknown> {
  const res = await fetchImpl(`${PRIVY_API}${path}`, {
    method: init.method,
    headers: privyAuthHeaders(appId, appSecret, init.headers),
    body: init.body,
  });
  const json = (await res.json().catch(() => ({}))) as unknown;
  if (!res.ok) {
    const hint =
      res.status === 403
        ? " Privy often returns 403 without User-Agent PrivyNodeJS/1.0, or when PRIVY_APP_ID / PRIVY_APP_SECRET do not match the shared Guild app."
        : "";
    throw new Error(
      `Privy wallet ${init.method} failed for ${role} (HTTP ${res.status}): ${JSON.stringify(json)}.${hint}`,
    );
  }
  return json;
}

export function formatWalletSecretLines(result: EnsureWalletsResult): string {
  const lines = [
    "Guild Privy server wallets are ready.",
    "Path A uses two wallets: give the buyer bot only the buyer id, and the expert bot only the expert id.",
    "Do not commit them. PRIVY_WALLET_VERIFIER_* is not part of the demo.",
    "",
  ];
  for (const role of ROLES) {
    const w = result.config.wallets[role];
    if (!w) continue;
    lines.push(`${WALLET_ID_ENV[role]}=${w.walletId}`);
    lines.push(`${WALLET_ADDRESS_ENV[role]}=${w.address ?? ""}`);
    lines.push(`# ${role}: ${result.source[role]}`);
  }
  lines.push("");
  lines.push("Reuse these ids on the next run. A new bootstrap without them creates another set of wallets.");
  return lines.join("\n");
}

/** Demo path wallets. Verifier is not included unless the caller opts in. */
export const DEMO_ROLES: readonly Role[] = ["buyer", "expert"];

/**
 * Resolve server wallets for the shared Guild Privy app.
 * The demo path creates buyer and expert only (`POST /v1/wallets`, chain_type ethereum).
 * Pass `roles` including `"verifier"` only for the optional non-demo wallet.
 * Returns null when `PRIVY_APP_ID` / `PRIVY_APP_SECRET` are unset (local keys).
 */
export async function ensurePrivyRoleWallets(opts?: {
  env?: Env;
  fetchImpl?: typeof fetch;
  filePath?: string;
  roles?: readonly Role[];
}): Promise<EnsureWalletsResult | null> {
  const env = opts?.env ?? process.env;
  const appId = envValue(env, "PRIVY_APP_ID");
  const appSecret = envValue(env, "PRIVY_APP_SECRET");
  if (!appId || !appSecret) return null;

  const fetchImpl = opts?.fetchImpl ?? fetch;
  const filePath = opts?.filePath ?? defaultRoleWalletsPath();
  const stored = readStore(filePath);
  const roles = opts?.roles ?? DEMO_ROLES;
  const wallets: PrivyConfig["wallets"] = {};
  const source: Partial<Record<Role, WalletSource>> = {};
  const created: Role[] = [];
  let dirty = false;

  for (const role of roles) {
    const envId = envValue(env, WALLET_ID_ENV[role]);
    const envAddress = envValue(env, WALLET_ADDRESS_ENV[role]);
    const fromFile = stored[role];

    let walletId = envId;
    let address = envAddress;
    let origin: WalletSource = "env";

    if (!walletId && fromFile?.walletId) {
      walletId = fromFile.walletId;
      address = address ?? fromFile.address;
      origin = "file";
    }

    if (!walletId) {
      const json = await privyJson(
        fetchImpl,
        appId,
        appSecret,
        "/v1/wallets",
        {
          method: "POST",
          headers: { "privy-idempotency-key": IDEMPOTENCY_KEY[role] },
          body: JSON.stringify({ chain_type: "ethereum" }),
        },
        role,
      );
      const createdWallet = walletFromJson(role, json);
      walletId = createdWallet.walletId;
      address = createdWallet.address;
      origin = "created";
      created.push(role);
      dirty = true;
    } else if (!address && fromFile?.walletId === walletId && fromFile.address) {
      address = fromFile.address;
    } else if (!address) {
      const json = await privyJson(fetchImpl, appId, appSecret, `/v1/wallets/${walletId}`, { method: "GET" }, role);
      address = walletFromJson(role, json).address;
      dirty = true;
    }

    if (!address) {
      throw new Error(`Privy wallet ${role} is missing an address.`);
    }
    const checksum = asAddress(role, address);
    wallets[role] = { walletId, address: checksum };
    source[role] = origin;
    if (origin === "created" || dirty) {
      writeStore(filePath, wallets);
      dirty = false;
    }
  }

  writeStore(filePath, wallets);
  const config: PrivyConfig = { appId, appSecret, wallets };
  return { config, created, source };
}
