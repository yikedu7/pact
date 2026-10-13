import { createPublicClient, http, parseEventLogs, stringToHex, type Address } from "viem";
import { identityRegistryAbi, reputationRegistryAbi, taskEscrowAbi } from "../abi.js";
import type { ChainConfig } from "../chain.js";
import type { DeploymentFile } from "../deployments.js";
import { OrderStatus, type DemoScenario } from "../state.js";
import {
  buildLogoSpec,
  deliveryHash,
  REVIEW_WINDOW_SEC,
  resultHash,
  resultUri,
  specHash,
  toDataUri,
  TASK_TYPE,
  type ApprovalModeLabel,
} from "../spec.js";
import { jcsCanonicalize } from "../hash.js";
import { createReferenceRuntime } from "../suppliers/runtime.js";

export interface DemoResult {
  orderId: bigint;
  expertAgentId: bigint;
  buyerAgentId: bigint;
  verifierAgentId: bigint;
  status: OrderStatus;
  txHashes: string[];
  signingBackend: "privy" | "local";
  expertPassRate?: bigint;
  expertFeedbackCount?: bigint;
}

function envBigint(name: string): bigint {
  const v = process.env[name];
  if (!v || v === "0") return 0n;
  return BigInt(v);
}

async function registerIfNeeded(
  register: (registry: Address, uri: string) => Promise<string>,
  registry: Address,
  existingId: bigint,
  uri: string,
  rpcUrl: string,
  txHashes: string[],
): Promise<bigint> {
  if (existingId !== 0n) return existingId;
  const hash = await register(registry, uri);
  txHashes.push(hash);
  const client = createPublicClient({ transport: http(rpcUrl) });
  const receipt = await client.getTransactionReceipt({ hash });
  const logs = parseEventLogs({ abi: identityRegistryAbi, logs: receipt.logs });
  const reg = logs.find((l) => l.eventName === "Registered");
  if (!reg || reg.args.agentId === undefined) {
    throw new Error("Failed to parse Registered event");
  }
  return reg.args.agentId;
}

async function readOrderStatus(
  escrow: Address,
  rpcUrl: string,
  orderId: bigint,
): Promise<OrderStatus> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  const order = await client.readContract({
    address: escrow,
    abi: taskEscrowAbi,
    functionName: "getOrder",
    args: [orderId],
  });
  return order.status as OrderStatus;
}

async function readNextOrderId(escrow: `0x${string}`, rpcUrl: string): Promise<bigint> {
  const client = createPublicClient({ transport: http(rpcUrl) });
  return client.readContract({
    address: escrow,
    abi: taskEscrowAbi,
    functionName: "nextOrderId",
  });
}

