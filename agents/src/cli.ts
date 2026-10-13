#!/usr/bin/env node
import { config as loadEnv } from "dotenv";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http } from "viem";
import { chainConfigFromEnv, resolveRpcUrl } from "./chain.js";
import { loadDeployment, repoRootFromAgents } from "./deployments.js";
import { runLogoDemo } from "./demo/logo-demo.js";
import { OrderStatus, parseScenario, statusLabel } from "./state.js";
import type { ApprovalModeLabel } from "./spec.js";

const agentsDir = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: join(repoRootFromAgents(), ".env") });
loadEnv({ path: join(agentsDir, "..", ".env") });

function parseApprovalMode(raw: string): ApprovalModeLabel {
  if (raw === "user" || raw === "approve_for_me") return raw;
  throw new Error(`APPROVAL_MODE must be user or approve_for_me, got ${raw}`);
}

async function main(): Promise<void> {
  const args = new Set(process.argv.slice(2));
  const localAnvil = args.has("--local-anvil");

  const rpcUrl = resolveRpcUrl();
  const publicClient = createPublicClient({ transport: http(rpcUrl) });
  const chainId = process.env.CHAIN_ID
    ? Number(process.env.CHAIN_ID)
    : await publicClient.getChainId();

  const chain = chainConfigFromEnv(chainId, rpcUrl);
  const deployment = loadDeployment(chainId);

  const scenario = parseScenario(process.env.SCENARIO ?? "pass");
  const approvalMode = parseApprovalMode(process.env.APPROVAL_MODE ?? "user");

  if (localAnvil && chainId !== 31337) {
    console.warn("--local-anvil: expected chain 31337, got", chainId);
  }

  console.log(`chain ${chain.name} (${chain.chainId}) via ${rpcUrl}`);
  console.log(`TaskEscrow ${deployment.taskEscrow}`);
  console.log(`scenario=${scenario} approval_mode=${approvalMode}`);

  const result = await runLogoDemo({
    chain,
    deployment,
    scenario,
    approvalMode,
  });

  console.log("\nTransactions:");
  for (const h of result.txHashes) {
    if (h) console.log(`  ${h}`);
  }

  console.log("\nResult:");
  console.log(`  orderId: ${result.orderId}`);
  console.log(`  status: ${statusLabel(result.status)} (${result.status})`);
  console.log(`  expertAgentId: ${result.expertAgentId}`);
  console.log(`  buyerAgentId: ${result.buyerAgentId}`);
  console.log(`  verifierAgentId: ${result.verifierAgentId}`);
  console.log(`  signing: ${result.signingBackend}`);
  if (result.expertFeedbackCount !== undefined) {
    console.log(
      `  expert design.logo feedback: count=${result.expertFeedbackCount} passRate%=${result.expertPassRate}`,
    );
  }

  const expected =
    scenario === "timeout"
      ? OrderStatus.Funded
      : scenario === "fail"
        ? OrderStatus.Refunded
        : OrderStatus.Released;

  if (result.status !== expected) {
    console.warn(`  warning: expected terminal status ${statusLabel(expected)}, got ${statusLabel(result.status)}`);
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
