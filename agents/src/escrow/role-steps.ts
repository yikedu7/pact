import { dirname, join } from "node:path";
import type { Address, Hex } from "viem";
import { buyerApproveOrder, buyerCreateOrder, buyerFund, buyerPreparePayment } from "../agents/buyer.js";
import { expertAgree, expertDeliver } from "../agents/expert.js";
import { verifierFail, verifierRelease } from "../agents/verifier.js";
import type { ChainConfig } from "../chain.js";
import type { DeploymentFile } from "../deployments.js";
import { hashUtf8, jcsCanonicalize } from "../hash.js";
import { taskFromAccept } from "../negotiate.js";
import { assertFundWithinCaps, fileSpendLedger, policyFromEnv, type SpendLedger, type SpendPolicy } from "../policy.js";
import { assertEscrowSigner } from "../skills/boundaries.js";
import {
  deadlineUnix,
  DELIVERY_MANIFEST,
  resultHash,
  resultUri,
  REVIEW_WINDOW_SEC,
  specHash,
  toDataUri,
  usdcAmountToUnits,
  type ApprovalModeLabel,
  type TaskSpec,
} from "../spec.js";
import { OrderStatus, statusLabel, type DemoScenario } from "../state.js";
import { defaultRoleWalletsPath } from "../wallet/bootstrap.js";
import { signingBackend, type TxSender } from "../wallet/index.js";
import type { Role } from "../wallet/types.js";
import { isArchivedVerifier, isEscrowCue, makeCue, parseEscrowCue, type EscrowCue } from "./cue.js";
import { viemEscrowChain, type EscrowChainIo, type OnChainOrder } from "./chain-io.js";

export interface EscrowStepRecord {
  step: string;
  role: Role;
  tx: string;
}

export interface RoleStepResult {
  orderId: bigint;
  specHash: Hex;
  status: OrderStatus;
  steps: EscrowStepRecord[];
  signingBackend: "privy" | "local";
  cue: EscrowCue;
  amount: bigint;
  verifier: Address;
  approvalMode: ApprovalModeLabel;
}

export interface RoleRunOpts {
  message: unknown;
  chain: ChainConfig;
  deployment: DeploymentFile;
  sender: TxSender;
  chainIo?: EscrowChainIo;
  policy?: SpendPolicy;
  ledger?: SpendLedger;
  now?: Date;
  env?: Record<string, string | undefined>;
  scenario?: DemoScenario;
  deliveryJson?: string;
}

function defaultSpendPath(): string {
  if (process.env.GUILD_SPEND_LEDGER) return process.env.GUILD_SPEND_LEDGER;
  return join(dirname(defaultRoleWalletsPath()), "spend-ledger.json");
}

function requireRole(sender: TxSender, role: Role): void {
  if (sender.role === role) return;
  throw new Error(
    `This command signs only with the ${role} wallet, but the sender is ${sender.role}. Nothing was broadcast.`,
  );
}

function stopWrongStatus(orderId: bigint, actual: OrderStatus, expected: OrderStatus, action: string): void {
  if (actual === expected) return;
  throw new Error(
    `Order ${orderId} is ${statusLabel(actual)}, expected ${statusLabel(expected)} before ${action}. ` +
      `Stopping. This process will not use another role's key. Nothing was broadcast.`,
  );
}

function chainIoOf(opts: RoleRunOpts): EscrowChainIo {
  return opts.chainIo ?? viemEscrowChain(opts.chain, opts.deployment);
}

function scenarioOf(opts: RoleRunOpts, cue?: EscrowCue): DemoScenario {
  return cue?.body.scenario ?? opts.scenario ?? "pass";
}

function orderIdOf(cue: EscrowCue): bigint {
  const raw = cue.body.orderId;
  if (!raw || !/^\d+$/.test(raw)) {
    throw new Error("Escrow cue is missing a numeric orderId. Nothing was broadcast.");
  }
  return BigInt(raw);
}

function agentId(raw: string | undefined, name: string, required: boolean): bigint {
  if (raw === undefined || raw.trim() === "" || raw.trim() === "0") {
    if (!required) return 0n;
    throw new Error(
      `${name} is required. The buyer process does not register the expert and does not hold the expert wallet. Nothing was broadcast.`,
    );
  }
  if (!/^\d+$/.test(raw.trim())) {
    throw new Error(`${name} must be a positive integer, got ${JSON.stringify(raw)}.`);
  }
  return BigInt(raw.trim());
}

function approvalLabel(mode: number): ApprovalModeLabel {
  if (mode === 1) return "approve_for_me";
  if (mode === 0) return "user";
  throw new Error(`On-chain approvalMode ${mode} is not user (0) or approve_for_me (1). Nothing was broadcast.`);
}

