import { dirname, join } from "node:path";
import { buyerApproveOrder, buyerCreateOrder, buyerFund, buyerPreparePayment } from "../agents/buyer.js";
import { expertAgree, expertDeliver } from "../agents/expert.js";
import { evaluateCriteria, verifierFail, verifierRelease } from "../agents/verifier.js";
import type { Hex } from "viem";
import type { ChainConfig } from "../chain.js";
import type { DeploymentFile } from "../deployments.js";
import { encodeRegister } from "../encode.js";
import { hashUtf8, jcsCanonicalize } from "../hash.js";
import { taskFromAccept } from "../negotiate.js";
import {
  assertFundWithinCaps,
  fileSpendLedger,
  policyFromEnv,
  type SpendLedger,
  type SpendPolicy,
} from "../policy.js";
import { assertEscrowSigner } from "../skills/boundaries.js";
import {
  deadlineUnix,
  DELIVERY_MANIFEST,
  REVIEW_WINDOW_SEC,
  resultHash,
  resultUri,
  specHash,
  toDataUri,
  usdcAmountToUnits,
  type TaskSpec,
} from "../spec.js";
import { OrderStatus, type DemoScenario } from "../state.js";
import { defaultRoleWalletsPath } from "../wallet/bootstrap.js";
import { createRoleSenders, signingBackend, type TxSender } from "../wallet/index.js";
import type { Role } from "../wallet/types.js";
import { viemEscrowChain, type EscrowChainIo } from "./chain-io.js";

export interface EscrowStepRecord {
  step: string;
  role: Role;
  tx: string;
}

export interface EscrowAfterAcceptResult {
  orderId: bigint;
  specHash: Hex;
  status: OrderStatus;
  steps: EscrowStepRecord[];
  signingBackend: "privy" | "local";
  amount: bigint;
  expertAgentId: bigint;
  buyerAgentId: bigint;
  verifierAgentId: bigint;
  approvalMode: TaskSpec["approval_mode"];
}

function envBigint(name: string, env: Record<string, string | undefined>): bigint {
  const v = env[name];
  if (!v || v === "0") return 0n;
  return BigInt(v);
}

function defaultSpendPath(): string {
  if (process.env.GUILD_SPEND_LEDGER) return process.env.GUILD_SPEND_LEDGER;
  return join(dirname(defaultRoleWalletsPath()), "spend-ledger.json");
}

async function registerIfNeeded(
  sender: TxSender,
  registry: DeploymentFile["identityRegistry"],
  existingId: bigint,
  uri: string,
  chainIo: EscrowChainIo,
  steps: EscrowStepRecord[],
): Promise<bigint> {
  if (existingId !== 0n) return existingId;
  const hash = await sender.send(encodeRegister(uri, registry));
  steps.push({ step: "register", role: sender.role, tx: hash });
  return chainIo.agentIdFromRegisterReceipt(hash);
}

/**
 * Buyer path after a `guild.negotiate/v0.1` accept.
 * Drives create → agree → fund → deliver → verify → release (then buyer
 * `approve` when `approval_mode` is `user`). Expert only signs agree and
 * deliver; verifier only signs release or fail.
 */
