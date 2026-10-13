export type CliCommand =
  | { kind: "bootstrap"; includeVerifierWallet: boolean }
  | { kind: "buyer-create-fund"; payload: string }
  | { kind: "expert-agree-deliver"; payload: string }
  | { kind: "buyer-release"; payload: string }
  | { kind: "logo-demo"; localAnvil: boolean };

const PAYLOAD_FLAGS = ["--buyer-create-fund", "--expert-agree-deliver", "--buyer-release"] as const;

type PayloadKind = "buyer-create-fund" | "expert-agree-deliver" | "buyer-release";

function payloadOf(flag: string, argv: string[], index: number): { value: string; next: number } {
  const arg = argv[index] ?? "";
  if (arg.startsWith(`${flag}=`)) {
    const value = arg.slice(flag.length + 1);
    if (!value) throw new Error(`${flag} requires a JSON file path, or - to read stdin.`);
    return { value, next: index };
  }
  const next = argv[index + 1];
  if (!next || next.startsWith("--")) {
    throw new Error(`${flag} requires a JSON file path, or - to read stdin.`);
  }
  return { value: next, next: index + 1 };
}

export function parseCliArgs(argv: string[]): CliCommand {
  let localAnvil = false;
  let includeVerifierWallet = false;
  let payloadKind: PayloadKind | undefined;
  let payload: string | undefined;
  let bootstrap = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i] ?? "";
    const flag = arg.includes("=") ? arg.slice(0, arg.indexOf("=")) : arg;
    if ((PAYLOAD_FLAGS as readonly string[]).includes(flag)) {
      if (payloadKind || bootstrap) throw new Error("Pass only one escrow command.");
      const got = payloadOf(flag, argv, i);
      payloadKind = flag.slice(2) as PayloadKind;
      payload = got.value;
      i = got.next;
    } else if (arg === "--bootstrap-wallets") {
      if (payloadKind || bootstrap) throw new Error("Pass only one escrow command.");
      bootstrap = true;
    } else if (arg === "--include-verifier-wallet") {
      includeVerifierWallet = true;
    } else if (arg === "--local-anvil") {
      localAnvil = true;
    } else if (arg === "--after-accept" || arg.startsWith("--after-accept=")) {
      throw new Error(
        "--after-accept is not the demo path. Use --buyer-create-fund, --expert-agree-deliver, and --buyer-release. Each process signs with one wallet.",
      );
    } else {
      throw new Error(`Unknown argument ${arg}.`);
    }
  }

  if (includeVerifierWallet && !bootstrap) {
    throw new Error("--include-verifier-wallet is only for --bootstrap-wallets, and it is not the demo path.");
  }
  if (bootstrap) return { kind: "bootstrap", includeVerifierWallet };
  if (payloadKind && payload) return { kind: payloadKind, payload };
  return { kind: "logo-demo", localAnvil };
}
