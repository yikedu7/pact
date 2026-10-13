export interface CliArgs {
  localAnvil: boolean;
  bootstrapWallets: boolean;
  /** File path, or `-` for stdin. Unset when this is the logo demo. */
  afterAccept?: string;
}

export function parseCliArgs(argv: string[]): CliArgs {
  let afterAccept: string | undefined;
  let localAnvil = false;
  let bootstrapWallets = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--after-accept") {
      const next = argv[i + 1];
      if (!next || next.startsWith("--")) {
        throw new Error("--after-accept requires a JSON file path, or - to read stdin.");
      }
      afterAccept = next;
      i++;
    } else if (arg.startsWith("--after-accept=")) {
      const value = arg.slice("--after-accept=".length);
      if (!value) throw new Error("--after-accept requires a JSON file path, or - to read stdin.");
      afterAccept = value;
    } else if (arg === "--bootstrap-wallets") {
      bootstrapWallets = true;
    } else if (arg === "--local-anvil") {
      localAnvil = true;
    } else {
      throw new Error(`Unknown argument ${arg}.`);
    }
  }
  if (bootstrapWallets && afterAccept) {
    throw new Error("Use either --bootstrap-wallets or --after-accept, not both.");
  }
  return { localAnvil, bootstrapWallets, afterAccept };
}
