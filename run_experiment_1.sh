#!/usr/bin/env bash
# Run one 300-second Experiment 1 and produce samples, event and period CSVs.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source .env

ATTACKER_COUNT=${1:-50}
COLLECTION_SECONDS=300
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/data/experiment_1"
BOOT_PID_FILE=.local/bootnode/pid

if ! [[ "$ATTACKER_COUNT" =~ ^[1-9][0-9]*$ ]] || [ "$ATTACKER_COUNT" -gt 100 ]; then
    echo "attacker count must be between 1 and 100" >&2
    echo "usage: $0 [attacker_count]" >&2
    exit 2
fi
if [ "${BSC_CLUSTER_SIZE:-}" != 1 ]; then
    echo "Experiment 1 requires BSC_CLUSTER_SIZE=1; set it in .env and initialize that cluster first." >&2
    exit 2
fi
if [ ! -d .local/node0 ] || [ ! -f .local/node0/genesis.json ]; then
    echo "Honest cluster is not initialized. Run ./bsc_cluster.sh reset first, then rerun this script." >&2
    exit 2
fi
if [ ! -f .local/BSC_CLUSTER_SIZE ] || [ "$(cat .local/BSC_CLUSTER_SIZE)" != 1 ]; then
    echo "The initialized cluster is not marked as a one-validator Experiment 1 cluster. Run ./bsc_cluster.sh reset with BSC_CLUSTER_SIZE=1." >&2
    exit 2
fi
if [ ! -x bin/geth ] || [ ! -x bin/bootnode ]; then
    echo "Missing node-deploy/bin/geth or bin/bootnode. Build/copy the BSC binaries first." >&2
    exit 2
fi
if [ -e "$OUT_DIR/samples.csv" ]; then
    echo "Results already exist at $OUT_DIR; archive them before starting a new run." >&2
    exit 2
fi
existing_artifact=$(find "$OUT_DIR" -mindepth 1 ! -name .gitkeep -print -quit 2>/dev/null || true)
if [ -n "$existing_artifact" ]; then
    echo "Experiment output directory is not empty: $OUT_DIR; archive it before starting a new run." >&2
    exit 2
fi

mkdir -p "$OUT_DIR/logs/attackers"
collector_pid=

