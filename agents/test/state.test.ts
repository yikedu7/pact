import { describe, expect, it } from "vitest";
import { OrderStatus, expectedStatusAfterStep, parseScenario } from "../src/state.js";

describe("order state helpers", () => {
  it("parses demo scenarios", () => {
    expect(parseScenario("pass")).toBe("pass");
    expect(parseScenario("FAIL")).toBe("fail");
    expect(() => parseScenario("nope")).toThrow();
  });

  it("models happy-path transitions", () => {
    expect(expectedStatusAfterStep("createOrder", "user", "pass")).toBe(OrderStatus.Created);
    expect(expectedStatusAfterStep("agree", "user", "pass")).toBe(OrderStatus.Agreed);
    expect(expectedStatusAfterStep("fund", "user", "pass")).toBe(OrderStatus.Funded);
    expect(expectedStatusAfterStep("submitDelivery", "user", "pass")).toBe(OrderStatus.Delivered);
    expect(expectedStatusAfterStep("release", "user", "pass")).toBe(OrderStatus.Verified);
    expect(expectedStatusAfterStep("approve", "user", "pass")).toBe(OrderStatus.Released);
    expect(expectedStatusAfterStep("release", "approve_for_me", "pass")).toBe(OrderStatus.Released);
    expect(expectedStatusAfterStep("fail", "user", "fail")).toBe(OrderStatus.Refunded);
    expect(expectedStatusAfterStep("submitDelivery", "user", "timeout")).toBe(OrderStatus.Funded);
  });
});
