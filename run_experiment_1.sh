#!/usr/bin/env bash
# Run the 16-seed (six malicious) plus 34-active-dialer Experiment 1.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BSC_DIR=${BSC_SOURCE_DIR:-"$ROOT_DIR/bsc"}
cd "$SCRIPT_DIR"
source .env
unset BOOT_ENODE

PYTHON="$SCRIPT_DIR/genesis/.venv/bin/python"
OUT_DIR=${EXPERIMENT_1_OUTPUT_DIR:-"$ROOT_DIR/data/experiment_1"}
STATE_DIR=.local/experiment_1_v2
MANIFEST="$STATE_DIR/peer_manifest.csv"
COLLECTION_SECONDS=${EXPERIMENT_1_DURATION:-300}
TD_OFFSET=${DL_EXP_TD_OFFSET:-10000000}
VICTIM_MAX_PEERS=50
VICTIM_DIAL_RATIO=3
SEEDER="$STATE_DIR/seed-discovery-db"
collector_pid=
run_succeeded=false
node0_config_backup=

usage() {
    echo "Usage: $0 [--duration SECONDS]"
    echo "Default observation window: 300 seconds"
}
while (($#)); do
    case "$1" in
        --duration) (($# >= 2)) || { usage >&2; exit 2; }; COLLECTION_SECONDS=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if ! [[ "$COLLECTION_SECONDS" =~ ^[1-9][0-9]*$ ]] || ((COLLECTION_SECONDS > 3600)); then
    echo "duration must be an integer between 1 and 3600 seconds" >&2
    exit 2
fi
if [[ "${BSC_CLUSTER_SIZE:-}" != 1 || ! -f .local/BSC_CLUSTER_SIZE || $(<.local/BSC_CLUSTER_SIZE) != 1 ]]; then
    echo "Experiment 1 requires an initialized BSC_CLUSTER_SIZE=1 chain" >&2
    exit 2
fi
if [[ ! -f .local/node0/genesis.json || ! -f .local/node0/hardforkTime.txt ]]; then
    echo "validator genesis is missing; initialize the one-validator chain first" >&2
    exit 2
fi
if [[ ! -x bin/geth || ! -x bin/bootnode || ! -x "$PYTHON" || ! -d "$BSC_DIR" ]]; then
    echo "geth, bootnode, Python environment, or BSC source is missing" >&2
    exit 2
fi

mkdir -p "$OUT_DIR"
if [[ -L "$OUT_DIR" ]]; then echo "refusing symlink output directory: $OUT_DIR" >&2; exit 2; fi
existing=$(find "$OUT_DIR" -mindepth 1 ! -name .gitkeep -print -quit)
if [[ -n "$existing" ]]; then
    echo "chart CSV output already exists at $OUT_DIR; archive it before rerunning" >&2
    exit 2
fi
mkdir -p "$OUT_DIR"
if [[ -L "$STATE_DIR" ]]; then echo "refusing symlink runtime directory: $STATE_DIR" >&2; exit 2; fi

stop_pidfile() {
    local file=$1 pid
    [[ -f "$file" ]] || return 0
    pid=$(cat "$file")
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 12); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
}

stop_runtime_nodes() {
    local file pid
    local -a pid_files=() pids=()
    if [[ -d "$STATE_DIR" ]]; then
        while IFS= read -r file; do
            pid_files+=("$file")
            pid=$(cat "$file" 2>/dev/null || true)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                pids+=("$pid")
            fi
        done < <(find "$STATE_DIR" -type f -name pid -print)
    fi
    if ((${#pids[@]})); then
        sleep 2
        for pid in "${pids[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
    fi
    for file in "${pid_files[@]}"; do rm -f "$file"; done
    stop_pidfile .local/bootnode/pid
    ./bsc_cluster.sh stop || true
}

archive_experiment_logs() {
    local source relative destination
    local archive_dir="$OUT_DIR/logs"
    mkdir -p "$archive_dir"

    if [[ -f .local/bootnode/bootnode.log ]]; then
        cp -p .local/bootnode/bootnode.log "$archive_dir/bootnode.log"
    fi

    if [[ -d .local/node0 ]]; then
        mkdir -p "$archive_dir/validator"
        while IFS= read -r -d '' source; do
            cp -p "$source" "$archive_dir/validator/${source##*/}"
        done < <(find .local/node0 -maxdepth 1 -type f -name 'bsc.log*' -print0)
    fi

    if [[ -d "$STATE_DIR" ]]; then
        while IFS= read -r -d '' source; do
            relative=${source#"$STATE_DIR"/}
            destination="$archive_dir/$relative"
            mkdir -p "$(dirname "$destination")"
            cp -p -- "$source" "$destination"
        done < <(find "$STATE_DIR" -type f \( -name 'console.log' -o -name 'init.log' -o -name 'bsc.log*' \) -print0)
    fi
}

restore_node0_config() {
    if [[ -n "$node0_config_backup" && -f "$node0_config_backup" && -f .local/node0/config.toml ]]; then
        cp "$node0_config_backup" .local/node0/config.toml
    fi
}

clean_failed_output() {
    [[ ! -L "$OUT_DIR" ]] || { echo "refusing to clean symlink output directory: $OUT_DIR" >&2; return 1; }
    find "$OUT_DIR" -mindepth 1 -maxdepth 1 ! -name .gitkeep -exec rm -rf -- {} +
}

on_exit() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$collector_pid" ]] && kill -0 "$collector_pid" 2>/dev/null; then
        kill "$collector_pid" 2>/dev/null || true
        wait "$collector_pid" 2>/dev/null || true
    fi
    stop_runtime_nodes
    restore_node0_config
    [[ ! -L "$STATE_DIR" ]] && rm -rf -- "$STATE_DIR"
    if [[ "$status" -ne 0 || "$run_succeeded" != true ]]; then clean_failed_output || true; fi
    exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rpc() {
    curl -fsS -m 3 -X POST "http://127.0.0.1:$1" \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}"
}

wait_rpc() {
    local port=$1 method=$2 tries=${3:-90}
    for _ in $(seq 1 "$tries"); do
        if rpc "$port" "$method" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "RPC $method on port $port did not become ready" >&2
    return 1
}

node_height() {
    rpc "$1" eth_blockNumber | "$PYTHON" -c 'import json,sys; print(int(json.load(sys.stdin)["result"],16))'
}

prepare_validator_discovery() {
    "$PYTHON" - .local/node0/config.toml <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
section = ""
discovery = admin = False
for i, line in enumerate(lines):
    key = line.strip()
    if key.startswith("[") and key.endswith("]"):
        section = key[1:-1]
    elif section == "Node.P2P" and re.match(r"^\s*NoDiscovery\s*=", line):
        prefix = line.split("=", 1)[0]
        lines[i] = prefix + "= false"
        discovery = True
    elif section == "Node" and re.match(r"^\s*HTTPModules\s*=", line):
        prefix, value = line.split("=", 1)
        modules = json.loads(value.strip())
        if "admin" not in modules:
            modules.append("admin")
        lines[i] = prefix.rstrip() + " = " + json.dumps(modules)
        admin = True
if not discovery or not admin:
    raise SystemExit("unable to enable discovery and admin RPC on validator")
path.write_text("\n".join(lines) + "\n")
PY
}

write_node_config() {
    local datadir=$1 p2p_port=$2 http_port=$3 nodiscover=$4 dial_ratio=$5 static_json=$6 max_peers=${7:-50}
    "$PYTHON" - config.toml "$datadir/config.toml" "$p2p_port" "$http_port" "$nodiscover" "$dial_ratio" "$static_json" "$max_peers" <<'PY'
import json
import re
import sys
from pathlib import Path

src, dst, p2p, http, nodiscover, dial_ratio, static_json, max_peers = sys.argv[1:]
content = Path(src).read_text()
content = re.sub(r"(HTTPPort\s*=\s*)\d+", rf"\g<1>{http}", content)
content = re.sub(r"(HTTPHost\s*=\s*)\"[^\"]*\"", r'\g<1>"127.0.0.1"', content)
content = re.sub(r"(WSPort\s*=\s*)\d+", rf"\g<1>{int(http) + 1000}", content)
content = re.sub(r"(WSHost\s*=\s*)\"[^\"]*\"", r'\g<1>"127.0.0.1"', content)
content = re.sub(r"\[Node\.P2P\].*?(?=\n\[|\Z)", "", content, flags=re.S).rstrip()
static_nodes = json.loads(static_json)
content += f'''\n\n[Node.P2P]
MaxPeers = {max_peers}
DialRatio = {dial_ratio}
NoDiscovery = {nodiscover.lower()}
ListenAddr = ":{p2p}"
StaticNodes = {json.dumps(static_nodes)}
TrustedNodes = []
BootstrapNodes = []
EnableMsgEvents = false
PeerFilterPatterns = []
'''
content = re.sub(r'(?m)^(\s*Level\s*=\s*)"debug"', r'\g<1>"info"', content)
Path(dst).write_text(content)
PY
}

prepare_peer() {
    local label=$1 cohort=$2 role=$3 datadir=$4 p2p=$5 http=$6 nodiscover=$7 dial_ratio=$8
    shift 8
    local static_json pubkey enode_url peer_id
    static_json=$("$PYTHON" -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")
    mkdir -p "$datadir/geth"
    openssl rand -hex 32 > "$datadir/geth/nodekey"
    pubkey=$(./bin/bootnode -nodekey "$datadir/geth/nodekey" -writeaddress)
    enode_url="enode://${pubkey}@127.0.0.1:${p2p}?discport=${p2p}"
    peer_id=$("$PYTHON" - "$pubkey" <<'PY'
import sys
from Crypto.Hash import keccak
k = keccak.new(digest_bits=256)
k.update(bytes.fromhex(sys.argv[1]))
print(k.hexdigest())
PY
)
    write_node_config "$datadir" "$p2p" "$http" "$nodiscover" "$dial_ratio" "$static_json"
    ./bin/geth --datadir "$datadir" init --state.scheme hash --db.engine leveldb \
        .local/node0/genesis.json > "$datadir/init.log" 2>&1
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$peer_id" "$label" "$cohort" "$role" "$enode_url" "$p2p" "$http" >> "$MANIFEST"
    PREPARED_DIR=$datadir
    PREPARED_ENODE=$enode_url
    PREPARED_ID=$peer_id
}

start_peer() {
    local datadir=$1 p2p=$2 http=$3 experiment_enabled=${4:-false} discovery_mode=${5:-nodiscover} max_peers=${6:-50}
    local -a attack_env=()
    local -a discovery_args=()
    case "$discovery_mode" in
        bootnode) discovery_args=(--bootnodes "$BOOT_ENODE" --discovery.v4) ;;
        discovery) discovery_args=(--discovery.v4) ;;
        nodiscover) discovery_args=(--nodiscover) ;;
        *) echo "invalid discovery mode: $discovery_mode" >&2; return 2 ;;
    esac
    if [[ "$experiment_enabled" == true ]]; then
        attack_env=(
            BSC_DOWNLOADER_EXPERIMENT_ENABLED=1
            BSC_DOWNLOADER_EXPERIMENT_NETWORK_ID="$CHAIN_ID"
            BSC_DOWNLOADER_EXPERIMENT_VICTIM_IDS="$VICTIM_NODE_ID"
            BSC_DOWNLOADER_EXPERIMENT_TD_OFFSET="$TD_OFFSET"
        )
    fi
    nohup env "${attack_env[@]}" ./bin/geth \
        --config "$datadir/config.toml" --datadir "$datadir" --nodekey "$datadir/geth/nodekey" \
        --ipcdisable \
        --port "$p2p" --http --http.addr 127.0.0.1 --http.port "$http" \
        --http.api eth,net,admin,debug --http.vhosts '*' \
        "${discovery_args[@]}" \
        --networkid "$CHAIN_ID" --maxpeers "$max_peers" --cache 64 --syncmode full --gcmode full --state.scheme hash \
        --rialtohash "$RIALTO_HASH" \
        --override.passedforktime "$PASSED_FORK_TIME" \
        --override.lorentz "$PASSED_FORK_TIME" --override.maxwell "$PASSED_FORK_TIME" \
        --override.fermi "$PASSED_FORK_TIME" --override.osaka "$PASSED_FORK_TIME" \
        --override.mendel "$PASSED_FORK_TIME" --override.pasteur "$LAST_FORK_TIME" \
        --override.immutabilitythreshold "$FullImmutabilityThreshold" \
        --override.minforblobrequest "$MinBlocksForBlobRequests" \
        --override.defaultextrareserve "$DefaultExtraReserveForBlobRequests" \
        >> "$datadir/console.log" 2>&1 &
    echo $! > "$datadir/pid"
}

wait_for_normal_sync() {
    local port=$1 reference current
    echo "[experiment-1] Waiting for honest peer $port to catch up"
    for _ in $(seq 1 600); do
        reference=$(node_height 8545) || { sleep 1; continue; }
        current=$(node_height "$port") || { sleep 1; continue; }
        if ((current >= reference - 10)); then return 0; fi
        sleep 1
    done
    echo "honest peer at RPC $port did not catch up with consensus node" >&2
    return 1
}

echo "[experiment-1] Topology: DB seeds 6 malicious + 10 honest; active dialers 33 malicious + 1 honest"
echo "[experiment-1] Window: ${COLLECTION_SECONDS}s; DB candidates=16; active dialers=34; victim defaults MaxPeers=${VICTIM_MAX_PEERS}, DialRatio=${VICTIM_DIAL_RATIO}"

if [[ -d "$STATE_DIR" ]]; then
    stop_runtime_nodes
    rm -rf -- "$STATE_DIR"
fi
mkdir -p "$STATE_DIR"
node0_config_backup="$STATE_DIR/node0-config.original"
cp .local/node0/config.toml "$node0_config_backup"
MANIFEST="$STATE_DIR/peer_manifest.csv"
printf 'peer_id,label,cohort,role,enode,p2p_port,http_port\n' > "$MANIFEST"
stop_runtime_nodes

./start_bootnode.sh
BOOT_ENODE=$(<.local/bootnode/enode.txt)
export BOOT_ENODE
prepare_validator_discovery
./bsc_cluster.sh restart
wait_rpc 8545 eth_blockNumber
node_info=$(rpc 8545 admin_nodeInfo)
read -r VALIDATOR_ID VALIDATOR_ENODE < <("$PYTHON" -c 'import json,sys; n=json.load(sys.stdin)["result"]; print(n["id"].lower(),n["enode"])' <<< "$node_info")
RIALTO_HASH=$(awk -F'hash=' '/Successfully wrote genesis state/{print $2}' .local/node0/init.log | awk '{print $1}')
PASSED_FORK_TIME=$(awk '/passedHardforkTime/{print $2}' .local/node0/hardforkTime.txt)
LAST_FORK_TIME=$((PASSED_FORK_TIME + LAST_FORK_MORE_DELAY))
[[ -n "$RIALTO_HASH" && -n "$VALIDATOR_ID" && -n "$VALIDATOR_ENODE" ]] || {
    echo "failed to read validator identity or genesis settings" >&2; exit 1;
}
printf '%s,db-honest-validator,db,honest,%s,30303,8545\n' \
    "$VALIDATOR_ID" "$VALIDATOR_ENODE" >> "$MANIFEST"

VICTIM_P2P=30401
VICTIM_HTTP=8645
VICTIM_KEY="$STATE_DIR/victim/geth/nodekey"
mkdir -p "$(dirname "$VICTIM_KEY")"
cp keys/victim-nodekey "$VICTIM_KEY"
victim_pubkey=$(./bin/bootnode -nodekey "$VICTIM_KEY" -writeaddress)
VICTIM_NODE_ID=$("$PYTHON" - "$victim_pubkey" <<'PY'
import sys
from Crypto.Hash import keccak
k = keccak.new(digest_bits=256)
k.update(bytes.fromhex(sys.argv[1]))
print(k.hexdigest())
PY
)
VICTIM_ENODE="enode://${victim_pubkey}@127.0.0.1:${VICTIM_P2P}?discport=${VICTIM_P2P}"

echo "[experiment-1] Preparing 6 malicious + 9 additional honest DB peers, plus the honest validator"
DB_SEED_URLS=("$VALIDATOR_ENODE")
DB_PEER_PORTS=()
for index in $(seq 0 5); do
    label=$(printf 'db-malicious-%02d' "$index")
    p2p=$((31000 + index))
    http=$((8800 + index))
    dir="$STATE_DIR/db-peers/$label"
    prepare_peer "$label" db malicious "$dir" "$p2p" "$http" false 3 "$VALIDATOR_ENODE"
    DB_SEED_URLS+=("$PREPARED_ENODE")
    DB_PEER_PORTS+=("$http")
    start_peer "$PREPARED_DIR" "$p2p" "$http" true bootnode
done

DB_HONEST_PORTS=()
for index in $(seq 1 9); do
    label=$(printf 'db-honest-%02d' "$index")
    p2p=$((31005 + index))
    http=$((8805 + index))
    dir="$STATE_DIR/db-peers/$label"
    prepare_peer "$label" db honest "$dir" "$p2p" "$http" false 3 "$VALIDATOR_ENODE"
    DB_SEED_URLS+=("$PREPARED_ENODE")
    DB_HONEST_PORTS+=("$http")
    DB_PEER_PORTS+=("$http")
    start_peer "$PREPARED_DIR" "$p2p" "$http" false bootnode
done

echo "[experiment-1] Preparing 33 active malicious + 1 active honest dialer"
ACTIVE_EVIL_DIRS=()
ACTIVE_PEER_PORTS=()
for index in $(seq 1 33); do
    label=$(printf 'active-malicious-%02d' "$index")
    p2p=$((31100 + index - 1))
    http=$((8900 + index - 1))
    dir="$STATE_DIR/active-peers/$label"
    prepare_peer "$label" active malicious "$dir" "$p2p" "$http" true 3 "$VICTIM_ENODE"
    ACTIVE_EVIL_DIRS+=("$PREPARED_DIR:$p2p:$http")
    ACTIVE_PEER_PORTS+=("$http")
done
ACTIVE_HONEST_DIR="$STATE_DIR/active-peers/active-honest-01"
prepare_peer active-honest-01 active honest "$ACTIVE_HONEST_DIR" 31133 8933 true 3 "$VALIDATOR_ENODE" "$VICTIM_ENODE"
ACTIVE_HONEST_PORT=8933
ACTIVE_PEER_PORTS+=("$ACTIVE_HONEST_PORT")
for entry in "${ACTIVE_EVIL_DIRS[@]}"; do
    IFS=: read -r dir p2p http <<< "$entry"
    start_peer "$dir" "$p2p" "$http" true nodiscover
done
start_peer "$ACTIVE_HONEST_DIR" 31133 8933 false nodiscover

CONTROL_DIR="$STATE_DIR/normal-sync"
prepare_peer normal-sync-control control honest "$CONTROL_DIR" 30601 8665 true 3 "$VALIDATOR_ENODE"
start_peer "$PREPARED_DIR" 30601 8665 false nodiscover

wait_rpc 8665 eth_blockNumber
for port in "${DB_PEER_PORTS[@]}" "${ACTIVE_PEER_PORTS[@]}"; do
    if ! wait_rpc "$port" eth_blockNumber 15; then
        echo "candidate peer RPC failed on port $port" >&2
        exit 1
    fi
done
for index in "${DB_HONEST_PORTS[@]}" "$ACTIVE_HONEST_PORT"; do
    wait_rpc "$index" eth_blockNumber
done
wait_for_normal_sync 8665
for index in "${DB_HONEST_PORTS[@]}" "$ACTIVE_HONEST_PORT"; do
    wait_for_normal_sync "$index"
done

VICTIM_DIR="$STATE_DIR/victim"
mkdir -p "$VICTIM_DIR/geth"
cp keys/password.txt "$VICTIM_DIR/password.txt"
cp .local/node0/hardforkTime.txt "$VICTIM_DIR/hardforkTime.txt"
write_node_config "$VICTIM_DIR" "$VICTIM_P2P" "$VICTIM_HTTP" false "$VICTIM_DIAL_RATIO" '[]' "$VICTIM_MAX_PEERS"
./bin/geth --datadir "$VICTIM_DIR" init --state.scheme hash --db.engine leveldb \
    .local/node0/genesis.json > "$VICTIM_DIR/init.log" 2>&1
(
    cd "$BSC_DIR"
    go build -o "$SCRIPT_DIR/$SEEDER" "$SCRIPT_DIR/seed_discovery_db.go"
)
"$SEEDER" "$VICTIM_DIR/geth/nodes" "${DB_SEED_URLS[@]}"

echo "[experiment-1] Starting victim; peer discovery is seeded only from its nodes DB"
T0_EPOCH=$(date +%s.%N)
EXPERIMENT_1_RUNTIME_DIR="$STATE_DIR" "$PYTHON" ./analyze_experiment_1.py collect \
    --start-epoch "$T0_EPOCH" --duration "$COLLECTION_SECONDS" --max-peers "$VICTIM_MAX_PEERS" &
collector_pid=$!
start_peer "$VICTIM_DIR" "$VICTIM_P2P" "$VICTIM_HTTP" false discovery "$VICTIM_MAX_PEERS"
wait_rpc "$VICTIM_HTTP" eth_blockNumber
wait "$collector_pid"
collector_pid=

echo "[experiment-1] Collection complete; stopping nodes and deriving sync timeline"
stop_runtime_nodes
EXPERIMENT_1_RUNTIME_DIR="$STATE_DIR" "$PYTHON" ./analyze_experiment_1.py finalize \
    --start-epoch "$T0_EPOCH" --duration "$COLLECTION_SECONDS" --out-dir "$OUT_DIR"
archive_experiment_logs
run_succeeded=true
echo "[experiment-1] Complete. Chart CSVs: $OUT_DIR"
