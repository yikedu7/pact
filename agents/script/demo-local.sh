#!/usr/bin/env bash
# Optional local-dev replay on anvil (not the Path A two-wallet handoff).
# Deploys via Foundry, then `npm run demo` with local EOAs. createOrder.verifier is the buyer.
# DEFAULT_VERIFIER below is only the contract fallback. New orders do not use it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

for bin in anvil forge cast jq node npm; do
  command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }
done

RPC_URL=${RPC_URL:-http://127.0.0.1:8545}
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
VERIFIER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6

if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  port=${RPC_URL##*:}
  echo "Starting anvil on port $port"
  anvil --silent --port "$port" &
  anvil_pid=$!
  trap 'kill $anvil_pid 2>/dev/null || true' EXIT
  for _ in $(seq 50); do cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break; sleep 0.2; done
fi

chain_id=$(cast chain-id --rpc-url "$RPC_URL")
[ "$chain_id" = 31337 ] || { echo "expected anvil chain 31337" >&2; exit 1; }

echo "== Deploy =="
PRIVATE_KEY=$DEPLOYER_KEY DEFAULT_VERIFIER=$(cast wallet address "$VERIFIER_KEY") \
  forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --slow -q

pushd agents >/dev/null
npm ci
export RPC_URL CHAIN_ID=31337 SCENARIO=pass APPROVAL_MODE=approve_for_me
echo "== TypeScript agents demo (approve_for_me) =="
npm run demo
popd >/dev/null