stop_pidfile() {
    local file=$1 pid
    [ -f "$file" ] || return 0
    pid=$(cat "$file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
}

stop_attackers() {
    local -a pids=()
    for file in .local/attackers/attacker-*/pid; do
        [ -f "$file" ] || continue
        pid=$(cat "$file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            pids+=("$pid")
        fi
        rm -f "$file"
    done
    for pid in "${pids[@]}"; do
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$pid" 2>/dev/null || true
    done
}

stop_experiment_nodes() {
    stop_attackers
    stop_pidfile .local/victim/pid
    stop_pidfile .local/normal-sync/pid
    stop_pidfile "$BOOT_PID_FILE"
    ./bsc_cluster.sh stop || true
}

clean_failed_output() {
    python3 - "$OUT_DIR" <<'PY'
import shutil
import sys
from pathlib import Path

output_dir = Path(sys.argv[1]).resolve()
if output_dir.is_symlink():
    raise SystemExit(f"refusing to clean symlink output directory: {output_dir}")
for entry in output_dir.iterdir():
    if entry.name == ".gitkeep":
        continue
    if entry.is_dir() and not entry.is_symlink():
        shutil.rmtree(entry)
    else:
        entry.unlink()
PY
}

on_exit() {
    local status=$?
    trap - EXIT INT TERM
    if [ -n "$collector_pid" ] && kill -0 "$collector_pid" 2>/dev/null; then
        kill "$collector_pid" 2>/dev/null || true
        wait "$collector_pid" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then
        stop_experiment_nodes
        clean_failed_output || echo "[experiment-1] WARNING: failed-run output cleanup did not complete: $OUT_DIR" >&2
    fi
    exit "$status"
}
trap on_exit EXIT INT TERM

wait_rpc() {
    local port=$1 method=$2 tries=${3:-90}
    for _ in $(seq 1 "$tries"); do
        if curl -fsS -m 2 -X POST "http://127.0.0.1:${port}" \
            -H 'Content-Type: application/json' \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":[],\"id\":1}" >/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "RPC $method on port $port did not become ready" >&2
    return 1
}

node_height() {
    curl -fsS -m 3 -X POST "http://127.0.0.1:$1" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' |
        python3 -c 'import json,sys; print(int(json.load(sys.stdin)["result"], 16))'
}

prepare_honest_discovery() {
    python3 - .local/node0/config.toml <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
section = ""
discovery_configured = False
http_modules_configured = False
for index, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped[1:-1]
        continue
    if section == "Node.P2P":
        match = re.match(r"^(\s*NoDiscovery\s*=\s*)(true|false)(\s*(?:#.*)?)$", line, re.I)
        if match:
            lines[index] = match.group(1) + "false" + match.group(3)
            discovery_configured = True
    elif section == "Node" and re.match(r"^\s*HTTPModules\s*=", line):
        prefix, value = line.split("=", 1)
        modules = json.loads(value.strip())
        if "admin" not in modules:
            modules.append("admin")
        lines[index] = prefix.rstrip() + " = " + json.dumps(modules)
        http_modules_configured = True
if not discovery_configured or not http_modules_configured:
    raise SystemExit("unable to configure honest node discovery/admin peer RPC")
path.write_text("\n".join(lines) + "\n")
PY
}

wait_for_normal_sync_progress() {
    local current_height=0
    echo "[experiment-1] Waiting for normal-sync control to import blocks before attack"
    for _ in $(seq 1 60); do
        current_height=$(node_height 8665)
        if [ "$current_height" -gt 0 ]; then
            echo "[experiment-1] Normal-sync control reached height $current_height"
            return 0
        fi
        sleep 3
    done
    echo "Normal-sync control did not advance from genesis; refusing to collect an invalid control run." >&2
    return 1
}

archive_node_logs() {
    local source_dir=$1 output=$2 file copied=false
    : > "$output"
    for file in "$source_dir"/bsc.log* "$source_dir"/bsc-node.log "$source_dir"/attacker.log; do
        [ -f "$file" ] || continue
        cat "$file" >> "$output"
        printf '\n' >> "$output"
        copied=true
    done
    [ "$copied" = true ]
}

clean_old_experiment_processes() {
    stop_attackers
    stop_pidfile .local/victim/pid
    stop_pidfile .local/normal-sync/pid
    stop_pidfile "$BOOT_PID_FILE"
    rm -rf .local/attackers .local/victim .local/normal-sync
}

echo "[experiment-1] Starting one run: 1 honest + 1 normal-sync + 1 victim + ${ATTACKER_COUNT} attackers + 1 bootnode"
clean_old_experiment_processes

echo "[experiment-1] Starting bootnode after cluster initialization"
./start_bootnode.sh
BOOT_ENODE=$(cat .local/bootnode/enode.txt)
export BOOT_ENODE

echo "[experiment-1] Enabling discovery and admin peer sampling on honest validator"
prepare_honest_discovery

echo "[experiment-1] Restarting honest validator with bootnode discovery"
BOOT_ENODE="$BOOT_ENODE" ./bsc_cluster.sh restart
wait_rpc 8545 eth_blockNumber

echo "[experiment-1] Waiting for honest chain to advance"
initial_height=$(node_height 8545)
for _ in $(seq 1 60); do
    sleep 3
    current_height=$(node_height 8545)
    [ "$current_height" -gt "$initial_height" ] && break
done
if [ "$current_height" -le "$initial_height" ]; then
    echo "Honest validator did not produce blocks; stopping before data collection." >&2
    exit 1
fi

echo "[experiment-1] Starting normal-sync control from genesis"
BOOT_ENODE="$BOOT_ENODE" ./start_experiment_observer.sh normal-sync start
wait_rpc 8665 eth_blockNumber

echo "[experiment-1] Preparing clean victim and attacker datadirs"
BOOT_ENODE="$BOOT_ENODE" ./dl_experiment.sh setup
./setup_multi_attackers.sh "$ATTACKER_COUNT"
wait_for_normal_sync_progress

echo "[experiment-1] Starting attackers, then victim"
./start_multi_attackers.sh "$ATTACKER_COUNT"
T0_EPOCH=$(python3 -c 'import time; print(time.time())')
printf '%s\n' "$T0_EPOCH" > "$OUT_DIR/run_start_epoch.txt"
BOOT_ENODE="$BOOT_ENODE" ./start_experiment_observer.sh victim start
wait_rpc 8645 eth_blockNumber

echo "[experiment-1] Sampling every 5 seconds for ${COLLECTION_SECONDS} seconds; attack remains active throughout"
EXPERIMENT_1_OUTPUT_DIR="$OUT_DIR" python3 ./analyze_experiment_1.py collect "$T0_EPOCH" &
collector_pid=$!
wait "$collector_pid"
collector_pid=

echo "[experiment-1] Collection complete; preserving logs before stopping experiment nodes"
echo "[experiment-1] Saving original logs"
archive_node_logs .local/node0 "$OUT_DIR/logs/honest.log" || true
archive_node_logs .local/normal-sync "$OUT_DIR/logs/normal_sync.log" || true
archive_node_logs .local/victim "$OUT_DIR/logs/victim.log" || true
cp .local/bootnode/bootnode.log "$OUT_DIR/logs/bootnode.log" 2>/dev/null || true
for dir in .local/attackers/attacker-*; do
    [ -d "$dir" ] || continue
    archive_node_logs "$dir" "$OUT_DIR/logs/attackers/$(basename "$dir").log" || true
done

EXPERIMENT_1_OUTPUT_DIR="$OUT_DIR" python3 ./analyze_experiment_1.py analyze
stop_experiment_nodes
trap - EXIT INT TERM
echo "[experiment-1] Complete. CSV results: $OUT_DIR"