function baseResult(
  opts: RoleRunOpts,
  order: OnChainOrder,
  orderId: bigint,
  steps: EscrowStepRecord[],
  cue: EscrowCue,
): RoleStepResult {
  return {
    orderId,
    specHash: order.specHash,
    status: order.status,
    steps,
    signingBackend: signingBackend(opts.env),
    cue,
    amount: order.amount,
    verifier: order.verifier,
    approvalMode: approvalLabel(order.approvalMode),
  };
}

/**
 * Buyer wallet only. Accept JSON creates the order (verifier = buyer) and approves the token.
 * A `buyer-fund` cue funds an Agreed order. Never signs agree, delivery, or another wallet.
 */
export async function runBuyerCreateOrFund(opts: RoleRunOpts): Promise<RoleStepResult> {
  requireRole(opts.sender, "buyer");
  if (isArchivedVerifier(opts.sender.address)) {
    throw new Error(
      `Refusing to sign with archived verifier ${opts.sender.address}. New orders use the Buyer wallet. Nothing was broadcast.`,
    );
  }
  if (isEscrowCue(opts.message)) {
    const cue = parseEscrowCue(opts.message);
    if (cue.body.step !== "buyer-fund") {
      throw new Error(
        `buyer-create-fund received cue step ${cue.body.step}. ` +
          `Fund only a buyer-fund cue, or pass a negotiate accept to create. Nothing was broadcast.`,
      );
    }
    return fundAgreedOrder(opts, cue);
  }
  return createOrder(opts);
}

