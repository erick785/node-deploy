#!/usr/bin/env bash
# Downloader experiment script for BSC node startup sync-failure research.
#
# Node layout:
#   node0-6  : honest validator nodes (managed by bsc_cluster.sh, P2P :30311-30317)
#   victim   : new/restart node being observed, P2P :30401, HTTP :8645
#   malicious: experiment node with spoofed TD + header silence, P2P :30501, HTTP :8745
#
# Commands:
#   setup    - generate keys, init datadirs, compute enodes (run once after bsc_cluster.sh reset)
#   phase0   - start victim only (honest peers, no attack – baseline)
#   phase1   - start victim + 1 malicious (single attack, malicious not static)
#   phase2   - start victim + 1 malicious as static peer (reconnect loop)
#   stop     - stop victim and malicious
#   clean    - delete victim and malicious datadirs
#   status   - show peer count, synced, chain head via RPC
#   logs     - tail victim and malicious logs

set -euo pipefail

basedir=$(cd "$(dirname "$0")"; pwd)
source "${basedir}/.env"

# ---------------------------------------------------------------------------
# Ports and directories
# ---------------------------------------------------------------------------
VICTIM_P2P=30401
VICTIM_HTTP=8645
VICTIM_WS=8646
VICTIM_METRICS=6160
VICTIM_PPROF=7160
VICTIM_DIR="${basedir}/.local/victim"
VICTIM_NODEKEY="${basedir}/keys/victim-nodekey"

MALICIOUS_P2P=30501
MALICIOUS_HTTP=8745
MALICIOUS_WS=8746
MALICIOUS_METRICS=6161
MALICIOUS_PPROF=7161
MALICIOUS_DIR="${basedir}/.local/malicious"
MALICIOUS_NODEKEY="${basedir}/keys/malicious-nodekey"

ENODES_CACHE="${basedir}/.local/experiment-enodes.env"

stateScheme="hash"
dbEngine="leveldb"
gcmode="full"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function sed_in_place() {
    if sed --version >/dev/null 2>&1; then
        sed -i -e "$1" "$2"
    else
        sed -i '' -e "$1" "$2"
    fi
}

function geth_bin() {
    # always use the freshly compiled binary with experiment hooks
    echo "${basedir}/bin/geth"
}

function rpc() {
    local port=$1; shift
    curl -s -X POST "http://127.0.0.1:${port}" \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":${2:-[]},\"id\":1}"
}

# get_node_info_from_nodekey: prints two lines — "enode:<url>" and "id:<hex>"
# The id is the 32-byte keccak256 node ID (as returned by peer.ID() /
# admin_nodeInfo.id), NOT the raw 64-byte public key in the enode URL.
function get_node_info_from_nodekey() {
    local nodekey_file=$1
    local p2p_port=$2
    local http_port=$((p2p_port + 200))
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -rf "$tmp_dir"' RETURN

    local geth; geth=$(geth_bin)
    local nkey; nkey=$(cat "$nodekey_file")
    "$geth" \
        --datadir "$tmp_dir" \
        --nodekeyhex "$nkey" \
        --port "$p2p_port" \
        --http --http.port "$http_port" \
        --http.api eth,net,admin \
        --nodiscover \
        2>"$tmp_dir/geth.log" &
    local pid=$!

    # Poll until HTTP is ready (up to 15s)
    local enode="" node_id=""
    for _ in $(seq 1 15); do
        sleep 1
        local info
        info=$(rpc "$http_port" admin_nodeInfo '[]' 2>/dev/null || true)
        enode=$(echo "$info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('enode',''))" 2>/dev/null || true)
        node_id=$(echo "$info" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('id',''))" 2>/dev/null || true)
        [ -n "$enode" ] && [ -n "$node_id" ] && break
    done
    echo "enode:${enode}"
    echo "id:${node_id}"
}

