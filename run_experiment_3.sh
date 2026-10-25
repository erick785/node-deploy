#!/usr/bin/env bash
# Run four matching peer-pool and victim MaxPeers configurations.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
BSC_DIR=${BSC_SOURCE_DIR:-"$ROOT_DIR/bsc"}
cd "$SCRIPT_DIR"
source .env
unset BOOT_ENODE

PYTHON="$SCRIPT_DIR/genesis/.venv/bin/python"
OUT_DIR=${EXPERIMENT_3_OUTPUT_DIR:-"$ROOT_DIR/data/experiment_3"}
STATE_DIR=${EXPERIMENT_3_STATE_DIR:-.local/experiment_3}
DURATION=300
TRIALS=10
RETRY_LIMIT=3
GROUP_FILTER=
CHILD_PID=
CURRENT_ATTEMPT_DIR=
DIAL_RATIO=3
TD_OFFSET=${DL_EXP_TD_OFFSET:-10000000}
EXPERIMENT_LABEL=experiment-3
CHILD_MODE=false
OUT_ATTEMPT=
collector_pid=
node0_config_backup=

GROUP_IDS=(group_01 group_02 group_03 group_04)
TOTAL_PEERS=(40 50 60 70)
MAX_PEERS=(40 50 60 70)
DB_MALICIOUS=(6 6 10 10)
DB_HONEST=(7 10 10 13)
ACTIVE_MALICIOUS=(13 17 20 23)
ACTIVE_HONEST=(14 17 20 24)

usage() {
    cat <<'EOF'
Usage: ./run_experiment_3.sh [--duration SECONDS] [--trials COUNT] [--group ID] [--retry-limit COUNT]

Defaults: candidate-peer-pool sizes and victim MaxPeers of 40/50/60/70, 10 valid
trials per group, 300 seconds per trial. GROUP_ID is group_01 through group_04.
EOF
}

