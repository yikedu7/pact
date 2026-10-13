import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address } from "viem";

export interface DeploymentFile {
  chainId: number;
  startBlock: number;
  deployer: Address;
  paymentToken: Address;
  mockPaymentToken: boolean;
  identityRegistry: Address;
  reputationRegistry: Address;
  defaultVerifier: Address;
  taskEscrow: Address;
}

const agentsDir = dirname(fileURLToPath(import.meta.url));

export function repoRootFromAgents(): string {
  return join(agentsDir, "..", "..");
}

export function deploymentsPath(chainId: number, deploymentsDir?: string): string {
  const root = deploymentsDir ?? process.env.DEPLOYMENTS_DIR ?? join(repoRootFromAgents(), "deployments");
  return join(root, `${chainId}.json`);
}

export function loadDeployment(chainId: number, deploymentsDir?: string): DeploymentFile {
  const path = deploymentsPath(chainId, deploymentsDir);
  if (!existsSync(path)) {
    throw new Error(`Missing deployment file: ${path} (deploy contracts first)`);
  }
  const raw = JSON.parse(readFileSync(path, "utf8")) as DeploymentFile;
  if (raw.chainId !== chainId) {
    throw new Error(`Deployment chainId mismatch: file ${raw.chainId} vs expected ${chainId}`);
  }
  return raw;
}
