/** Mirrors `ITaskEscrow.Status` for off-chain guards and tests. */
export enum OrderStatus {
  None = 0,
  Created = 1,
  Agreed = 2,
  Funded = 3,
  Delivered = 4,
  Verified = 5,
  Released = 6,
  Refunded = 7,
  Disputed = 8,
}

export type DemoScenario = "pass" | "fail" | "timeout";

export function parseScenario(raw: string): DemoScenario {
  const v = raw.toLowerCase();
  if (v === "pass" || v === "fail" || v === "timeout") return v;
  throw new Error(`Unknown SCENARIO: ${raw}`);
}

export function statusLabel(status: OrderStatus): string {
  return OrderStatus[status] ?? String(status);
}

/** Expected next status after a successful on-chain transition in the happy-path demo. */
export function expectedStatusAfterStep(
  step:
    | "createOrder"
    | "agree"
    | "fund"
    | "submitDelivery"
    | "release"
    | "fail"
    | "approve"
    | "refundExpired",
  approvalMode: "user" | "approve_for_me",
  scenario: DemoScenario,
): OrderStatus {
  switch (step) {
    case "createOrder":
      return OrderStatus.Created;
    case "agree":
      return OrderStatus.Agreed;
    case "fund":
      return OrderStatus.Funded;
    case "submitDelivery":
      return scenario === "timeout" ? OrderStatus.Funded : OrderStatus.Delivered;
    case "release":
      return approvalMode === "approve_for_me" ? OrderStatus.Released : OrderStatus.Verified;
    case "fail":
      return OrderStatus.Refunded;
    case "approve":
      return OrderStatus.Released;
    case "refundExpired":
      return OrderStatus.Refunded;
    default:
      throw new Error(`unknown step ${step}`);
  }
}
