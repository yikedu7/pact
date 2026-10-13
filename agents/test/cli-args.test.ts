import { describe, expect, it } from "vitest";
import { parseCliArgs } from "../src/cli-args.js";

describe("parseCliArgs", () => {
  it("parses after-accept and bootstrap as separate modes", () => {
    expect(parseCliArgs(["--after-accept", "accept.json"])).toMatchObject({ afterAccept: "accept.json" });
    expect(parseCliArgs(["--after-accept=-"])).toMatchObject({ afterAccept: "-" });
    expect(parseCliArgs(["--bootstrap-wallets"]).bootstrapWallets).toBe(true);
    expect(parseCliArgs(["--local-anvil"]).localAnvil).toBe(true);
  });

  it("requires a path for after-accept", () => {
    expect(() => parseCliArgs(["--after-accept"])).toThrow(/requires a JSON file path/);
    expect(() => parseCliArgs(["--bootstrap-wallets", "--after-accept", "a.json"])).toThrow(/not both/);
  });
});
