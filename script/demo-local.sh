#!/usr/bin/env bash
# One-command reproduction of the PRODUCT_SPEC demo on a local anvil chain:
# deploy, then run the pass (user approval), pass (approve_for_me), fail and timeout branches,
# printing the transaction hash of every step. Testnet/local only; uses anvil's public dev keys.
#
#   ./script/demo-local.sh            # starts anvil on :8545 if nothing is listening
#   RPC_URL=http://127.0.0.1:9545 ./script/demo-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

for bin in anvil forge cast jq; do
  command -v "$bin" >/dev/null || { echo "missing '$bin' (install Foundry: https://getfoundry.sh, and jq)" >&2; exit 1; }
done

RPC_URL=${RPC_URL:-http://127.0.0.1:8545}
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # anvil account 0
VERIFIER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6 # anvil account 3

if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
  port=${RPC_URL##*:}
  echo "Starting anvil on port $port"
  anvil --silent --port "$port" &
  anvil_pid=$!
  trap 'kill $anvil_pid 2>/dev/null || true' EXIT
  for _ in $(seq 50); do cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break; sleep 0.2; done
fi

chain_id=$(cast chain-id --rpc-url "$RPC_URL")
[ "$chain_id" = 31337 ] || { echo "expected anvil (chain 31337), got chain $chain_id" >&2; exit 1; }

print_txs() {
  jq -r --slurpfile d deployments/31337.json '
    ($d[0] | {(.paymentToken | ascii_downcase): "MockUSDC", (.identityRegistry | ascii_downcase): "IdentityRegistry",
              (.reputationRegistry | ascii_downcase): "ReputationRegistry", (.taskEscrow | ascii_downcase): "TaskEscrow"}) as $names
    | .transactions[]
    | "  \(.hash)  \(.contractName // $names[.transaction.to | ascii_downcase] // .transaction.to)"
      + (if .function then "." + (.function | split("(")[0]) else " (create)" end)' \
    "broadcast/$1/31337/run-latest.json"
}

section() { printf '\n== %s ==\n' "$1"; }

section "Deploy (MockUSDC, IdentityRegistry, ReputationRegistry, TaskEscrow)"
PRIVATE_KEY=$DEPLOYER_KEY DEFAULT_VERIFIER=$(cast wallet address "$VERIFIER_KEY") \
  forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --slow -q
print_txs Deploy.s.sol
escrow=$(jq -r .taskEscrow deployments/31337.json)
echo "  TaskEscrow at $escrow"

expert_id=0
buyer_id=0
verifier_id=0
run_demo() {
  section "$1"
  out=$(SCENARIO=$2 APPROVAL_MODE=$3 EXPERT_AGENT_ID=$expert_id BUYER_AGENT_ID=$buyer_id VERIFIER_AGENT_ID=$verifier_id \
    forge script script/Demo.s.sol --rpc-url "$RPC_URL" --broadcast --slow)
  print_txs Demo.s.sol
  echo "$out" | sed -n '/== Logs ==/,/^$/p' | sed '1d;/^$/d'
  expert_id=$(echo "$out" | awk '/expert agentId/ {print $NF}')
  buyer_id=$(echo "$out" | awk '/buyer agentId/ {print $NF}')
  verifier_id=$(echo "$out" | awk '/verifier agentId/ {print $NF}')
}

run_demo "Pass, user approval: Created > Agreed > Funded > Delivered > Verified > Released" pass user
run_demo "Pass, approve_for_me: verifier pass auto-releases" pass approve_for_me
run_demo "Fail: verifier fail refunds the buyer" fail user
run_demo "Timeout: funded, never delivered" timeout user

order_id=$(( $(cast call "$escrow" "nextOrderId()(uint256)" --rpc-url "$RPC_URL") - 1 ))
cast rpc evm_increaseTime $((24 * 3600 + 1)) --rpc-url "$RPC_URL" >/dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
echo "  advanced anvil time past deliverBy"
tx=$(cast send "$escrow" "refundExpired(uint256)" "$order_id" --private-key "$DEPLOYER_KEY" --rpc-url "$RPC_URL" --json)
echo "  $(echo "$tx" | jq -r .transactionHash)  TaskEscrow.refundExpired (status $(echo "$tx" | jq -r .status))"
echo "  order $order_id status: $(cast call "$escrow" "getOrder(uint256)((address,uint64,uint8,uint8,bool,address,uint64,address,uint64,uint32,uint64,uint64,uint256,uint256,uint256,bytes32,bytes32,bytes32,string,string))" "$order_id" --rpc-url "$RPC_URL" | cut -d, -f3 | tr -d ' )') (7=Refunded)"

section "Expert reputation via escrow (tag1=expert, tag2=design.logo)"
reputation=$(jq -r .reputationRegistry deployments/31337.json)
summary=$(cast call "$reputation" "getSummary(uint256,address[],string,string)(uint64,int128,uint8)" \
  "$expert_id" "[$escrow]" expert design.logo --rpc-url "$RPC_URL" | tr '\n' ' ')
read -r count rate _ <<<"$summary"
echo "  agent $expert_id: $count fulfillments, pass rate $rate%"
