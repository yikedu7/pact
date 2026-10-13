import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { hashJcs } from "../src/hash.js";
import { taskFromAccept } from "../src/negotiate.js";
import { repoRootFromAgents } from "../src/deployments.js";
import { specHash, usdcAmountToUnits } from "../src/spec.js";

const NEGOTIATION_HASH = "0x1b43cd73e2242762c4e27c12cb5ee58f32f733bba1b2406a158be2f2abaeff1d";

describe("taskFromAccept", () => {
  it("reads the hackathon accept record and keeps its spec hash", () => {
    const path = join(repoRootFromAgents(), "docs/demos/2026-10-13-dfcb9220/NEGOTIATION_dfcb9220.json");
    const record = JSON.parse(readFileSync(path, "utf8")) as unknown;
    const task = taskFromAccept(record);
    expect(task.task_type).toBe("design.logo");
    expect(task.approval_mode).toBe("approve_for_me");
    expect(usdcAmountToUnits(task.price.amount)).toBe(5_000_000n);
    expect(specHash(task)).toBe(NEGOTIATION_HASH);
    expect(hashJcs(task)).toBe(NEGOTIATION_HASH);
  });

  it("accepts a bare accept envelope", () => {
    const task = taskFromAccept({
      protocol: "guild.negotiate/v0.1",
      type: "accept",
      body: {
        final_task: {
          task_type: "design.logo",
          title: "Guild logo",
          price: { token: "USDC", amount: "5" },
          deadline: "2099-01-01T00:00:00Z",
          approval_mode: "user",
          revisions: 1,
        },
      },
    });
    expect(task.approval_mode).toBe("user");
  });

  it("refuses to start escrow from an offer", () => {
    expect(() =>
      taskFromAccept({
        protocol: "guild.negotiate/v0.1",
        type: "offer",
        body: { task: { title: "nope" } },
      }),
    ).toThrow(/expert accept/);
  });

  it("refuses a non-USDC price", () => {
    expect(() =>
      taskFromAccept({
        protocol: "guild.negotiate/v0.1",
        type: "accept",
        body: {
          final_task: {
            task_type: "design.logo",
            price: { token: "ETH", amount: "1" },
            deadline: "2099-01-01T00:00:00Z",
            approval_mode: "user",
          },
        },
      }),
    ).toThrow(/USDC only/);
  });
});
