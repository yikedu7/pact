import { deadlineUnix, usdcAmountToUnits, type TaskSpec } from "./spec.js";

const PROTOCOL = "guild.negotiate/v0.1";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function protocolOk(value: unknown): void {
  if (value !== undefined && value !== PROTOCOL) {
    throw new Error(`Expected protocol ${PROTOCOL}, got ${JSON.stringify(value)}.`);
  }
}

function validateTask(task: Record<string, unknown>): TaskSpec {
  if (typeof task.task_type !== "string" || task.task_type.length === 0) {
    throw new Error("Accepted task is missing task_type.");
  }
  if (task.approval_mode !== "user" && task.approval_mode !== "approve_for_me") {
    throw new Error(
      `Accepted task approval_mode must be "user" or "approve_for_me", got ${JSON.stringify(task.approval_mode)}.`,
    );
  }
  const token = isRecord(task.price) ? task.price.token : undefined;
  if (token !== "USDC") {
    throw new Error(`Guild escrow MVP settles USDC only. This task prices in ${JSON.stringify(token)}.`);
  }
  if (typeof task.price !== "object" || task.price === null || typeof (task.price as { amount?: unknown }).amount !== "string") {
    throw new Error('Task price.amount must be a decimal string such as "5".');
  }
  if (typeof task.deadline !== "string") {
    throw new Error("Accepted task is missing an ISO8601 deadline.");
  }
  usdcAmountToUnits((task.price as { amount: string }).amount);
  deadlineUnix(task.deadline);
  return task as unknown as TaskSpec;
}

function taskFromEnvelope(message: Record<string, unknown>): TaskSpec {
  protocolOk(message.protocol);
  if (message.type !== "accept") {
    throw new Error(
      `Escrow starts after an expert accept. This message is ${JSON.stringify(message.type)}, so nothing was broadcast.`,
    );
  }
  const body = message.body;
  if (!isRecord(body) || !isRecord(body.final_task)) {
    throw new Error("Accept message has no body.final_task. Nothing was broadcast.");
  }
  return validateTask(body.final_task);
}

/**
 * Pull the frozen task from a `guild.negotiate/v0.1` accept envelope, or from a
 * negotiation record whose `latest` message is that accept.
 */
export function taskFromAccept(message: unknown): TaskSpec {
  if (!isRecord(message)) {
    throw new Error("Accept payload must be a JSON object.");
  }
  if (isRecord(message.latest)) {
    return taskFromEnvelope(message.latest);
  }
  return taskFromEnvelope(message);
}
