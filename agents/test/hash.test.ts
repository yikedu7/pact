import { describe, expect, it } from "vitest";
import { hashJcs, jcsCanonicalize } from "../src/hash.js";
import { PINNED_SPEC_HASH, PINNED_SPEC_JSON, buildLogoSpec, specHash } from "../src/spec.js";

describe("JCS spec hashing", () => {
  it("matches the Foundry pinned vector", () => {
    expect(jcsCanonicalize(JSON.parse(PINNED_SPEC_JSON))).toBe(PINNED_SPEC_JSON);
    expect(hashJcs(JSON.parse(PINNED_SPEC_JSON))).toBe(PINNED_SPEC_HASH);
    expect(specHash(JSON.parse(PINNED_SPEC_JSON))).toBe(PINNED_SPEC_HASH);
  });

  it("buildLogoSpec matches Demo.s.sol template for fixed deadline", () => {
    const deliverBy = 1_700_086_400; // 2023-11-15T22:13:20Z
    const spec = buildLogoSpec("user", deliverBy);
    expect(specHash(spec)).toBe(PINNED_SPEC_HASH);
  });
});