function get_honest_enodes() {
    local config_file="${basedir}/.local/node0/config.toml"
    python3 -c "
import re, sys
with open('${config_file}') as f:
    content = f.read()
m = re.search(r'StaticNodes\s*=\s*\[([^\]]*)\]', content, re.DOTALL)
if not m:
    sys.exit(0)
for e in re.findall(r'\"(enode://[^\"]+)\"', m.group(1)):
    print(e)
"
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
function cmd_setup() {
    echo "[dl-exp] Generating nodekeys if missing..."
    [ -f "$VICTIM_NODEKEY" ] || openssl rand -hex 32 > "$VICTIM_NODEKEY"
    [ -f "$MALICIOUS_NODEKEY" ] || openssl rand -hex 32 > "$MALICIOUS_NODEKEY"

    echo "[dl-exp] Computing enodes and node IDs (starts geth briefly)..."
    local victim_info malicious_info
    victim_info=$(get_node_info_from_nodekey "$VICTIM_NODEKEY" $VICTIM_P2P)
    malicious_info=$(get_node_info_from_nodekey "$MALICIOUS_NODEKEY" $MALICIOUS_P2P)

    local victim_enode victim_node_id malicious_enode malicious_node_id
    victim_enode=$(echo "$victim_info" | grep "^enode:" | sed 's/^enode://')
    victim_node_id=$(echo "$victim_info" | grep "^id:" | sed 's/^id://')
    malicious_enode=$(echo "$malicious_info" | grep "^enode:" | sed 's/^enode://')
    malicious_node_id=$(echo "$malicious_info" | grep "^id:" | sed 's/^id://')

    if [ -z "$victim_enode" ] || [ -z "$malicious_enode" ] || [ -z "$victim_node_id" ]; then
        echo "[dl-exp] ERROR: could not compute enodes/node IDs. Is geth binary available?" >&2
        exit 1
    fi

    cat > "$ENODES_CACHE" <<EOF
VICTIM_ENODE="${victim_enode}"
VICTIM_NODE_ID="${victim_node_id}"
MALICIOUS_ENODE="${malicious_enode}"
MALICIOUS_NODE_ID="${malicious_node_id}"
EOF
    echo "[dl-exp] victim    enode:   $victim_enode"
    echo "[dl-exp] victim    node ID: $victim_node_id  (keccak256, used as attack target)"
    echo "[dl-exp] malicious enode:   $malicious_enode"

    echo "[dl-exp] Initialising victim datadir..."
    _init_victim_dir

    echo "[dl-exp] Initialising malicious datadir..."
    _init_malicious_dir

    echo "[dl-exp] Setup complete. Run 'phase0' for baseline or 'phase1' for attack."
}

function _load_enodes() {
    if [ ! -f "$ENODES_CACHE" ]; then
        echo "[dl-exp] ERROR: run 'setup' first." >&2
        exit 1
    fi
    source "$ENODES_CACHE"
}

function _hardfork_times() {
    PassedForkTime=$(cat "${basedir}/.local/node0/hardforkTime.txt" | grep passedHardforkTime | awk -F" " '{print $NF}')
    LastHardforkTime=$(( PassedForkTime + LAST_FORK_MORE_DELAY ))
    rialtoHash=$(cat "${basedir}/.local/node0/init.log" | grep "Successfully wrote genesis state" | awk -F"hash=" '{print $NF}' | awk '{print $1}')
}

function _init_victim_dir() {
    _load_enodes
    local geth; geth=$(geth_bin)

    rm -rf "$VICTIM_DIR"
    mkdir -p "$VICTIM_DIR/geth"
    cp "$VICTIM_NODEKEY" "$VICTIM_DIR/geth/nodekey"
    cp "${basedir}/keys/password.txt" "$VICTIM_DIR/password.txt"
    cp "${basedir}/.local/node0/hardforkTime.txt" "$VICTIM_DIR/hardforkTime.txt"

    # Build static nodes: use node1-node6 (honest) as victim's peers
    # node0 is also honest but we skip it so victim has 6 honest peers
    local honest_enodes
    honest_enodes=$(get_honest_enodes)
    local static_list=""
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        static_list="${static_list}\"${e}\","
    done <<< "$honest_enodes"
    # trim trailing comma
    static_list="${static_list%,}"

    # Build config.toml with correct ports and P2P section
    python3 - "${basedir}/config.toml" "$VICTIM_DIR/config.toml" \
              "$VICTIM_P2P" "$VICTIM_HTTP" "$VICTIM_WS" "$static_list" <<'PYEOF'
import sys, re

src, dst, p2p_port, http_port, ws_port, static_list = sys.argv[1:7]
with open(src) as f:
    content = f.read()

# Override HTTP/WS ports in [Node] section
content = re.sub(r'(HTTPPort\s*=\s*)\d+', f'\\g<1>{http_port}', content)
content = re.sub(r'(WSPort\s*=\s*)\d+', f'\\g<1>{ws_port}', content)
content = re.sub(r'(HTTPHost\s*=\s*)"[^"]*"', r'\1"127.0.0.1"', content)
content = re.sub(r'(WSHost\s*=\s*)"[^"]*"', r'\1"127.0.0.1"', content)

# Replace [Node.P2P] section entirely
content = re.sub(r'\[Node\.P2P\].*?(?=\n\[|\Z)', '', content, flags=re.DOTALL).rstrip() + '\n'

p2p_section = f"""
# --- experiment overrides ---
[Node.P2P]
MaxPeers = 50
NoDiscovery = true
ListenAddr = ":{p2p_port}"
StaticNodes = [{static_list}]
TrustedNodes = []
BootstrapNodes = []
EnableMsgEvents = false
PeerFilterPatterns = []
"""
with open(dst, 'w') as f:
    f.write(content + p2p_section)
PYEOF

    # Init genesis
    "$geth" --datadir "$VICTIM_DIR" init \
        --state.scheme "$stateScheme" --db.engine "$dbEngine" \
        "${basedir}/.local/node0/genesis.json" \
        > "$VICTIM_DIR/init.log" 2>&1
    echo "[dl-exp] victim dir initialised at $VICTIM_DIR"
}

function _init_malicious_dir() {
    _load_enodes
    local geth; geth=$(geth_bin)

    rm -rf "$MALICIOUS_DIR"
    mkdir -p "$MALICIOUS_DIR/geth"
    cp "$MALICIOUS_NODEKEY" "$MALICIOUS_DIR/geth/nodekey"
    cp "${basedir}/keys/password.txt" "$MALICIOUS_DIR/password.txt"
    cp "${basedir}/.local/node0/hardforkTime.txt" "$MALICIOUS_DIR/hardforkTime.txt"

    python3 - "${basedir}/config.toml" "$MALICIOUS_DIR/config.toml" \
              "$MALICIOUS_P2P" "$MALICIOUS_HTTP" "$MALICIOUS_WS" "${VICTIM_ENODE}" <<'PYEOF'
import sys, re

src, dst, p2p_port, http_port, ws_port, victim_enode = sys.argv[1:7]
with open(src) as f:
    content = f.read()

content = re.sub(r'(HTTPPort\s*=\s*)\d+', f'\\g<1>{http_port}', content)
content = re.sub(r'(WSPort\s*=\s*)\d+', f'\\g<1>{ws_port}', content)
content = re.sub(r'(HTTPHost\s*=\s*)"[^"]*"', r'\1"127.0.0.1"', content)
content = re.sub(r'(WSHost\s*=\s*)"[^"]*"', r'\1"127.0.0.1"', content)
content = re.sub(r'\[Node\.P2P\].*?(?=\n\[|\Z)', '', content, flags=re.DOTALL).rstrip() + '\n'

p2p_section = f"""
# --- experiment overrides ---
[Node.P2P]
MaxPeers = 50
NoDiscovery = true
ListenAddr = ":{p2p_port}"
StaticNodes = ["{victim_enode}"]
TrustedNodes = []
BootstrapNodes = []
EnableMsgEvents = false
PeerFilterPatterns = []
"""
with open(dst, 'w') as f:
    f.write(content + p2p_section)
PYEOF

    "$geth" --datadir "$MALICIOUS_DIR" init \
        --state.scheme "$stateScheme" --db.engine "$dbEngine" \
        "${basedir}/.local/node0/genesis.json" \
        > "$MALICIOUS_DIR/init.log" 2>&1
    echo "[dl-exp] malicious dir initialised at $MALICIOUS_DIR"
}

# ---------------------------------------------------------------------------
# start victim
# ---------------------------------------------------------------------------
function _start_victim() {
    _load_enodes
    _hardfork_times
    local geth; geth=$(geth_bin)

    echo "[dl-exp] Starting victim (P2P :${VICTIM_P2P} HTTP :${VICTIM_HTTP})..."
    nohup "$geth" \
        --config "$VICTIM_DIR/config.toml" \
        --datadir "$VICTIM_DIR" \
        --nodekey "$VICTIM_DIR/geth/nodekey" \
        --port "$VICTIM_P2P" \
        --rpc.allow-unprotected-txs --allow-insecure-unlock \
        --ws --ws.addr 127.0.0.1 --ws.port "$VICTIM_WS" \
        --http --http.addr 127.0.0.1 --http.port "$VICTIM_HTTP" \
            --http.corsdomain "*" --http.api "eth,net,admin,debug" \
        --metrics --metrics.addr localhost --metrics.port "$VICTIM_METRICS" \
        --pprof --pprof.addr localhost --pprof.port "$VICTIM_PPROF" \
        --gcmode "$gcmode" --syncmode full \
        --rialtohash "$rialtoHash" \
        --override.passedforktime "$PassedForkTime" \
        --override.lorentz "$PassedForkTime" \
        --override.maxwell "$PassedForkTime" \
        --override.fermi "$PassedForkTime" \
        --override.osaka "$PassedForkTime" \
        --override.mendel "$PassedForkTime" \
        --override.pasteur "$LastHardforkTime" \
        --override.immutabilitythreshold "${FullImmutabilityThreshold}" \
        --override.breatheblockinterval "${BreatheBlockInterval}" \
        --override.minforblobrequest "${MinBlocksForBlobRequests}" \
        --override.defaultextrareserve "${DefaultExtraReserveForBlobRequests}" \
        --verbosity 4 \
        >> "$VICTIM_DIR/bsc-node.log" 2>&1 &
    echo $! > "$VICTIM_DIR/pid"
    echo "[dl-exp] victim started (pid=$(cat $VICTIM_DIR/pid))"
}

# ---------------------------------------------------------------------------
# start malicious
# ---------------------------------------------------------------------------
function _start_malicious() {
    local static_victim=${1:-false}   # true = add victim as static peer
    _load_enodes
    _hardfork_times
    local geth; geth=$(geth_bin)

    # Use the keccak256 node ID (64 hex chars) — this is what peer.ID() returns
    # during the ETH handshake. Do NOT use the raw pubkey from the enode URL
    # (128 hex chars) — that never matches and disables the experiment hooks.
    local victim_id="${VICTIM_NODE_ID}"

    local static_nodes_toml="[]"
    if [ "$static_victim" = "true" ]; then
        static_nodes_toml="[\"${VICTIM_ENODE}\"]"
    fi

    # Patch malicious config.toml static nodes (python3 to avoid duplicate section)
    python3 - "${basedir}/config.toml" "$MALICIOUS_DIR/config.toml" \
              "$MALICIOUS_P2P" "$MALICIOUS_HTTP" "$MALICIOUS_WS" "$static_nodes_toml" <<'PYEOF'
import sys, re

src, dst, p2p_port, http_port, ws_port, static_nodes = sys.argv[1:7]
with open(src) as f:
    content = f.read()

content = re.sub(r'(HTTPPort\s*=\s*)\d+', f'\\g<1>{http_port}', content)
content = re.sub(r'(WSPort\s*=\s*)\d+', f'\\g<1>{ws_port}', content)
content = re.sub(r'(HTTPHost\s*=\s*)"[^"]*"', r'\1"127.0.0.1"', content)
content = re.sub(r'(WSHost\s*=\s*)"[^"]*"', r'\1"127.0.0.1"', content)
content = re.sub(r'\[Node\.P2P\].*?(?=\n\[|\Z)', '', content, flags=re.DOTALL).rstrip() + '\n'

p2p_section = f"""
# --- experiment overrides ---
[Node.P2P]
MaxPeers = 50
NoDiscovery = true
ListenAddr = ":{p2p_port}"
StaticNodes = {static_nodes}
TrustedNodes = []
BootstrapNodes = []
EnableMsgEvents = false
PeerFilterPatterns = []
"""
with open(dst, 'w') as f:
    f.write(content + p2p_section)
PYEOF

    echo "[dl-exp] Starting malicious (P2P :${MALICIOUS_P2P} HTTP :${MALICIOUS_HTTP} static=${static_victim})..."
    BSC_DOWNLOADER_EXPERIMENT_ENABLED=true \
    BSC_DOWNLOADER_EXPERIMENT_LOCAL_ONLY_ACK=LOCAL_TEST_ONLY \
    BSC_DOWNLOADER_EXPERIMENT_NETWORK_ID="${CHAIN_ID}" \
    BSC_DOWNLOADER_EXPERIMENT_VICTIM_IDS="${victim_id}" \
    BSC_DOWNLOADER_EXPERIMENT_TD_OFFSET="${DL_EXP_TD_OFFSET:-1000000}" \
    BSC_DOWNLOADER_EXPERIMENT_MODE="${DL_EXP_MODE:-silent-header}" \
    BSC_DOWNLOADER_EXPERIMENT_AFTER_REQUESTS="${DL_EXP_AFTER_REQUESTS:-0}" \
    BSC_DOWNLOADER_EXPERIMENT_MAX_TRIGGERS="${DL_EXP_MAX_TRIGGERS:-0}" \
    nohup "$geth" \
        --config "$MALICIOUS_DIR/config.toml" \
        --datadir "$MALICIOUS_DIR" \
        --nodekey "$MALICIOUS_DIR/geth/nodekey" \
        --port "$MALICIOUS_P2P" \
        --rpc.allow-unprotected-txs --allow-insecure-unlock \
        --ws --ws.addr 127.0.0.1 --ws.port "$MALICIOUS_WS" \
        --http --http.addr 127.0.0.1 --http.port "$MALICIOUS_HTTP" \
            --http.corsdomain "*" --http.api "eth,net,admin,debug" \
        --metrics --metrics.addr localhost --metrics.port "$MALICIOUS_METRICS" \
        --pprof --pprof.addr localhost --pprof.port "$MALICIOUS_PPROF" \
        --gcmode "$gcmode" --syncmode full \
        --rialtohash "$rialtoHash" \
        --override.passedforktime "$PassedForkTime" \
        --override.lorentz "$PassedForkTime" \
        --override.maxwell "$PassedForkTime" \
        --override.fermi "$PassedForkTime" \
        --override.osaka "$PassedForkTime" \
        --override.mendel "$PassedForkTime" \
        --override.pasteur "$LastHardforkTime" \
        --override.immutabilitythreshold "${FullImmutabilityThreshold}" \
        --override.breatheblockinterval "${BreatheBlockInterval}" \
        --override.minforblobrequest "${MinBlocksForBlobRequests}" \
        --override.defaultextrareserve "${DefaultExtraReserveForBlobRequests}" \
        --verbosity 4 \
        >> "$MALICIOUS_DIR/bsc-node.log" 2>&1 &
    echo $! > "$MALICIOUS_DIR/pid"
    echo "[dl-exp] malicious started (pid=$(cat $MALICIOUS_DIR/pid))"
    echo "[dl-exp]   victim ID targeted: ${victim_id:0:16}..."
    echo "[dl-exp]   TD offset: ${DL_EXP_TD_OFFSET:-1000000}  mode: ${DL_EXP_MODE:-silent-header}"
}

# ---------------------------------------------------------------------------
# stop helpers
# ---------------------------------------------------------------------------
function _stop_node() {
    local pid_file=$1
    local label=$2
    [ -f "$pid_file" ] || return 0
    local pid; pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        echo "[dl-exp] stopped $label (pid=$pid)"
        # Wait for the process to actually exit (up to 10s) so ports are freed
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        # If still running, force-kill
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi
    fi
    rm -f "$pid_file"
}

function cmd_stop() {
    _stop_node "$VICTIM_DIR/pid" "victim"
    _stop_node "$MALICIOUS_DIR/pid" "malicious"
}

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
function cmd_clean() {
    cmd_stop || true
    rm -rf "$VICTIM_DIR" "$MALICIOUS_DIR"
    echo "[dl-exp] datadirs removed"
}

# ---------------------------------------------------------------------------
# reinit victim (for repeated scenario B / restart)
# ---------------------------------------------------------------------------
function cmd_reinit_victim() {
    _stop_node "$VICTIM_DIR/pid" "victim" || true
    sleep 2
    _init_victim_dir
    echo "[dl-exp] victim datadir reinitialised (scenario A: fresh new node)"
}

# ---------------------------------------------------------------------------
# phases
# ---------------------------------------------------------------------------

# Phase 0: baseline — victim + honest nodes only
function cmd_phase0() {
    echo "[dl-exp] === Phase 0: Baseline (no attack) ==="
    cmd_stop 2>/dev/null || true
    _init_victim_dir
    _start_victim
    echo "[dl-exp] Waiting 5s then check status..."
    sleep 5
    cmd_status
    echo "[dl-exp] Monitor: tail -f ${VICTIM_DIR}/bsc-node.log | grep -E 'DL-ATTACK-EXP|Synchronisation|sync'"
}

# _wait_p2p_ready: poll until the node's P2P port is open (max 20s)
function _wait_p2p_ready() {
    local port=$1
    local label=$2
    for _ in $(seq 1 20); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            echo "[dl-exp] $label P2P port $port is ready"
            return 0
        fi
        sleep 1
    done
    echo "[dl-exp] WARNING: $label P2P port $port not reachable after 20s" >&2
}

# Phase 1: single attack — one malicious cycle, no forced reconnect.
# Victim has malicious in its static list so they connect simultaneously on
# startup.  Malicious does NOT have victim in its static list, so after being
# kicked by the Downloader it will only reconnect via victim-initiated retry
# (much slower).  This lets us observe a single clean attack cycle:
#   connect → high-TD advertisement → sync_start → header suppression
#   → Downloader timeout → malicious dropped → victim selects honest peer
#   → sync succeeds → synced_changed old=false new=true
function cmd_phase1() {
    echo "[dl-exp] === Phase 1: Single attack (one malicious cycle) ==="
    cmd_stop 2>/dev/null || true
    _load_enodes

    # Build victim static list: honest nodes + malicious
    _init_victim_dir
    local static_list=""
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        static_list="${static_list}\"${e}\","
    done < <(get_honest_enodes)
    static_list="${static_list}\"${MALICIOUS_ENODE}\""

    python3 - "${VICTIM_DIR}/config.toml" <<PYEOF
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
new_nodes = [${static_list}]
formatted = ', '.join(f'"{e}"' for e in new_nodes)
content = re.sub(r'(StaticNodes\s*=\s*)\[[^\]]*\]',
                 lambda m: f'{m.group(1)}[{formatted}]', content)
with open(path, 'w') as f:
    f.write(content)
print(f"[dl-exp] Phase 1 victim static nodes: {len(new_nodes)} peers (incl. malicious)")
PYEOF

    # Malicious starts first so it is ready before victim dials it.
    # static_victim=false: malicious does NOT have victim in its own static
    # list, so it will not aggressively reconnect after being kicked.
    _start_malicious false
    _wait_p2p_ready "$MALICIOUS_P2P" "malicious"
    _start_victim
    echo "[dl-exp] Phase 1 running. Expecting: victim selects malicious (high TD) →"
    echo "[dl-exp]   header suppression → Downloader timeout → drop → honest sync."
    echo "[dl-exp] Key events: grep 'DL-ATTACK-EXP' ${VICTIM_DIR}/bsc.log"
    echo "[dl-exp]   grep 'advertising offset\\|suppressing header' ${MALICIOUS_DIR}/bsc.log"
}

# Phase 2: repeated attack — malicious as static peer (reconnects after being kicked)
function cmd_phase2() {
    echo "[dl-exp] === Phase 2: Repeated attack (malicious as static peer) ==="
    cmd_stop 2>/dev/null || true

    # Victim needs malicious as static peer
    _load_enodes
    _init_victim_dir

    # Patch victim static nodes to include malicious
    local static_list=""
    while IFS= read -r e; do
        [ -z "$e" ] && continue
        static_list="${static_list}\"${e}\","
    done < <(get_honest_enodes)
    static_list="${static_list}\"${MALICIOUS_ENODE}\""

    # Re-write the static nodes in victim config to include malicious
    python3 - "${VICTIM_DIR}/config.toml" <<PYEOF
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

new_nodes = [${static_list}]
formatted = ', '.join(f'"{e}"' for e in new_nodes)
content = re.sub(
    r'(StaticNodes\s*=\s*)\[[^\]]*\]',
    lambda m: f'{m.group(1)}[{formatted}]',
    content
)
with open(path, 'w') as f:
    f.write(content)
print(f"[dl-exp] Updated victim static nodes: {len(new_nodes)} peers")
PYEOF

    # Start malicious FIRST — it must be listening before victim starts so that
    # the initial ETH handshake from victim includes malicious's inflated TD.
    _start_malicious true
    _wait_p2p_ready "$MALICIOUS_P2P" "malicious"
    _start_victim
    echo "[dl-exp] Phase 2 running. Malicious is a static peer — expect reconnect after kick."
    echo "[dl-exp] Watch reconnect interval: grep -E 'DL-ATTACK-EXP|Dropping|useless' ${VICTIM_DIR}/bsc.log"
}

# Phase 4: recovery — stop malicious after N seconds, observe victim recovering
function cmd_phase4() {
    local wait_secs=${1:-120}
    echo "[dl-exp] === Phase 4: Recovery (stopping attack after ${wait_secs}s) ==="
    cmd_phase2
    echo "[dl-exp] Waiting ${wait_secs}s while attack runs..."
    sleep "$wait_secs"
    echo "[dl-exp] Stopping malicious node..."
    _stop_node "$MALICIOUS_DIR/pid" "malicious"
    echo "[dl-exp] Malicious stopped. Victim should now select an honest peer."
    echo "[dl-exp] Watch: grep 'DL-ATTACK-EXP\|synced_changed' ${VICTIM_DIR}/bsc-node.log"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
function cmd_status() {
    echo "=== Experiment node status ==="

    for label in victim malicious; do
        if [ "$label" = "victim" ]; then
            http_port=$VICTIM_HTTP
            dir=$VICTIM_DIR
        else
            http_port=$MALICIOUS_HTTP
            dir=$MALICIOUS_DIR
        fi

        pid_file="$dir/pid"
        if [ -f "$pid_file" ] && kill -0 "$(cat $pid_file)" 2>/dev/null; then
            pid=$(cat "$pid_file")
            block=$(rpc $http_port eth_blockNumber '[]' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d.get('result','0x0'),16))" 2>/dev/null || echo "?")
            peers=$(rpc $http_port net_peerCount '[]' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d.get('result','0x0'),16))" 2>/dev/null || echo "?")
            syncing=$(rpc $http_port eth_syncing '[]' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); r=d.get('result'); print('no' if r is False else r)" 2>/dev/null || echo "?")
            echo "  $label  pid=$pid  block=$block  peers=$peers  syncing=$syncing"
        else
            echo "  $label  NOT RUNNING"
        fi
    done

    echo ""
    echo "Honest nodes (node0-6):"
    for i in 0 1 2 3 4 5 6; do
        local http=$((8545 + i*2))
        local dir="${basedir}/.local/node${i}"
        if [ -f "$dir/pid" ] && kill -0 "$(cat $dir/pid)" 2>/dev/null; then
            block=$(rpc $http eth_blockNumber '[]' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d.get('result','0x0'),16))" 2>/dev/null || echo "?")
            echo "  node${i}  port=${http}  block=${block}"
        else
            echo "  node${i}  NOT RUNNING"
        fi
    done
}

