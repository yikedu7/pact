#!/usr/bin/env node
import { config as loadEnv } from "dotenv";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http } from "viem";
import { chainConfigFromEnv, resolveRpcUrl } from "./chain.js";
import { parseCliArgs } from "./cli-args.js";
import { loadDeployment, repoRootFromAgents } from "./deployments.js";
import { runLogoDemo } from "./demo/logo-demo.js";
import { runEscrowAfterAccept } from "./escrow/after-accept.js";
import { OrderStatus, parseScenario, statusLabel } from "./state.js";
import type { ApprovalModeLabel } from "./spec.js";
import { ensurePrivyRoleWallets, formatWalletSecretLines } from "./wallet/bootstrap.js";

const agentsDir = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: join(repoRootFromAgents(), ".env") });
loadEnv({ path: join(agentsDir, "..", ".env") });

function parseApprovalMode(raw: string): ApprovalModeLabel {
  if (raw === "user" || raw === "approve_for_me") return raw;
  throw new Error(`APPROVAL_MODE must be user or approve_for_me, got ${raw}`);
}

function readStdin(): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    process.stdin.on("data", (chunk: Buffer) => chunks.push(chunk));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", reject);
  });
}

async function readAcceptPayload(path: string): Promise<unknown> {
  const text = path === "-" ? await readStdin() : readFileSync(path, "utf8");
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new Error(`Accept payload is not JSON (${path === "-" ? "stdin" : path}).`);
  }
}

async function main(): Promise<void> {
  const args = parseCliArgs(process.argv.slice(2));

  if (args.bootstrapWallets) {
    const wallets = await ensurePrivyRoleWallets();
    if (!wallets) {
      throw new Error(
        "Set PRIVY_APP_ID and PRIVY_APP_SECRET to the shared Guild Privy app. " +
          "Creators do not apply for their own Privy app on the MVP path. Wallet ids are created on first run.",
      );
    }
    console.log(formatWalletSecretLines(wallets));
    return;
  }

  const localAnvil = args.localAnvil;

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

  if (args.afterAccept) {
    console.log(`after-accept ${args.afterAccept}`);
    const message = await readAcceptPayload(args.afterAccept);
    const result = await runEscrowAfterAccept({
      message,
      chain,
      deployment,
      scenario,
    });
    console.log("\nEscrow steps:");
    for (const step of result.steps) {
      console.log(`  ${step.role} ${step.step} ${step.tx}`);
    }
    console.log("\nResult:");
    console.log(`  orderId: ${result.orderId}`);
    console.log(`  status: ${statusLabel(result.status)} (${result.status})`);
    console.log(`  specHash: ${result.specHash}`);
    console.log(`  amount: ${result.amount} (USDC base units)`);
    console.log(`  approval_mode: ${result.approvalMode} (from the accepted task, not APPROVAL_MODE)`);
    console.log(`  signing: ${result.signingBackend}`);
    console.log(`  expertAgentId: ${result.expertAgentId}`);
    console.log(`  buyerAgentId: ${result.buyerAgentId}`);
    console.log(`  verifierAgentId: ${result.verifierAgentId}`);
    const expected =
      scenario === "timeout" ? OrderStatus.Funded : scenario === "fail" ? OrderStatus.Refunded : OrderStatus.Released;
    if (result.status !== expected) {
      console.warn(`  warning: expected terminal status ${statusLabel(expected)}, got ${statusLabel(result.status)}`);
      process.exitCode = 1;
    }
    return;
  }

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
