import { describe, expect, it } from "vitest";
import { parseCliArgs } from "../src/cli-args.js";

describe("parseCliArgs", () => {
  it("parses the two-wallet commands and bootstrap", () => {
    expect(parseCliArgs(["--buyer-create-fund", "accept.json"])).toEqual({
      kind: "buyer-create-fund",
      payload: "accept.json",
    });
    expect(parseCliArgs(["--expert-agree-deliver=-"])).toEqual({
      kind: "expert-agree-deliver",
      payload: "-",
    });
    expect(parseCliArgs(["--buyer-release", "cue.json"])).toEqual({
      kind: "buyer-release",
      payload: "cue.json",
    });
    expect(parseCliArgs(["--bootstrap-wallets"])).toEqual({ kind: "bootstrap", includeVerifierWallet: false });
    expect(parseCliArgs(["--local-anvil"])).toEqual({ kind: "logo-demo", localAnvil: true });
  });

  it("rejects the retired all-in-one flag and a missing path", () => {
    expect(() => parseCliArgs(["--buyer-create-fund"])).toThrow(/requires a JSON file path/);
    expect(() => parseCliArgs(["--after-accept", "a.json"])).toThrow(/not the demo path/);
    expect(() => parseCliArgs(["--bootstrap-wallets", "--buyer-create-fund", "a.json"])).toThrow(/only one/);
    expect(() => parseCliArgs(["--include-verifier-wallet"])).toThrow(/not the demo path/);
  });
});
