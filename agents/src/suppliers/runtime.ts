import type { Address, Hex } from "viem";
import {
  buyerApproveOrder,
  buyerCreateOrder,
  buyerFund,
  buyerPreparePayment,
  buyerRegister,
  type BuyerCreateParams,
} from "../agents/buyer.js";
import { expertAgree, expertDeliver, expertRegister } from "../agents/expert.js";
import {
  evaluateCriteria,
  verifierFail,
  verifierRegister,
  verifierRelease,
} from "../agents/verifier.js";
import type { ChainConfig } from "../chain.js";
import type { TaskSpec } from "../spec.js";
import { createRoleSenders, signingBackend, type Role, type TxSender } from "../wallet/index.js";

export type { BuyerCreateParams };

/** Buyer escrow calls. `sender` is the wallet that signs them. */
export interface BuyerClient {
  readonly sender: TxSender;
  register(registry: Address, agentUri?: string): Promise<string>;
  preparePayment(
    paymentToken: Address,
    escrow: Address,
    mockPaymentToken: boolean,
  ): Promise<string[]>;
  createOrder(params: BuyerCreateParams): Promise<{ specHash: Hex; tx: string }>;
  fund(escrow: Address, orderId: bigint): Promise<string>;
  approveOrder(escrow: Address, orderId: bigint): Promise<string>;
}

/** Expert escrow calls. `sender` is the wallet that signs them. */
export interface ExpertClient {
  readonly sender: TxSender;
  register(registry: Address, agentUri?: string): Promise<string>;
  agree(escrow: Address, orderId: bigint, specHash: Hex): Promise<string>;
  deliver(
    escrow: Address,
    orderId: bigint,
    deliveryHash: Hex,
    deliveryUri: string,
  ): Promise<string>;
}

/** Verifier escrow calls. `sender` is the wallet that signs them. */
export interface VerifierClient {
  readonly sender: TxSender;
  register(registry: Address, agentUri?: string): Promise<string>;
  evaluateCriteria(spec: TaskSpec, scenarioPass: boolean): boolean;
  release(
    escrow: Address,
    orderId: bigint,
    resultHash: Hex,
    resultUri: string,
  ): Promise<string>;
  fail(
    escrow: Address,
    orderId: bigint,
    resultHash: Hex,
    resultUri: string,
  ): Promise<string>;
}

/**
 * Vendor boundary for running the buyer, expert, and verifier call sequence
 * and signing the transactions. Hosts (Grok Bot) implement this outside the package;
 * `createReferenceRuntime` is the in-repo viem adapter.
 */
export interface ExecutionRuntime {
  readonly buyer: BuyerClient;
  readonly expert: ExpertClient;
  readonly verifier: VerifierClient;
  readonly signingBackend: "privy" | "local";
}

/** Bind the existing role functions to three signers. */
export function createExecutionRuntime(
  senders: Record<Role, TxSender>,
  backend: "privy" | "local",
): ExecutionRuntime {
  const { buyer, expert, verifier } = senders;
  return {
    signingBackend: backend,
    buyer: {
      sender: buyer,
      register: (registry, agentUri) => buyerRegister(buyer, registry, agentUri),
      preparePayment: (paymentToken, escrow, mockPaymentToken) =>
        buyerPreparePayment(buyer, paymentToken, escrow, mockPaymentToken),
      createOrder: (params) => buyerCreateOrder(buyer, params),
      fund: (escrow, orderId) => buyerFund(buyer, escrow, orderId),
      approveOrder: (escrow, orderId) => buyerApproveOrder(buyer, escrow, orderId),
    },
    expert: {
      sender: expert,
      register: (registry, agentUri) => expertRegister(expert, registry, agentUri),
      agree: (escrow, orderId, specHash) => expertAgree(expert, escrow, orderId, specHash),
      deliver: (escrow, orderId, deliveryHash, deliveryUri) =>
        expertDeliver(expert, escrow, orderId, deliveryHash, deliveryUri),
    },
    verifier: {
      sender: verifier,
      register: (registry, agentUri) => verifierRegister(verifier, registry, agentUri),
      evaluateCriteria,
      release: (escrow, orderId, resultHash, resultUri) =>
        verifierRelease(verifier, escrow, orderId, resultHash, resultUri),
      fail: (escrow, orderId, resultHash, resultUri) =>
        verifierFail(verifier, escrow, orderId, resultHash, resultUri),
    },
  };
}

/** Reference adapter: Privy server wallets when configured, otherwise local keys. */
export function createReferenceRuntime(chain: ChainConfig): ExecutionRuntime {
  return createExecutionRuntime(createRoleSenders(chain), signingBackend());
}