# ---------------------------------------------------------------------------
# logs
# ---------------------------------------------------------------------------
function cmd_logs() {
    local node=${1:-victim}
    local dir
    if [ "$node" = "malicious" ]; then
        dir=$MALICIOUS_DIR
    else
        dir=$VICTIM_DIR
    fi
    exec tail -f "$dir/bsc-node.log"
}

function cmd_grep() {
    local pattern=${1:-"DL-ATTACK-EXP"}
    echo "=== victim ($pattern) ==="
    grep "$pattern" "$VICTIM_DIR/bsc-node.log" 2>/dev/null | tail -50 || true
    echo "=== malicious ($pattern) ==="
    grep "$pattern" "$MALICIOUS_DIR/bsc-node.log" 2>/dev/null | tail -50 || true
}

# ---------------------------------------------------------------------------
# add_honest_static: add 3 honest nodes to victim's static list (used in phase1
# where malicious is dynamic — ensures victim can still find honest peers)
# ---------------------------------------------------------------------------
function cmd_add_peer() {
    local target_port=${1:-$VICTIM_HTTP}
    local enode=${2:-}
    if [ -z "$enode" ]; then
        echo "Usage: add_peer [http_port] <enode_url>" >&2
        exit 1
    fi
    rpc "$target_port" admin_addPeer "[\"${enode}\"]"
}

