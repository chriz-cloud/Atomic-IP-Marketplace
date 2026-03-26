#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# ── Load environment ──────────────────────────────────────────────────────────
if [[ -f .env ]]; then
  source .env
elif [[ -f .env.example ]]; then
  cp .env.example .env
  source .env
else
  echo "ERROR: Missing .env and .env.example" >&2
  exit 1
fi

# ── Validate required variables ───────────────────────────────────────────────
: "${STELLAR_NETWORK:=testnet}"
: "${STELLAR_DEPLOYER_KEY:=deployer}"
: "${ATOMIC_SWAP_ADMIN:?ERROR: ATOMIC_SWAP_ADMIN must be set in .env}"
: "${ATOMIC_SWAP_FEE_BPS:=0}"
: "${ATOMIC_SWAP_FEE_RECIPIENT:?ERROR: ATOMIC_SWAP_FEE_RECIPIENT must be set in .env}"
: "${ATOMIC_SWAP_CANCEL_DELAY_SECS:=3600}"

# ── Check deployer key exists ─────────────────────────────────────────────────
if ! stellar keys show "$STELLAR_DEPLOYER_KEY" &>/dev/null; then
  echo "ERROR: Deployer key '$STELLAR_DEPLOYER_KEY' not found." >&2
  echo "       Run: stellar keys generate $STELLAR_DEPLOYER_KEY --network $STELLAR_NETWORK --fund" >&2
  exit 1
fi

# ── Check wasm artifacts exist ────────────────────────────────────────────────
WASM_DIR="target/wasm32-unknown-unknown/release"
for wasm in ip_registry atomic_swap zk_verifier; do
  if [[ ! -f "$WASM_DIR/${wasm}.wasm" ]]; then
    echo "ERROR: Missing wasm: $WASM_DIR/${wasm}.wasm" >&2
    echo "       Run: ./scripts/build.sh" >&2
    exit 1
  fi
done

# ── Helpers ───────────────────────────────────────────────────────────────────
deploy_contract() {
  local name="$1"
  local wasm_path="$2"
  local contract_id
  echo "Deploying $name..."
  if ! contract_id=$(stellar contract deploy \
    --wasm "$wasm_path" \
    --network "$STELLAR_NETWORK" \
    --source "$STELLAR_DEPLOYER_KEY" 2>&1); then
    echo "ERROR: Failed to deploy $name" >&2
    echo "       $contract_id" >&2
    exit 1
  fi
  printf '%s' "$contract_id"
}

invoke_contract() {
  local name="$1"
  local contract_id="$2"
  shift 2
  echo "Invoking $name..."
  if ! stellar contract invoke \
    --id "$contract_id" \
    --network "$STELLAR_NETWORK" \
    --source "$STELLAR_DEPLOYER_KEY" \
    -- "$@" 2>&1; then
    echo "ERROR: Failed to invoke $name (contract: $contract_id)" >&2
    exit 1
  fi
}

set_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '\n%s=%s\n' "$key" "$value" >> .env
  fi
  rm -f .env.bak
}

# ── Deploy contracts ──────────────────────────────────────────────────────────
echo ""
echo "=== Deploying contracts to $STELLAR_NETWORK ==="

IP_REGISTRY=$(deploy_contract "ip_registry" "$WASM_DIR/ip_registry.wasm")
echo "  ip_registry:  $IP_REGISTRY"

ATOMIC_SWAP=$(deploy_contract "atomic_swap" "$WASM_DIR/atomic_swap.wasm")
echo "  atomic_swap:  $ATOMIC_SWAP"

ZK_VERIFIER=$(deploy_contract "zk_verifier" "$WASM_DIR/zk_verifier.wasm")
echo "  zk_verifier:  $ZK_VERIFIER"

# ── Initialize atomic_swap ────────────────────────────────────────────────────
echo ""
echo "=== Initializing contracts ==="

invoke_contract "atomic_swap::initialize" "$ATOMIC_SWAP" \
  initialize \
  --admin "$ATOMIC_SWAP_ADMIN" \
  --fee_bps "$ATOMIC_SWAP_FEE_BPS" \
  --fee_recipient "$ATOMIC_SWAP_FEE_RECIPIENT" \
  --cancel_delay_secs "$ATOMIC_SWAP_CANCEL_DELAY_SECS"

# Optionally override the default dispute window (17280 ledgers ≈ 24h)
if [[ -n "${ATOMIC_SWAP_DISPUTE_WINDOW_LEDGERS:-}" ]]; then
  invoke_contract "atomic_swap::set_dispute_window" "$ATOMIC_SWAP" \
    set_dispute_window \
    --ledgers "$ATOMIC_SWAP_DISPUTE_WINDOW_LEDGERS"
fi

# ip_registry and zk_verifier require no initialization

# ── Write contract IDs back to .env ──────────────────────────────────────────
echo ""
echo "=== Writing contract IDs to .env ==="

set_env_var CONTRACT_IP_REGISTRY "$IP_REGISTRY"
set_env_var CONTRACT_ATOMIC_SWAP "$ATOMIC_SWAP"
set_env_var CONTRACT_ZK_VERIFIER "$ZK_VERIFIER"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Deployment complete ==="
echo "  CONTRACT_IP_REGISTRY=$IP_REGISTRY"
echo "  CONTRACT_ATOMIC_SWAP=$ATOMIC_SWAP"
echo "  CONTRACT_ZK_VERIFIER=$ZK_VERIFIER"
