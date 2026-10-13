import { describe, expect, it } from "vitest";
import { fundHint, walletVendor } from "../src/wallet/adapter.js";

describe("wallet adapter", () => {
  it("names today's two vendors and leaves account-abstraction for later", () => {
    expect(walletVendor("privy")).toBe("PrivyShared");
    expect(walletVendor("local")).toBe("LocalEoa");
  });

  it("points a testnet EOA at a faucet", () => {
    const address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
    expect(fundHint(10143, address)).toContain("https://faucet.monad.xyz");
    expect(fundHint(10143, address)).toContain(address);
    expect(fundHint(84532)).toContain("Base Sepolia");
    expect(fundHint(31337)).toMatch(/prefunded/i);
  });
});