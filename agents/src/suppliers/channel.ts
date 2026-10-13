/** Envelope schema for the negotiation channel. The channel moves these; it does not interpret `payload`. */
export const NEGOTIATE_SCHEMA = "guild.negotiate/v0.1" as const;

export interface NegotiateEnvelope {
  schema: typeof NEGOTIATE_SCHEMA;
  payload: unknown;
}

export type NegotiateHandler = (envelope: NegotiateEnvelope) => void | Promise<void>;

/**
 * Vendor boundary for `guild.negotiate/v0.1`.
 * `send` delivers an envelope to the counterparty. `onMessage` receives one.
 * The return value unsubscribes that handler.
 */
export interface NegotiationChannel {
  send(envelope: NegotiateEnvelope): Promise<void>;
  onMessage(handler: NegotiateHandler): () => void;
}

export function negotiateEnvelope(payload: unknown): NegotiateEnvelope {
  return { schema: NEGOTIATE_SCHEMA, payload };
}

export function assertNegotiateEnvelope(
  value: { schema?: unknown } | null | undefined,
): asserts value is NegotiateEnvelope {
  if (!value || value.schema !== NEGOTIATE_SCHEMA) {
    const got = value ? String(value.schema) : "empty";
    throw new Error(`expected ${NEGOTIATE_SCHEMA} envelope, got ${got}`);
  }
}

/**
 * Same-process `NegotiationChannel`. `send` invokes this channel's `onMessage` handlers.
 * Stand-in for a same-account `SendToAgent` demo, where one shared pipe replaces two
 * webhook URLs. It does not call Cursor.
 */
export function createInMemoryChannel(): NegotiationChannel {
  const handlers = new Set<NegotiateHandler>();

  return {
    onMessage(handler) {
      handlers.add(handler);
      return () => {
        handlers.delete(handler);
      };
    },
    async send(envelope) {
      assertNegotiateEnvelope(envelope);
      for (const handler of [...handlers]) {
        await handler(envelope);
      }
    },
  };
}
