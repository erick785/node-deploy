#!/usr/bin/env bash
# Helpers for the multi-node Bootnode-only downloader experiment.

set -euo pipefail

basedir=$(cd "$(dirname "$0")" && pwd)
source "${basedir}/.env"

VICTIM_P2P=30401
VICTIM_HTTP=8645
VICTIM_WS=8646
VICTIM_DIR="${basedir}/.local/victim"
VICTIM_NODEKEY="${basedir}/keys/victim-nodekey"
ENODES_CACHE="${basedir}/.local/experiment-enodes.env"

geth_bin() { echo "${basedir}/bin/geth"; }

rpc() {
    local port=$1 method=$2 params=${3:-[]}
    curl -s -X POST "http://127.0.0.1:${port}" \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}"
}

get_node_info_from_nodekey() {
    local nodekey_file=$1 p2p_port=$2 http_port
    local tmp_dir pid info enode node_id
    http_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    tmp_dir=$(mktemp -d)
    "$(geth_bin)" --datadir "$tmp_dir" --nodekeyhex "$(cat "$nodekey_file")" \
        --port "$p2p_port" --http --http.port "$http_port" \
        --http.api eth,net,admin --nodiscover >"$tmp_dir/geth.log" 2>&1 &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$tmp_dir"' RETURN
    for _ in $(seq 1 15); do
        sleep 1
        info=$(rpc "$http_port" admin_nodeInfo 2>/dev/null || true)
        enode=$(echo "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("result",{}).get("enode",""))' 2>/dev/null || true)
        node_id=$(echo "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("result",{}).get("id",""))' 2>/dev/null || true)
        [ -n "$enode" ] && [ -n "$node_id" ] && break
    done
    echo "enode:${enode:-}"
    echo "id:${node_id:-}"
}

load_enodes() {
    [ -f "$ENODES_CACHE" ] || { echo "[dl-exp] ERROR: run './dl_experiment.sh setup' first" >&2; exit 1; }
    source "$ENODES_CACHE"
}

init_victim_dir() {
    load_enodes
    rm -rf "$VICTIM_DIR"
    mkdir -p "$VICTIM_DIR/geth"
    cp "$VICTIM_NODEKEY" "$VICTIM_DIR/geth/nodekey"
    cp "${basedir}/keys/password.txt" "$VICTIM_DIR/password.txt"
    cp "${basedir}/.local/node0/hardforkTime.txt" "$VICTIM_DIR/hardforkTime.txt"
    python3 - "${basedir}/config.toml" "$VICTIM_DIR/config.toml" "$VICTIM_P2P" "$VICTIM_HTTP" "$VICTIM_WS" <<'PY'
import re, sys
src, dst, p2p, http, ws = sys.argv[1:]
content = open(src).read()
content = re.sub(r'(HTTPPort\s*=\s*)\d+', rf'\g<1>{http}', content)
content = re.sub(r'(WSPort\s*=\s*)\d+', rf'\g<1>{ws}', content)
content = re.sub(r'(HTTPHost\s*=\s*)"[^"]*"', r'\g<1>"127.0.0.1"', content)
content = re.sub(r'(WSHost\s*=\s*)"[^"]*"', r'\g<1>"127.0.0.1"', content)
content = re.sub(r'\[Node\.P2P\].*?(?=\n\[|\Z)', '', content, flags=re.S).rstrip()
content += f'''\n\n[Node.P2P]\nMaxPeers = 50\nNoDiscovery = false\nListenAddr = ":{p2p}"\nStaticNodes = []\nTrustedNodes = []\nBootstrapNodes = []\nEnableMsgEvents = false\nPeerFilterPatterns = []\n'''
open(dst, 'w').write(content)
PY
    "$(geth_bin)" --datadir "$VICTIM_DIR" init --state.scheme hash --db.engine leveldb \
        "${basedir}/.local/node0/genesis.json" > "$VICTIM_DIR/init.log" 2>&1
    echo "[dl-exp] victim dir initialised at $VICTIM_DIR"
}

cmd_setup() {
    [ -f "$VICTIM_NODEKEY" ] || openssl rand -hex 32 > "$VICTIM_NODEKEY"
    local info victim_enode victim_node_id
    info=$(get_node_info_from_nodekey "$VICTIM_NODEKEY" "$VICTIM_P2P")
    victim_enode=$(echo "$info" | sed -n 's/^enode://p')
    victim_node_id=$(echo "$info" | sed -n 's/^id://p')
    [ -n "$victim_enode" ] && [ -n "$victim_node_id" ] || { echo "[dl-exp] ERROR: unable to compute victim identity" >&2; exit 1; }
    mkdir -p "$(dirname "$ENODES_CACHE")"
    printf 'VICTIM_ENODE="%s"\nVICTIM_NODE_ID="%s"\n' "$victim_enode" "$victim_node_id" > "$ENODES_CACHE"
    init_victim_dir
    echo "[dl-exp] victim node ID: $victim_node_id"
    echo "[dl-exp] Setup complete. Run './run_experiment_1.sh [attacker_count]'."
}

stop_victim() {
    local pid
    [ -f "$VICTIM_DIR/pid" ] || return 0
    pid=$(cat "$VICTIM_DIR/pid")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$VICTIM_DIR/pid"
}

cmd_status() {
    if [ ! -f "$VICTIM_DIR/pid" ] || ! kill -0 "$(cat "$VICTIM_DIR/pid")" 2>/dev/null; then
        echo "victim: NOT RUNNING"
        return 0
    fi
    local block peers syncing
    block=$(rpc "$VICTIM_HTTP" eth_blockNumber | python3 -c 'import sys,json; print(int(json.load(sys.stdin).get("result","0x0"),16))' 2>/dev/null || echo '?')
    peers=$(rpc "$VICTIM_HTTP" net_peerCount | python3 -c 'import sys,json; print(int(json.load(sys.stdin).get("result","0x0"),16))' 2>/dev/null || echo '?')
    syncing=$(rpc "$VICTIM_HTTP" eth_syncing | python3 -c 'import sys,json; r=json.load(sys.stdin).get("result"); print("no" if r is False else "yes")' 2>/dev/null || echo '?')
    echo "victim: pid=$(cat "$VICTIM_DIR/pid") block=$block peers=$peers syncing=$syncing"
}

case "${1:-help}" in
    setup) cmd_setup ;;
    stop) stop_victim ;;
    clean) stop_victim; rm -rf "$VICTIM_DIR" "$ENODES_CACHE" ;;
    status) cmd_status ;;
    logs) exec tail -f "$VICTIM_DIR/bsc-node.log" ;;
    *)
        cat <<'USAGE'
Usage: ./dl_experiment.sh {setup|stop|clean|status|logs}

This helper only prepares the victim. Start the full ten-period experiment with:
  ./run_experiment_1.sh [attacker_count]

attacker_count defaults to 50 and must be between 1 and 100.
USAGE
        ;;
esac