# ---------------------------------------------------------------------------
# entrypoint
# ---------------------------------------------------------------------------
CMD=${1:-help}
shift || true

case "$CMD" in
setup)          cmd_setup ;;
phase0)         cmd_phase0 ;;
phase1)         cmd_phase1 ;;
phase2)         cmd_phase2 ;;
phase4)         cmd_phase4 "${1:-120}" ;;
stop)           cmd_stop ;;
clean)          cmd_clean ;;
reinit_victim)  cmd_reinit_victim ;;
status)         cmd_status ;;
logs)           cmd_logs "${1:-victim}" ;;
grep)           cmd_grep "${1:-DL-ATTACK-EXP}" ;;
add_peer)       cmd_add_peer "$@" ;;
*)
    cat <<'USAGE'
Usage: dl_experiment.sh <command> [args]

Experiment commands (run bsc_cluster.sh reset first):
  setup           Generate victim/malicious keys, init datadirs
  phase0          Baseline: victim + honest only (no attack)
  phase1          Attack: victim + honest + 1 malicious (dynamic peer)
  phase2          Attack: victim + honest + 1 malicious (static peer, reconnects)
  phase4 [secs]   Run phase2 then stop malicious after N seconds (default 120)
  stop            Stop victim and malicious nodes
  clean           Stop and delete victim/malicious datadirs
  reinit_victim   Reinit victim datadir (scenario A: fresh new node)
  status          Show block number, peers, syncing state
  logs [victim|malicious]   Tail node log
  grep [pattern]  grep DL-ATTACK-EXP events from both logs

Environment overrides (export before running):
  DL_EXP_TD_OFFSET       TD offset for malicious node (default: 1000000)
  DL_EXP_MODE            Attack mode: silent-header (default)
  DL_EXP_AFTER_REQUESTS  Normal requests before blocking (default: 0)
  DL_EXP_MAX_TRIGGERS    Max attack triggers (default: 0 = unlimited)
USAGE
    ;;
esac