export async function runEscrowAfterAccept(opts: {
  message: unknown;
  chain: ChainConfig;
  deployment: DeploymentFile;
  scenario?: DemoScenario;
  senders?: Record<Role, TxSender>;
  chainIo?: EscrowChainIo;
  policy?: SpendPolicy;
  ledger?: SpendLedger;
  now?: Date;
  deliveryJson?: string;
  agentIds?: { expert?: bigint; buyer?: bigint; verifier?: bigint };
  env?: Record<string, string | undefined>;
}): Promise<EscrowAfterAcceptResult> {
  const env = opts.env ?? process.env;
  const task: TaskSpec = taskFromAccept(opts.message);
  const amount = usdcAmountToUnits(task.price.amount);
  const policy = opts.policy ?? policyFromEnv(env);
  const ledger = opts.ledger ?? fileSpendLedger(defaultSpendPath());
  const { day } = assertFundWithinCaps(amount, policy, ledger, opts.now ?? new Date());

  const chainIo = opts.chainIo ?? viemEscrowChain(opts.chain, opts.deployment);
  const deliverBy = deadlineUnix(task.deadline);
  const blockTime = await chainIo.blockTimestamp();
  if (deliverBy <= blockTime) {
    throw new Error(
      `Task deadline ${task.deadline} is not in the future on ${opts.chain.name} ` +
        `(block time ${blockTime}). createOrder would revert. Negotiate a later deadline. Nothing was broadcast.`,
    );
  }

  const senders = opts.senders ?? (await createRoleSenders(opts.chain));
  if (senders.buyer.role !== "buyer" || senders.expert.role !== "expert" || senders.verifier.role !== "verifier") {
    throw new Error("Role senders are mis-labeled. Refusing to sign an escrow step with the wrong wallet.");
  }
  const distinct = new Set(
    [senders.buyer.address, senders.expert.address, senders.verifier.address].map((a) => a.toLowerCase()),
  );
  if (distinct.size !== 3) {
    throw new Error(
      "Buyer, expert, and verifier must be three different wallets. Guild escrow rejects self-dealing. Nothing was broadcast.",
    );
  }

  const canonical = jcsCanonicalize(task);
  const hash = specHash(task);
  const onChainHash = await chainIo.onChainSpecHash(canonical);
  if (onChainHash !== hash) {
    throw new Error(
      `Frozen spec hash does not match TaskEscrow.hashSpec. Local ${hash} vs contract ${onChainHash}. Nothing was broadcast.`,
    );
  }

  const scenario = opts.scenario ?? "pass";
  const steps: EscrowStepRecord[] = [];
  const ids = opts.agentIds ?? {};
  const expertAgentId = await registerIfNeeded(
    senders.expert,
    opts.deployment.identityRegistry,
    ids.expert ?? envBigint("EXPERT_AGENT_ID", env),
    "ipfs://guild-design-bot.json",
    chainIo,
    steps,
  );
  const buyerAgentId = await registerIfNeeded(
    senders.buyer,
    opts.deployment.identityRegistry,
    ids.buyer ?? envBigint("BUYER_AGENT_ID", env),
    "ipfs://guild-buyer-agent.json",
    chainIo,
    steps,
  );
  const verifierAgentId = await registerIfNeeded(
    senders.verifier,
    opts.deployment.identityRegistry,
    ids.verifier ?? envBigint("VERIFIER_AGENT_ID", env),
    "ipfs://guild-verifier-bot.json",
    chainIo,
    steps,
  );

  const prep = await buyerPreparePayment(
    senders.buyer,
    opts.deployment.paymentToken,
    opts.deployment.taskEscrow,
    opts.deployment.mockPaymentToken,
    amount,
  );
  const prepLabels = opts.deployment.mockPaymentToken ? ["mint", "approveToken"] : ["approveToken"];
  prep.forEach((tx, i) => {
    steps.push({ step: prepLabels[i] ?? "approveToken", role: "buyer", tx });
  });

  const orderId = await chainIo.nextOrderId();
  assertEscrowSigner(senders.buyer.role, "createOrder");
  const created = await buyerCreateOrder(senders.buyer, {
    escrow: opts.deployment.taskEscrow,
    paymentToken: opts.deployment.paymentToken,
    mockPaymentToken: opts.deployment.mockPaymentToken,
    sellerAgentId: expertAgentId,
    buyerAgentId,
    verifier: senders.verifier.address,
    spec: task,
    specUri: toDataUri(canonical),
    deliverBy,
    reviewWindow: REVIEW_WINDOW_SEC,
    approvalMode: task.approval_mode,
  });
  steps.push({ step: "createOrder", role: "buyer", tx: created.tx });

  assertEscrowSigner(senders.expert.role, "agree");
  steps.push({
    step: "agree",
    role: "expert",
    tx: await expertAgree(senders.expert, opts.deployment.taskEscrow, orderId, hash),
  });

  assertEscrowSigner(senders.buyer.role, "fund");
  steps.push({
    step: "fund",
    role: "buyer",
    tx: await buyerFund(senders.buyer, opts.deployment.taskEscrow, orderId),
  });
  ledger.record(day, amount);

  if (scenario !== "timeout") {
    const manifest = opts.deliveryJson ?? DELIVERY_MANIFEST;
    const dHash = hashUtf8(manifest);
    const dUri = toDataUri(manifest);
    assertEscrowSigner(senders.expert.role, "submitDelivery");
    steps.push({
      step: "submitDelivery",
      role: "expert",
      tx: await expertDeliver(senders.expert, opts.deployment.taskEscrow, orderId, dHash, dUri),
    });

    const pass = scenario === "pass" && evaluateCriteria(task, true);
    if (pass) {
      assertEscrowSigner(senders.verifier.role, "release");
      steps.push({
        step: "release",
        role: "verifier",
        tx: await verifierRelease(
          senders.verifier,
          opts.deployment.taskEscrow,
          orderId,
          resultHash(true),
          resultUri(true),
        ),
      });
      if (task.approval_mode === "user") {
        assertEscrowSigner(senders.buyer.role, "approve");
        steps.push({
          step: "approve",
          role: "buyer",
          tx: await buyerApproveOrder(senders.buyer, opts.deployment.taskEscrow, orderId),
        });
      }
    } else {
      assertEscrowSigner(senders.verifier.role, "fail");
      steps.push({
        step: "fail",
        role: "verifier",
        tx: await verifierFail(
          senders.verifier,
          opts.deployment.taskEscrow,
          orderId,
          resultHash(false),
          resultUri(false),
        ),
      });
    }
  }

  const status = await chainIo.orderStatus(orderId);
  return {
    orderId,
    specHash: hash,
    status,
    steps,
    signingBackend: signingBackend(env),
    amount,
    expertAgentId,
    buyerAgentId,
    verifierAgentId,
    approvalMode: task.approval_mode,
  };
}