async function createOrder(opts: RoleRunOpts): Promise<RoleStepResult> {
  const env = opts.env ?? process.env;
  const task: TaskSpec = taskFromAccept(opts.message);
  const amount = usdcAmountToUnits(task.price.amount);
  const policy = opts.policy ?? policyFromEnv(env);
  const ledger = opts.ledger ?? fileSpendLedger(defaultSpendPath());
  assertFundWithinCaps(amount, policy, ledger, opts.now ?? new Date());

  const chainIo = chainIoOf(opts);
  const deliverBy = deadlineUnix(task.deadline);
  const blockTime = await chainIo.blockTimestamp();
  if (deliverBy <= blockTime) {
    throw new Error(
      `Task deadline ${task.deadline} is not in the future on ${opts.chain.name} ` +
        `(block time ${blockTime}). createOrder would revert. Negotiate a later deadline. Nothing was broadcast.`,
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

  const expertAgentId = agentId(env.EXPERT_AGENT_ID, "EXPERT_AGENT_ID", true);
  const buyerAgentId = agentId(env.BUYER_AGENT_ID, "BUYER_AGENT_ID", false);
  const verifier = opts.sender.address;
  if (isArchivedVerifier(verifier)) {
    throw new Error(
      `createOrder.verifier would be the archived verifier. New orders set verifier to the Buyer wallet. Nothing was broadcast.`,
    );
  }

  const steps: EscrowStepRecord[] = [];
  const prep = await buyerPreparePayment(
    opts.sender,
    opts.deployment.paymentToken,
    opts.deployment.taskEscrow,
    opts.deployment.mockPaymentToken,
    amount,
  );
  const prepLabels = opts.deployment.mockPaymentToken ? ["mint", "approveToken"] : ["approveToken"];
  prep.forEach((tx, i) => steps.push({ step: prepLabels[i] ?? "approveToken", role: "buyer", tx }));

  const orderId = await chainIo.nextOrderId();
  assertEscrowSigner(opts.sender.role, "createOrder");
  const created = await buyerCreateOrder(opts.sender, {
    escrow: opts.deployment.taskEscrow,
    paymentToken: opts.deployment.paymentToken,
    mockPaymentToken: opts.deployment.mockPaymentToken,
    sellerAgentId: expertAgentId,
    buyerAgentId,
    verifier,
    spec: task,
    specUri: toDataUri(canonical),
    deliverBy,
    reviewWindow: REVIEW_WINDOW_SEC,
    approvalMode: task.approval_mode,
  });
  steps.push({ step: "createOrder", role: "buyer", tx: created.tx });

  const order = await chainIo.getOrder(orderId);
  const scenario = scenarioOf(opts);
  const cue = makeCue({
    step: "expert-agree",
    orderId: orderId.toString(),
    specHash: hash,
    approval_mode: task.approval_mode,
    amount: amount.toString(),
    sellerAgentId: expertAgentId.toString(),
    buyerAgentId: buyerAgentId.toString(),
    verifier,
    scenario,
  });
  return {
    orderId,
    specHash: hash,
    status: order.status,
    steps,
    signingBackend: signingBackend(env),
    cue,
    amount,
    verifier,
    approvalMode: task.approval_mode,
  };
}

async function fundAgreedOrder(opts: RoleRunOpts, cueIn: EscrowCue): Promise<RoleStepResult> {
  const env = opts.env ?? process.env;
  const chainIo = chainIoOf(opts);
  const orderId = orderIdOf(cueIn);
  const before = await chainIo.getOrder(orderId);
  stopWrongStatus(orderId, before.status, OrderStatus.Agreed, "fund");
  if (isArchivedVerifier(before.verifier)) {
    throw new Error(
      `Order ${orderId} names archived verifier ${before.verifier}. This buyer process will not continue it. Nothing was broadcast.`,
    );
  }
  if (before.verifier.toLowerCase() !== opts.sender.address.toLowerCase()) {
    throw new Error(
      `Order ${orderId} verifier is ${before.verifier}, not buyer ${opts.sender.address}. ` +
        `New orders set verifier to the buyer. Stopping. Nothing was broadcast.`,
    );
  }
  const blockTime = await chainIo.blockTimestamp();
  if (before.deliverBy <= blockTime) {
    throw new Error(
      `Order ${orderId} deadline ${before.deliverBy} is not after block time ${blockTime}. fund would revert. Nothing was broadcast.`,
    );
  }

  const policy = opts.policy ?? policyFromEnv(env);
  const ledger = opts.ledger ?? fileSpendLedger(defaultSpendPath());
  const { day } = assertFundWithinCaps(before.amount, policy, ledger, opts.now ?? new Date());
  assertEscrowSigner(opts.sender.role, "fund");
  const tx = await buyerFund(opts.sender, opts.deployment.taskEscrow, orderId);
  ledger.record(day, before.amount);
  const steps: EscrowStepRecord[] = [{ step: "fund", role: "buyer", tx }];
  const order = await chainIo.getOrder(orderId);
  const scenario = scenarioOf(opts, cueIn);
  const cue = makeCue({
    ...cueIn.body,
    step: scenario === "timeout" ? "done" : "expert-deliver",
    orderId: orderId.toString(),
    specHash: order.specHash,
    amount: order.amount.toString(),
    verifier: order.verifier,
    approval_mode: approvalLabel(order.approvalMode),
    scenario,
    reason: scenario === "timeout" ? "timeout: order stays Funded; expert does not deliver" : undefined,
  });
  return baseResult(opts, order, orderId, steps, cue);
}

/**
 * Expert wallet only. `expert-agree` on Created, `expert-deliver` on Funded.
 * A timeout cue stops at Funded without a delivery signature.
 */
export async function runExpertAgreeOrDeliver(opts: RoleRunOpts): Promise<RoleStepResult> {
  requireRole(opts.sender, "expert");
  if (!isEscrowCue(opts.message)) {
    throw new Error(
      "Expert runs from a guild.escrow/v0.1 cue (expert-agree or expert-deliver), not from the accept message. Nothing was broadcast.",
    );
  }
  const cueIn = parseEscrowCue(opts.message);
  const chainIo = chainIoOf(opts);
  const orderId = orderIdOf(cueIn);
  const before = await chainIo.getOrder(orderId);

  if (cueIn.body.step === "expert-agree") {
    stopWrongStatus(orderId, before.status, OrderStatus.Created, "agree");
    if (cueIn.body.specHash && cueIn.body.specHash.toLowerCase() !== before.specHash.toLowerCase()) {
      throw new Error(
        `Cue specHash ${cueIn.body.specHash} does not match on-chain ${before.specHash}. Stopping. Nothing was broadcast.`,
      );
    }
    const blockTime = await chainIo.blockTimestamp();
    if (before.deliverBy <= blockTime) {
      throw new Error(
        `Order ${orderId} deadline has passed (block time ${blockTime}). agree would revert. Nothing was broadcast.`,
      );
    }
    assertEscrowSigner(opts.sender.role, "agree");
    const tx = await expertAgree(opts.sender, opts.deployment.taskEscrow, orderId, before.specHash);
    const order = await chainIo.getOrder(orderId);
    const cue = makeCue({
      ...cueIn.body,
      step: "buyer-fund",
      orderId: orderId.toString(),
      specHash: order.specHash,
      verifier: order.verifier,
      amount: order.amount.toString(),
      approval_mode: approvalLabel(order.approvalMode),
    });
    return baseResult(opts, order, orderId, [{ step: "agree", role: "expert", tx }], cue);
  }

  if (cueIn.body.step === "expert-deliver") {
    stopWrongStatus(orderId, before.status, OrderStatus.Funded, "submitDelivery");
    const scenario = scenarioOf(opts, cueIn);
    if (scenario === "timeout") {
      throw new Error(
        `SCENARIO=timeout stops at Funded. Expert did not submit delivery for order ${orderId}. Nothing was broadcast.`,
      );
    }
    const manifest = opts.deliveryJson ?? DELIVERY_MANIFEST;
    assertEscrowSigner(opts.sender.role, "submitDelivery");
    const tx = await expertDeliver(
      opts.sender,
      opts.deployment.taskEscrow,
      orderId,
      hashUtf8(manifest),
      toDataUri(manifest),
    );
    const order = await chainIo.getOrder(orderId);
    const cue = makeCue({
      ...cueIn.body,
      step: "buyer-release",
      orderId: orderId.toString(),
      specHash: order.specHash,
      verifier: order.verifier,
      amount: order.amount.toString(),
      approval_mode: approvalLabel(order.approvalMode),
      scenario,
    });
    return baseResult(opts, order, orderId, [{ step: "submitDelivery", role: "expert", tx }], cue);
  }

  throw new Error(
    `expert-agree-deliver does not run cue step ${cueIn.body.step}. Nothing was broadcast.`,
  );
}

/**
 * Buyer wallet only, after delivery. release (pass) or fail (refund).
 * The order verifier must be this buyer address. User mode also sends approve.
 */
export async function runBuyerRelease(opts: RoleRunOpts): Promise<RoleStepResult> {
  requireRole(opts.sender, "buyer");
  if (!isEscrowCue(opts.message)) {
    throw new Error("buyer-release runs from a guild.escrow/v0.1 buyer-release cue. Nothing was broadcast.");
  }
  const cueIn = parseEscrowCue(opts.message);
  if (cueIn.body.step !== "buyer-release") {
    throw new Error(
      `buyer-release received cue step ${cueIn.body.step}. Nothing was broadcast.`,
    );
  }
  const chainIo = chainIoOf(opts);
  const orderId = orderIdOf(cueIn);
  const before = await chainIo.getOrder(orderId);
  stopWrongStatus(orderId, before.status, OrderStatus.Delivered, "release or fail");
  if (isArchivedVerifier(before.verifier)) {
    throw new Error(
      `Order ${orderId} names archived verifier ${before.verifier}. ` +
        `The buyer process will not use that wallet. Nothing was broadcast.`,
    );
  }
  if (before.verifier.toLowerCase() !== opts.sender.address.toLowerCase()) {
    throw new Error(
      `Order ${orderId} verifier is ${before.verifier}, not buyer ${opts.sender.address}. ` +
        `Stopping. This process will not sign with another wallet. Nothing was broadcast.`,
    );
  }
  if (before.buyer.toLowerCase() !== opts.sender.address.toLowerCase()) {
    throw new Error(
      `Order ${orderId} buyer is ${before.buyer}, not ${opts.sender.address}. Stopping. Nothing was broadcast.`,
    );
  }

  const scenario = scenarioOf(opts, cueIn);
  const steps: EscrowStepRecord[] = [];
  if (scenario === "fail") {
    assertEscrowSigner(opts.sender.role, "fail");
    steps.push({
      step: "fail",
      role: "buyer",
      tx: await verifierFail(
        opts.sender,
        opts.deployment.taskEscrow,
        orderId,
        resultHash(false),
        resultUri(false),
      ),
    });
  } else if (scenario === "pass") {
    assertEscrowSigner(opts.sender.role, "release");
    steps.push({
      step: "release",
      role: "buyer",
      tx: await verifierRelease(
        opts.sender,
        opts.deployment.taskEscrow,
        orderId,
        resultHash(true),
        resultUri(true),
      ),
    });
    const mid = await chainIo.getOrder(orderId);
    if (approvalLabel(mid.approvalMode) === "user") {
      stopWrongStatus(orderId, mid.status, OrderStatus.Verified, "approve");
      assertEscrowSigner(opts.sender.role, "approve");
      steps.push({
        step: "approve",
        role: "buyer",
        tx: await buyerApproveOrder(opts.sender, opts.deployment.taskEscrow, orderId),
      });
    }
  } else {
    throw new Error(
      `buyer-release does not run SCENARIO=timeout. The order should still be Funded. Nothing was broadcast.`,
    );
  }

  const order = await chainIo.getOrder(orderId);
  const cue = makeCue({
    ...cueIn.body,
    step: "done",
    orderId: orderId.toString(),
    specHash: order.specHash,
    verifier: order.verifier,
    amount: order.amount.toString(),
    approval_mode: approvalLabel(order.approvalMode),
    scenario,
    reason: scenario === "fail" ? "refunded" : "released",
  });
  return baseResult(opts, order, orderId, steps, cue);
}
