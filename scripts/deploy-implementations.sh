#!/usr/bin/env bash
# Deploy every protocol implementation (and the standalone contracts) via ge-publish.
# Calibur is separate and already live on Gnosis.
#
# Fish:
#   set -x PRIVATE_KEY 0x...
#   set -x RPC_URL https://rpc.gnosischain.com
#   set -x CHAIN_ID 100
#   bash scripts/deploy-implementations.sh
#
# Optional env:
#   ADMIN          RescueVault constructor admin (defaults to the deployer)
#   GAS_FEE_CAP    EIP-1559 fee cap wei (default 2000000000)
#   GAS_TIP_CAP    EIP-1559 tip wei (default 1000000000)
#   SKIP_BUILD=1   skip go build / make artifacts

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "PRIVATE_KEY is required (export it, or in fish: set -x PRIVATE_KEY 0x...)" >&2
  exit 1
fi

RPC_URL="${RPC_URL:-https://rpc.gnosischain.com}"
CHAIN_ID="${CHAIN_ID:-100}"
GAS_FEE_CAP="${GAS_FEE_CAP:-2000000000}"
GAS_TIP_CAP="${GAS_TIP_CAP:-1000000000}"
ADMIN="${ADMIN:-}"

if [[ "${SKIP_BUILD:-}" != "1" ]]; then
  echo "==> building ge-publish and artifacts"
  go build -o ./ge-publish ./cmd/ge-publish
  make all
fi

if [[ ! -x ./ge-publish ]]; then
  echo "./ge-publish is missing; run without SKIP_BUILD=1" >&2
  exit 1
fi

BASE=(
  --rpc-url "$RPC_URL"
  --chain-id "$CHAIN_ID"
  --private-key "$PRIVATE_KEY"
  --gas-fee-cap "$GAS_FEE_CAP"
  --gas-tip-cap "$GAS_TIP_CAP"
)

IMPLS=(
  erc1967factory
  accountsindex
  cat
  contractregistry
  ethfaucet
  feepolicy
  giftabletoken
  limiter
  oraclequoter
  oraclerelay
  periodsimple
  pfc
  relativequoter
  splitter
  swappool
  tokenuniquesymbolindex
  decimalquoter
  swaprouter
  rescuevault
)

OUT_DIR="$ROOT/deployments"
mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
JSON_OUT="$OUT_DIR/implementations-${CHAIN_ID}-${STAMP}.json"
ENV_OUT="$OUT_DIR/implementations-${CHAIN_ID}-${STAMP}.env"
: >"$ENV_OUT"
echo "{\"chain_id\":${CHAIN_ID},\"rpc_url\":\"${RPC_URL}\",\"addresses\":{" >"$JSON_OUT"
first=1

echo "==> deploying ${#IMPLS[@]} contracts on chain ${CHAIN_ID} (${RPC_URL})"

for name in "${IMPLS[@]}"; do
  echo
  echo "==> ${name}"
  extra=()
  if [[ "$name" == "rescuevault" && -n "$ADMIN" ]]; then
    extra+=(--admin "$ADMIN")
  fi
  raw="$(./ge-publish deploy-impl --contract "$name" "${BASE[@]}" "${extra[@]}")"
  echo "$raw"
  addr="$(python3 -c '
import json,sys
raw=sys.stdin.read()
start=raw.find("{")
if start<0:
    sys.exit("no json in ge-publish output")
data=json.loads(raw[start:])
addr=data.get("factory") or data.get("decimal_quoter")
if not addr:
    impls=data.get("implementations") or {}
    if impls:
        addr=next(iter(impls.values()))
if not addr:
    sys.exit("could not parse address")
print(addr)
' <<<"$raw")"
  key="$(echo "$name" | tr '[:lower:]' '[:upper:]')"
  printf '%s=%s\n' "$key" "$addr" >>"$ENV_OUT"
  if [[ $first -eq 0 ]]; then
    echo "," >>"$JSON_OUT"
  fi
  first=0
  printf '  "%s": "%s"' "$name" "$addr" >>"$JSON_OUT"
done

echo >>"$JSON_OUT"
echo "}}" >>"$JSON_OUT"
ln -sfn "$(basename "$JSON_OUT")" "$OUT_DIR/implementations-latest.json"
ln -sfn "$(basename "$ENV_OUT")" "$OUT_DIR/implementations-latest.env"

echo
echo "==> done"
echo "json: $JSON_OUT"
echo "env:  $ENV_OUT"
column -t -s= "$ENV_OUT"
