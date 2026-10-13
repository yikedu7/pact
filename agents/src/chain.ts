export interface ChainConfig {
  chainId: number;
  caip2: string;
  rpcUrl: string;
  name: string;
}

const SUPPORTED = new Set([31337, 10143, 84532]);

export function assertSupportedChain(chainId: number): void {
  if (!SUPPORTED.has(chainId)) {
    throw new Error(`Unsupported chain id ${chainId} (expected 31337, 10143, or 84532)`);
  }
}

export function chainConfigFromEnv(chainId: number, rpcUrl: string): ChainConfig {
  assertSupportedChain(chainId);
  const caip2FromEnv = process.env.PRIVY_CAIP2;
  if (chainId === 31337) {
    return {
      chainId,
      rpcUrl,
      name: "anvil",
      caip2: caip2FromEnv ?? "eip155:31337",
    };
  }
  if (chainId === 10143) {
    return {
      chainId,
      rpcUrl,
      name: "monad-testnet",
      caip2: caip2FromEnv ?? "eip155:10143",
    };
  }
  return {
    chainId,
    rpcUrl,
    name: "base-sepolia",
    caip2: caip2FromEnv ?? "eip155:84532",
  };
}

export function resolveRpcUrl(): string {
  return (
    process.env.RPC_URL ??
    process.env.MONAD_TESTNET_RPC ??
    process.env.BASE_SEPOLIA_RPC ??
    "http://127.0.0.1:8545"
  );
}

/** Default anvil dev keys (accounts 1–3), matching `script/Demo.s.sol`. */
export const ANVIL_KEYS = {
  buyer: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const,
  expert: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" as const,
  verifier: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6" as const,
};