if [[ "${1:-}" == "__trial" ]]; then
    (($# == 12)) || { echo "invalid internal trial arguments" >&2; exit 2; }
    shift
    GROUP_ID=$1
    RATIO=$2
    DB_MALICIOUS=$3
    DB_HONEST_TOTAL=$4
    ACTIVE_MALICIOUS=$5
    ACTIVE_HONEST=$6
    TRIAL=$7
    MAX_PEERS=$8
    DURATION=$9
    OUT_ATTEMPT=$(realpath -m -- "${10}")
    STATE_DIR=$(realpath -m -- "${11}")
    CHILD_MODE=true
else
    while (($#)); do
        case "$1" in
            --duration) (($# >= 2)) || { usage >&2; exit 2; }; DURATION=$2; shift 2 ;;
            --trials) (($# >= 2)) || { usage >&2; exit 2; }; TRIALS=$2; shift 2 ;;
            --group) (($# >= 2)) || { usage >&2; exit 2; }; GROUP_FILTER=$2; shift 2 ;;
            --retry-limit) (($# >= 2)) || { usage >&2; exit 2; }; RETRY_LIMIT=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
fi

if ! [[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || ((DURATION > 3600)); then
    echo "duration must be an integer between 1 and 3600 seconds" >&2; exit 2
fi
if ! [[ "$TRIALS" =~ ^[1-9][0-9]*$ ]] || ((TRIALS > 100)); then
    echo "trials must be an integer between 1 and 100" >&2; exit 2
fi
if ! [[ "$RETRY_LIMIT" =~ ^[1-9][0-9]*$ ]] || ((RETRY_LIMIT > 20)); then
    echo "retry limit must be an integer between 1 and 20" >&2; exit 2
fi
if [[ "${BSC_CLUSTER_SIZE:-}" != 1 ]]; then
    echo "Experiment 3 requires BSC_CLUSTER_SIZE=1 in .env" >&2; exit 2
fi
if [[ ! -x bin/geth || ! -x bin/bootnode || ! -x "$PYTHON" || ! -d "$BSC_DIR" ]]; then
    echo "geth, bootnode, Python environment, or BSC source is missing" >&2; exit 2
fi
if [[ -L "$OUT_DIR" || -L "$STATE_DIR" ]]; then
    echo "refusing symlink experiment output or runtime directory" >&2; exit 2
fi

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

wait_for_victim_peers() {
    local minimum=${1:-5} count
    for _ in $(seq 1 90); do
        count=$(rpc 8645 admin_peers 2>/dev/null | "$PYTHON" -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))' 2>/dev/null || echo 0)
        if ((count >= minimum)); then return 0; fi
        sleep 1
    done
    echo "victim reached fewer than $minimum peers before sampling" >&2
    return 1
}

node_height() {
    rpc "$1" eth_blockNumber | "$PYTHON" -c 'import json,sys; print(int(json.load(sys.stdin)["result"],16))'
}

prepare_validator_discovery() {
    "$PYTHON" - .local/node0/config.toml <<'PY'
import json, re, sys
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
        lines[i] = line.split("=", 1)[0] + "= false"
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
    local datadir=$1 p2p=$2 http=$3 nodiscover=$4 static_json=$5 max_peers=${6:-50}
    "$PYTHON" - config.toml "$datadir/config.toml" "$p2p" "$http" "$nodiscover" "$static_json" "$max_peers" "$DIAL_RATIO" <<'PY'
import json, re, sys
from pathlib import Path
src, dst, p2p, http, nodiscover, static_json, max_peers, dial_ratio = sys.argv[1:]
content = Path(src).read_text()
content = re.sub(r"(HTTPPort\s*=\s*)\d+", rf"\g<1>{http}", content)
content = re.sub(r'(HTTPHost\s*=\s*)"[^"]*"', r'\g<1>"127.0.0.1"', content)
content = re.sub(r"(WSPort\s*=\s*)\d+", rf"\g<1>{int(http) + 1000}", content)
content = re.sub(r'(WSHost\s*=\s*)"[^"]*"', r'\g<1>"127.0.0.1"', content)
content = re.sub(r"\[Node\.P2P\].*?(?=\n\[|\Z)", "", content, flags=re.S).rstrip()
content += f'''\n\n[Node.P2P]
MaxPeers = {max_peers}
DialRatio = {dial_ratio}
NoDiscovery = {nodiscover.lower()}
ListenAddr = ":{p2p}"
StaticNodes = {json.dumps(json.loads(static_json))}
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
    local label=$1 cohort=$2 role=$3 datadir=$4 p2p=$5 http=$6 nodiscover=$7
    shift 7
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
    write_node_config "$datadir" "$p2p" "$http" "$nodiscover" "$static_json"
    ./bin/geth --datadir "$datadir" init --state.scheme hash --db.engine leveldb \
        .local/node0/genesis.json > "$datadir/init.log" 2>&1
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$peer_id" "$label" "$cohort" "$role" "$enode_url" "$p2p" "$http" >> "$MANIFEST"
    PREPARED_DIR=$datadir
    PREPARED_ENODE=$enode_url
}

start_peer() {
    local datadir=$1 p2p=$2 http=$3 experiment_enabled=${4:-false} discovery_mode=${5:-nodiscover} max_peers=${6:-50}
    local -a attack_env=() discovery_args=()
    case "$discovery_mode" in
        bootnode) discovery_args=(--bootnodes "$BOOT_ENODE" --discovery.v4) ;;
        discovery) discovery_args=(--discovery.v4) ;;
        nodiscover) discovery_args=(--nodiscover) ;;
        *) echo "invalid discovery mode: $discovery_mode" >&2; return 2 ;;
    esac
    if [[ "$experiment_enabled" == true ]]; then
        attack_env=(BSC_DOWNLOADER_EXPERIMENT_ENABLED=1
            BSC_DOWNLOADER_EXPERIMENT_NETWORK_ID="$CHAIN_ID"
            BSC_DOWNLOADER_EXPERIMENT_VICTIM_IDS="$VICTIM_NODE_ID"
            BSC_DOWNLOADER_EXPERIMENT_TD_OFFSET="$TD_OFFSET")
    fi
    nohup env "${attack_env[@]}" ./bin/geth \
        --config "$datadir/config.toml" --datadir "$datadir" --nodekey "$datadir/geth/nodekey" --ipcdisable \
        --port "$p2p" --http --http.addr 127.0.0.1 --http.port "$http" \
        --http.api eth,net,admin,debug --http.vhosts '*' "${discovery_args[@]}" \
        --networkid "$CHAIN_ID" --maxpeers "$max_peers" --cache 64 --syncmode full --gcmode full --state.scheme hash \
        --rialtohash "$RIALTO_HASH" --override.passedforktime "$PASSED_FORK_TIME" \
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
    for _ in $(seq 1 600); do
        reference=$(node_height 8545) || { sleep 1; continue; }
        current=$(node_height "$port") || { sleep 1; continue; }
        if ((current >= reference - 10)); then return 0; fi
        sleep 1
    done
    echo "honest peer at RPC $port did not catch up with consensus node" >&2
    return 1
}

archive_experiment_logs() {
    local source relative destination archive_dir="$OUT_ATTEMPT/logs"
    mkdir -p "$archive_dir/validator"
    cp -p .local/bootnode/bootnode.log "$archive_dir/bootnode.log"
    while IFS= read -r -d '' source; do
        cp -p "$source" "$archive_dir/validator/${source##*/}"
    done < <(find .local/node0 -maxdepth 1 -type f \( -name 'bsc.log*' -o -name 'bsc-node.log' -o -name 'init.log' \) -print0)
    while IFS= read -r -d '' source; do
        relative=${source#"$STATE_DIR"/}
        destination="$archive_dir/$relative"
        mkdir -p "$(dirname "$destination")"
        cp -p -- "$source" "$destination"
    done < <(find "$STATE_DIR" -type f \( -name 'console.log' -o -name 'init.log' -o -name 'bsc.log*' \) -print0)
    cp -p "$MANIFEST" "$archive_dir/peer_manifest.csv"
    "$PYTHON" - "$archive_dir" "$GROUP_ID" "$RATIO" "$ACTIVE_MALICIOUS" "$ACTIVE_HONEST" "$TRIAL" "$DURATION" "$MAX_PEERS" "$DIAL_RATIO" "$TD_OFFSET" "$CHAIN_ID" "$RIALTO_HASH" "$T0_EPOCH" "$DB_MALICIOUS" "$DB_HONEST_TOTAL" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
(directory, group, ratio, malicious, honest, trial, duration, max_peers,
 dial_ratio, td_offset, chain_id, genesis_hash, start_epoch,
 db_malicious, db_honest_total) = sys.argv[1:]
metadata = {
    "group_id": group,
    "ratio": ratio,
    "trial": int(trial),
    "duration_seconds": int(duration),
    "chain_reset_command": "./bsc_cluster.sh reset",
    "start_epoch_unix": float(start_epoch),
    "start_time_utc": datetime.fromtimestamp(float(start_epoch), timezone.utc).isoformat(),
    "chain_id": int(chain_id),
    "genesis_hash": genesis_hash,
    "victim_max_peers": int(max_peers),
    "victim_dial_ratio": int(dial_ratio),
    "malicious_td_offset": int(td_offset),
    "db_malicious": int(db_malicious),
    "db_honest_including_validator": int(db_honest_total),
    "active_malicious": int(malicious),
    "active_honest": int(honest),
    "total_candidate_peers": int(db_malicious) + int(db_honest_total) + int(malicious) + int(honest),
}
Path(directory, "run_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY
    local expected_nodes console_logs init_logs
    expected_nodes=$(awk 'END { print NR - 1 }' "$MANIFEST")
    console_logs=$(find "$archive_dir" -type f -name console.log | wc -l)
    init_logs=$(find "$archive_dir" -type f -name init.log ! -path "$archive_dir/validator/init.log" | wc -l)
    if ((console_logs != expected_nodes || init_logs != expected_nodes)); then
        echo "incomplete log archive: expected $expected_nodes console/init logs, got $console_logs/$init_logs" >&2
        return 1
    fi
    if [[ ! -s "$OUT_ATTEMPT/logs/chain_reset.log" || ! -s "$archive_dir/bootnode.log" \
        || ! -s "$archive_dir/validator/bsc-node.log" || ! -s "$archive_dir/validator/init.log" \
        || -z "$(find "$archive_dir/victim" -maxdepth 1 -type f -name 'bsc.log*' -print -quit)" \
        || -z "$(find "$archive_dir/normal-sync" -maxdepth 1 -type f -name 'bsc.log*' -print -quit)" ]]; then
        echo "required Bootnode, validator, victim, or normal-sync log is missing" >&2
        return 1
    fi
}

run_trial() {
    local index label p2p http dir entry port active_index=0
    local validator_id validator_enode node_info victim_key victim_pubkey victim_enode control_enode
    local victim_dir control_dir seeder_count expected_nodes console_logs init_logs
    local -a db_seed_urls=() db_peer_ports=() honest_ports=() active_all_ports=()
    local -a active_evil_dirs=() active_honest_dirs=()

    mkdir -p "$OUT_ATTEMPT/logs"
    stop_runtime_nodes
    if [[ -e "$STATE_DIR" ]]; then rm -rf -- "$STATE_DIR"; fi
    echo "[$EXPERIMENT_LABEL][$GROUP_ID][$TRIAL] resetting validator chain; victim MaxPeers=$MAX_PEERS"
    ./bsc_cluster.sh reset 2>&1 | tee "$OUT_ATTEMPT/logs/chain_reset.log"
    [[ -f .local/BSC_CLUSTER_SIZE && $(<.local/BSC_CLUSTER_SIZE) == 1 \
        && -f .local/node0/genesis.json && -f .local/node0/hardforkTime.txt ]]

    mkdir -p "$STATE_DIR"
    node0_config_backup="$STATE_DIR/node0-config.original"
    cp .local/node0/config.toml "$node0_config_backup"
    MANIFEST="$STATE_DIR/peer_manifest.csv"
    printf 'peer_id,label,cohort,role,enode,p2p_port,http_port\n' > "$MANIFEST"
    ./start_bootnode.sh
    BOOT_ENODE=$(<.local/bootnode/enode.txt)
    export BOOT_ENODE
    prepare_validator_discovery
    ./bsc_cluster.sh restart
    wait_rpc 8545 eth_blockNumber
    node_info=$(rpc 8545 admin_nodeInfo)
    read -r validator_id validator_enode < <("$PYTHON" -c 'import json,sys; n=json.load(sys.stdin)["result"]; print(n["id"].lower(),n["enode"])' <<< "$node_info")
    RIALTO_HASH=$(awk -F'hash=' '/Successfully wrote genesis state/{print $2}' .local/node0/init.log | awk '{print $1}')
    PASSED_FORK_TIME=$(awk '/passedHardforkTime/{print $2}' .local/node0/hardforkTime.txt)
    LAST_FORK_TIME=$((PASSED_FORK_TIME + LAST_FORK_MORE_DELAY))
    [[ -n "$RIALTO_HASH" && -n "$validator_id" && -n "$validator_enode" ]]
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$validator_id" db-honest-validator db honest "$validator_enode" 30303 8545 >> "$MANIFEST"

    victim_key="$STATE_DIR/victim/geth/nodekey"
    mkdir -p "$(dirname "$victim_key")"
    cp keys/victim-nodekey "$victim_key"
    victim_pubkey=$(./bin/bootnode -nodekey "$victim_key" -writeaddress)
    VICTIM_NODE_ID=$("$PYTHON" - "$victim_pubkey" <<'PY'
import sys
from Crypto.Hash import keccak
k = keccak.new(digest_bits=256)
k.update(bytes.fromhex(sys.argv[1]))
print(k.hexdigest())
PY
)
    victim_enode="enode://${victim_pubkey}@127.0.0.1:30401?discport=30401"

    db_seed_urls=("$validator_enode")
    for index in $(seq 0 $((DB_MALICIOUS - 1))); do
        label=$(printf 'db-malicious-%02d' "$index")
        p2p=$((31000 + index)); http=$((8800 + index)); dir="$STATE_DIR/db-peers/$label"
        prepare_peer "$label" db malicious "$dir" "$p2p" "$http" false "$validator_enode"
        db_seed_urls+=("$PREPARED_ENODE"); db_peer_ports+=("$http")
        start_peer "$PREPARED_DIR" "$p2p" "$http" true bootnode
    done
    if ((DB_HONEST_TOTAL > 1)); then
        for index in $(seq 1 $((DB_HONEST_TOTAL - 1))); do
            label=$(printf 'db-honest-%02d' "$index")
            p2p=$((31000 + DB_MALICIOUS + index - 1))
            http=$((8800 + DB_MALICIOUS + index - 1))
            dir="$STATE_DIR/db-peers/$label"
            prepare_peer "$label" db honest "$dir" "$p2p" "$http" false "$validator_enode"
            db_seed_urls+=("$PREPARED_ENODE"); db_peer_ports+=("$http"); honest_ports+=("$http")
            start_peer "$PREPARED_DIR" "$p2p" "$http" false bootnode
        done
    fi

    control_dir="$STATE_DIR/normal-sync"
    prepare_peer normal-sync-control control honest "$control_dir" 30601 8665 true "$validator_enode"
    control_enode=$PREPARED_ENODE
    start_peer "$PREPARED_DIR" 30601 8665 false nodiscover
    wait_rpc 8665 eth_blockNumber
    wait_for_normal_sync 8665

    for index in $(seq 1 "$ACTIVE_MALICIOUS"); do
        label=$(printf 'active-malicious-%02d' "$index")
        active_index=$((active_index + 1)); p2p=$((31100 + active_index - 1)); http=$((8900 + active_index - 1))
        dir="$STATE_DIR/active-peers/$label"
        prepare_peer "$label" active malicious "$dir" "$p2p" "$http" true "$victim_enode"
        active_evil_dirs+=("$PREPARED_DIR:$p2p:$http"); active_all_ports+=("$http")
    done
    for index in $(seq 1 "$ACTIVE_HONEST"); do
        label=$(printf 'active-honest-%02d' "$index")
        active_index=$((active_index + 1)); p2p=$((31100 + active_index - 1)); http=$((8900 + active_index - 1))
        dir="$STATE_DIR/active-peers/$label"
        prepare_peer "$label" active honest "$dir" "$p2p" "$http" true "$control_enode" "$victim_enode"
        active_honest_dirs+=("$PREPARED_DIR:$p2p:$http"); active_all_ports+=("$http"); honest_ports+=("$http")
    done
    for entry in "${active_evil_dirs[@]}"; do
        IFS=: read -r dir p2p http <<< "$entry"
        start_peer "$dir" "$p2p" "$http" true nodiscover
    done
    for entry in "${active_honest_dirs[@]}"; do
        IFS=: read -r dir p2p http <<< "$entry"
        start_peer "$dir" "$p2p" "$http" false nodiscover
    done

    for port in "${db_peer_ports[@]}" "${active_all_ports[@]}"; do wait_rpc "$port" eth_blockNumber 30; done
    for port in "${honest_ports[@]}"; do wait_for_normal_sync "$port"; done
    wait_for_normal_sync 8665

    victim_dir="$STATE_DIR/victim"
    mkdir -p "$victim_dir/geth"
    cp keys/password.txt "$victim_dir/password.txt"
    cp .local/node0/hardforkTime.txt "$victim_dir/hardforkTime.txt"
    write_node_config "$victim_dir" 30401 8645 false '[]' "$MAX_PEERS"
    ./bin/geth --datadir "$victim_dir" init --state.scheme hash --db.engine leveldb \
        .local/node0/genesis.json > "$victim_dir/init.log" 2>&1
    (
        cd "$BSC_DIR"
        go build -o "$STATE_DIR/seed-discovery-db" "$SCRIPT_DIR/seed_discovery_db.go"
    )
    "$STATE_DIR/seed-discovery-db" "$victim_dir/geth/nodes" "${db_seed_urls[@]}"
    seeder_count=$("$PYTHON" - "$MANIFEST" <<'PY'
import csv,sys
with open(sys.argv[1], newline="") as source:
    print(sum(1 for row in csv.DictReader(source) if row["cohort"] == "db"))
PY
)
    expected_seed_count=$((DB_MALICIOUS + DB_HONEST_TOTAL))
    [[ "$seeder_count" == "$expected_seed_count" ]]
    echo "[$EXPERIMENT_LABEL][$GROUP_ID][$TRIAL] topology ready: active $ACTIVE_MALICIOUS malicious + $ACTIVE_HONEST honest; local seeds $DB_MALICIOUS malicious + $DB_HONEST_TOTAL honest; total peers $total_candidates; victim MaxPeers=$MAX_PEERS"

    if ((DURATION <= 1)); then
        start_peer "$victim_dir" 30401 8645 false discovery "$MAX_PEERS"
        wait_rpc 8645 eth_blockNumber
        wait_for_victim_peers 5
        T0_EPOCH=$(date +%s.%N)
        EXPERIMENT_2_RUNTIME_DIR="$STATE_DIR" "$PYTHON" ./analyze_experiment_2.py collect \
            --start-epoch "$T0_EPOCH" --duration "$DURATION" --max-peers "$MAX_PEERS" \
            --active-malicious "$ACTIVE_MALICIOUS" --active-honest "$ACTIVE_HONEST" \
            --db-malicious "$DB_MALICIOUS" --db-honest-total "$DB_HONEST_TOTAL" \
            --group-id "$GROUP_ID" --ratio "$RATIO" --trial "$TRIAL" --runtime-dir "$STATE_DIR" --trial-dir "$OUT_ATTEMPT" &
        collector_pid=$!
    else
        T0_EPOCH=$(date +%s.%N)
        EXPERIMENT_2_RUNTIME_DIR="$STATE_DIR" "$PYTHON" ./analyze_experiment_2.py collect \
            --start-epoch "$T0_EPOCH" --duration "$DURATION" --max-peers "$MAX_PEERS" \
            --active-malicious "$ACTIVE_MALICIOUS" --active-honest "$ACTIVE_HONEST" \
            --db-malicious "$DB_MALICIOUS" --db-honest-total "$DB_HONEST_TOTAL" \
            --group-id "$GROUP_ID" --ratio "$RATIO" --trial "$TRIAL" --runtime-dir "$STATE_DIR" --trial-dir "$OUT_ATTEMPT" &
        collector_pid=$!
        start_peer "$victim_dir" 30401 8645 false discovery "$MAX_PEERS"
        wait_rpc 8645 eth_blockNumber
    fi
    wait "$collector_pid"
    collector_pid=
    stop_runtime_nodes
    archive_experiment_logs

    "$PYTHON" - "$OUT_ATTEMPT/trial_result.json" "$MAX_PEERS" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
result = json.loads(path.read_text())
result["victim_max_peers"] = int(sys.argv[2])
path.write_text(json.dumps(result, indent=2) + "\n")
PY

    expected_nodes=$(awk 'END { print NR - 1 }' "$MANIFEST")
    console_logs=$(find "$OUT_ATTEMPT/logs" -type f -name console.log | wc -l)
    init_logs=$(find "$OUT_ATTEMPT/logs" -type f -name init.log ! -path "$OUT_ATTEMPT/logs/validator/init.log" | wc -l)
    ((console_logs == expected_nodes && init_logs == expected_nodes))
    [[ -s "$OUT_ATTEMPT/trial_result.json" && -s "$OUT_ATTEMPT/final_peers.json" ]]
}

child_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "${collector_pid:-}" ]] && kill -0 "$collector_pid" 2>/dev/null; then
        kill "$collector_pid" 2>/dev/null || true
        wait "$collector_pid" 2>/dev/null || true
    fi
    stop_runtime_nodes
    if [[ -n "${node0_config_backup:-}" && -f "${node0_config_backup:-}" && -f .local/node0/config.toml ]]; then
        cp "$node0_config_backup" .local/node0/config.toml
    fi
    if [[ ! -L "$STATE_DIR" && -d "$STATE_DIR" ]]; then rm -rf -- "$STATE_DIR"; fi
    exit "$status"
}

if [[ "$CHILD_MODE" == true ]]; then
    for value in "$DB_MALICIOUS" "$DB_HONEST_TOTAL" "$ACTIVE_MALICIOUS" "$ACTIVE_HONEST" "$TRIAL" "$MAX_PEERS" "$DURATION"; do
        [[ "$value" =~ ^[0-9]+$ ]] || { echo "numeric trial argument expected, got: $value" >&2; exit 2; }
    done
    [[ "$GROUP_ID" =~ ^group_0[1-4]$ ]]
    [[ "$RATIO" == "maxpeers_${MAX_PEERS}" ]]
    total_candidates=$((DB_MALICIOUS + DB_HONEST_TOTAL + ACTIVE_MALICIOUS + ACTIVE_HONEST))
    [[ "$MAX_PEERS" == "$total_candidates" ]] || {
        echo "MaxPeers=$MAX_PEERS does not match candidate peer total $total_candidates" >&2
        exit 2
    }
    ((MAX_PEERS > 0 && DURATION > 0))
    collector_pid=
    node0_config_backup=
    trap child_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    run_trial
    exit 0
fi

selected_indices=()
selected_ids=()
for index in "${!GROUP_IDS[@]}"; do
    if [[ -z "$GROUP_FILTER" || "$GROUP_FILTER" == "${GROUP_IDS[$index]}" ]]; then
        selected_indices+=("$index")
        selected_ids+=("${GROUP_IDS[$index]}")
    fi
done
if ((${#selected_indices[@]} == 0)); then
    echo "unknown group: $GROUP_FILTER" >&2; usage >&2; exit 2
fi

mkdir -p "$OUT_DIR"
if [[ -L "$OUT_DIR" ]]; then echo "refusing symlink output directory: $OUT_DIR" >&2; exit 2; fi
if [[ -f "$OUT_DIR/experiment_metadata.json" ]]; then
    "$PYTHON" - "$OUT_DIR/experiment_metadata.json" "$DURATION" "$TRIALS" "${selected_ids[@]}" <<'PY'
import json, sys
from pathlib import Path
metadata = json.loads(Path(sys.argv[1]).read_text())
expected = {
    "group_01": (40, 40, 6, 7, 13, 14),
    "group_02": (50, 50, 6, 10, 17, 17),
    "group_03": (60, 60, 10, 10, 20, 20),
    "group_04": (70, 70, 10, 13, 23, 24),
}
ids = sys.argv[4:]
if metadata.get("duration_seconds") != int(sys.argv[2]) or metadata.get("planned_trials") != int(sys.argv[3]):
    raise SystemExit("existing Experiment 3 uses a different duration or trial count")
groups = metadata.get("groups", [])
if [group.get("group_id") for group in groups] != ids:
    raise SystemExit("existing Experiment 3 uses a different group selection")
for group in groups:
    values = (group["total_candidate_peers"], group["max_peers"], group["db_malicious"],
        group["db_honest_including_validator"], group["active_malicious"], group["active_honest"])
    if values != expected[group["group_id"]]:
        raise SystemExit(f"Experiment 3 topology mismatch in {group['group_id']}")
PY
else
    existing=$(find "$OUT_DIR" -mindepth 1 -maxdepth 1 ! -name .gitkeep -print -quit)
    if [[ -n "$existing" ]]; then
        echo "output exists without Experiment 3 metadata; move it before starting" >&2; exit 2
    fi
    "$PYTHON" - "$OUT_DIR/experiment_metadata.json" "$DURATION" "$TRIALS" "${selected_indices[@]}" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
groups = [
    {"group_id":"group_01", "total_candidate_peers":40, "max_peers":40, "db_malicious":6,
     "db_honest_including_validator":7, "active_malicious":13, "active_honest":14},
    {"group_id":"group_02", "total_candidate_peers":50, "max_peers":50, "db_malicious":6,
     "db_honest_including_validator":10, "active_malicious":17, "active_honest":17},
    {"group_id":"group_03", "total_candidate_peers":60, "max_peers":60, "db_malicious":10,
     "db_honest_including_validator":10, "active_malicious":20, "active_honest":20},
    {"group_id":"group_04", "total_candidate_peers":70, "max_peers":70, "db_malicious":10,
     "db_honest_including_validator":13, "active_malicious":23, "active_honest":24},
]
selected = [groups[int(index)] for index in sys.argv[4:]]
for group in selected:
    assert group["total_candidate_peers"] == sum(group[key] for key in (
        "db_malicious", "db_honest_including_validator", "active_malicious", "active_honest"))
metadata = {
    "experiment":"experiment_3", "created_at_utc":datetime.now(timezone.utc).isoformat(),
    "duration_seconds":int(sys.argv[2]), "planned_trials":int(sys.argv[3]),
    "victim_dial_ratio":3, "groups":selected,
}
Path(sys.argv[1]).write_text(json.dumps(metadata, indent=2) + "\n")
PY
fi

mkdir -p "$OUT_DIR/runs"
exec > >(tee -a "$OUT_DIR/runner.log") 2>&1
echo "[experiment-3] output=$OUT_DIR duration=${DURATION}s trials/group=$TRIALS groups=${#selected_indices[@]}"

parent_cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    if [[ -n "$CURRENT_ATTEMPT_DIR" && -d "$CURRENT_ATTEMPT_DIR" ]]; then
        find "$CURRENT_ATTEMPT_DIR" -depth -delete
    fi
    exit "$status"
}
trap parent_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for group_index in "${selected_indices[@]}"; do
    group_id=${GROUP_IDS[$group_index]}
    total=${TOTAL_PEERS[$group_index]}
    max_peers=${MAX_PEERS[$group_index]}
    db_malicious=${DB_MALICIOUS[$group_index]}
    db_honest=${DB_HONEST[$group_index]}
    active_malicious=${ACTIVE_MALICIOUS[$group_index]}
    active_honest=${ACTIVE_HONEST[$group_index]}
    ratio="maxpeers_${max_peers}"
    group_dir="$OUT_DIR/runs/$group_id"
    mkdir -p "$group_dir"
    for ((trial=1; trial<=TRIALS; trial++)); do
        printf -v trial_name 'trial_%02d' "$trial"
        trial_dir="$group_dir/$trial_name"
        if [[ -f "$trial_dir/trial_result.json" ]]; then
            echo "[experiment-3][$group_id][$trial_name] existing valid trial; skip"
            continue
        fi
        if [[ -e "$trial_dir" ]]; then
            echo "incomplete trial directory exists: $trial_dir" >&2
            exit 1
        fi
        valid=false
        for ((attempt=1; attempt<=RETRY_LIMIT; attempt++)); do
            CURRENT_ATTEMPT_DIR="$OUT_DIR/runs/.attempt_${group_id}_${trial_name}_${attempt}"
            if [[ -e "$CURRENT_ATTEMPT_DIR" ]]; then find "$CURRENT_ATTEMPT_DIR" -depth -delete; fi
            mkdir -p "$CURRENT_ATTEMPT_DIR"
            echo "[experiment-3][$group_id][$trial_name] environment attempt $attempt/$RETRY_LIMIT (MaxPeers=$max_peers)"
            "$SCRIPT_DIR/run_experiment_3.sh" __trial \
                "$group_id" "$ratio" "$db_malicious" "$db_honest" \
                "$active_malicious" "$active_honest" "$trial" "$max_peers" \
                "$DURATION" "$CURRENT_ATTEMPT_DIR" "$STATE_DIR" &
            CHILD_PID=$!
            if wait "$CHILD_PID"; then
                CHILD_PID=
                mv "$CURRENT_ATTEMPT_DIR" "$trial_dir"
                CURRENT_ATTEMPT_DIR=
                valid=true
                "$PYTHON" ./analyze_experiment_3.py --root "$OUT_DIR"
                break
            fi
            CHILD_PID=
            echo "[experiment-3][$group_id][$trial_name] invalid environment; deleting attempt" >&2
            find "$CURRENT_ATTEMPT_DIR" -depth -delete
            CURRENT_ATTEMPT_DIR=
        done
        if [[ "$valid" != true ]]; then
            echo "[experiment-3][$group_id][$trial_name] failed after $RETRY_LIMIT invalid attempts" >&2
            exit 1
        fi
    done
done

"$PYTHON" ./analyze_experiment_3.py --root "$OUT_DIR" --require-complete
echo "[experiment-3] complete: $OUT_DIR/success_rate.csv"