export async function runLogoDemo(opts: {
  chain: ChainConfig;
  deployment: DeploymentFile;
  scenario: DemoScenario;
  approvalMode: ApprovalModeLabel;
}): Promise<DemoResult> {
  const { chain, deployment, scenario, approvalMode } = opts;
  const runtime = createReferenceRuntime(chain);
  const backend = runtime.signingBackend;
  const txHashes: string[] = [];
  const publicClient = createPublicClient({ transport: http(chain.rpcUrl) });

  let expertAgentId = envBigint("EXPERT_AGENT_ID");
  let buyerAgentId = envBigint("BUYER_AGENT_ID");
  let verifierAgentId = envBigint("VERIFIER_AGENT_ID");

  expertAgentId = await registerIfNeeded(
    runtime.expert.register,
    deployment.identityRegistry,
    expertAgentId,
    "ipfs://guild-design-bot.json",
    chain.rpcUrl,
    txHashes,
  );
  buyerAgentId = await registerIfNeeded(
    runtime.buyer.register,
    deployment.identityRegistry,
    buyerAgentId,
    "ipfs://guild-buyer-agent.json",
    chain.rpcUrl,
    txHashes,
  );
  verifierAgentId = await registerIfNeeded(
    runtime.verifier.register,
    deployment.identityRegistry,
    verifierAgentId,
    "ipfs://guild-verifier-bot.json",
    chain.rpcUrl,
    txHashes,
  );

  const block = await publicClient.getBlock();
  const deliverBy = BigInt(Number(block.timestamp) + 86400);
  const spec = buildLogoSpec(approvalMode, Number(deliverBy));
  const canonical = jcsCanonicalize(spec);
  const hash = specHash(spec);
  const specUri = toDataUri(canonical);

  const onChainHash = await publicClient.readContract({
    address: deployment.taskEscrow,
    abi: taskEscrowAbi,
    functionName: "hashSpec",
    args: [stringToHex(canonical)],
  });
  if (onChainHash !== hash) {
    throw new Error(`spec hash mismatch: local ${hash} vs contract ${onChainHash}`);
  }

  const orderIdBefore = await readNextOrderId(deployment.taskEscrow, chain.rpcUrl);

  txHashes.push(
    ...(await runtime.buyer.preparePayment(
      deployment.paymentToken,
      deployment.taskEscrow,
      deployment.mockPaymentToken,
    )),
  );

  const { tx: createTx } = await runtime.buyer.createOrder({
    escrow: deployment.taskEscrow,
    paymentToken: deployment.paymentToken,
    mockPaymentToken: deployment.mockPaymentToken,
    sellerAgentId: expertAgentId,
    buyerAgentId,
    verifier: runtime.verifier.sender.address,
    spec,
    specUri,
    deliverBy,
    reviewWindow: REVIEW_WINDOW_SEC,
    approvalMode,
  });
  txHashes.push(createTx);

  const orderId = orderIdBefore;
  txHashes.push(await runtime.expert.agree(deployment.taskEscrow, orderId, hash));
  txHashes.push(await runtime.buyer.fund(deployment.taskEscrow, orderId));

  if (scenario === "timeout") {
    const status = await readOrderStatus(deployment.taskEscrow, chain.rpcUrl, orderId);
    return {
      orderId,
      expertAgentId,
      buyerAgentId,
      verifierAgentId,
      status,
      txHashes,
      signingBackend: backend,
    };
  }

  const dHash = deliveryHash();
  const dUri = toDataUri(
    '{"files":["ipfs://guild-logo-1.png","ipfs://guild-logo-2.png","ipfs://guild-logo-3.png"]}',
  );
  txHashes.push(await runtime.expert.deliver(deployment.taskEscrow, orderId, dHash, dUri));

  const pass = scenario === "pass" && runtime.verifier.evaluateCriteria(spec, true);
  if (pass) {
    txHashes.push(
      await runtime.verifier.release(
        deployment.taskEscrow,
        orderId,
        resultHash(true),
        resultUri(true),
      ),
    );
    if (approvalMode === "user") {
      txHashes.push(await runtime.buyer.approveOrder(deployment.taskEscrow, orderId));
    }
  } else {
    txHashes.push(
      await runtime.verifier.fail(
        deployment.taskEscrow,
        orderId,
        resultHash(false),
        resultUri(false),
      ),
    );
  }

  const status = await readOrderStatus(deployment.taskEscrow, chain.rpcUrl, orderId);

  let expertPassRate: bigint | undefined;
  let expertFeedbackCount: bigint | undefined;
  try {
    const summary = await publicClient.readContract({
      address: deployment.reputationRegistry,
      abi: reputationRegistryAbi,
      functionName: "getSummary",
      args: [expertAgentId, [deployment.taskEscrow], "expert", TASK_TYPE],
    });
    expertFeedbackCount = summary[0];
    expertPassRate = BigInt(summary[1]);
  } catch {
    // optional if registry unavailable
  }

  return {
    orderId,
    expertAgentId,
    buyerAgentId,
    verifierAgentId,
    status,
    txHashes,
    signingBackend: backend,
    expertPassRate,
    expertFeedbackCount,
  };
}
