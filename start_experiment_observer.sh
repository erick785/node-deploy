#!/usr/bin/env bash
# Prepare and start the normal-sync control or victim node for Experiment 1.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
source .env

ROLE=${1:?usage: start_experiment_observer.sh <normal-sync|victim> <start|stop>}
ACTION=${2:?usage: start_experiment_observer.sh <normal-sync|victim> <start|stop>}
BOOT_ENODE=${BOOT_ENODE:?BOOT_ENODE must contain the local bootnode enode}

case "$ROLE" in
    normal-sync)
        NODE_DIR=.local/normal-sync
        NODE_KEY=keys/normal-sync-nodekey
        P2P_PORT=30601
        HTTP_PORT=8665
        WS_PORT=8666
        ;;
    victim)
        NODE_DIR=.local/victim
        NODE_KEY=keys/victim-nodekey
        P2P_PORT=30401
        HTTP_PORT=8645
        WS_PORT=8646
        ;;
    *) echo "unknown role: $ROLE" >&2; exit 2 ;;
esac

stop_node() {
    local pid
    [ -f "$NODE_DIR/pid" ] || return 0
    pid=$(cat "$NODE_DIR/pid")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 15); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$NODE_DIR/pid"
}

prepare_node() {
    [ -x bin/geth ] || { echo "missing node-deploy/bin/geth" >&2; exit 1; }
    [ -f .local/node0/genesis.json ] || { echo "honest validator genesis is not initialized" >&2; exit 1; }
    [ -f "$NODE_KEY" ] || openssl rand -hex 32 > "$NODE_KEY"
    mkdir -p "$NODE_DIR/geth"
    cp "$NODE_KEY" "$NODE_DIR/geth/nodekey"
    cp keys/password.txt "$NODE_DIR/password.txt"

    python3 - config.toml "$NODE_DIR/config.toml" "$P2P_PORT" "$HTTP_PORT" "$WS_PORT" <<'PY'
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

    ./bin/geth --datadir "$NODE_DIR" init --state.scheme hash --db.engine leveldb \
        .local/node0/genesis.json > "$NODE_DIR/init.log" 2>&1
}

start_node() {
    local passed_fork last_fork rialto_hash
    if [ -f "$NODE_DIR/pid" ] && kill -0 "$(cat "$NODE_DIR/pid")" 2>/dev/null; then
        echo "$ROLE already running (pid $(cat "$NODE_DIR/pid"))"
        return 0
    fi
    passed_fork=$(awk '/passedHardforkTime/{print $2}' .local/node0/hardforkTime.txt)
    last_fork=$((passed_fork + LAST_FORK_MORE_DELAY))
    rialto_hash=$(awk -F'hash=' '/Successfully wrote genesis state/{print $2}' .local/node0/init.log | awk '{print $1}')
    nohup ./bin/geth \
        --config "$NODE_DIR/config.toml" --datadir "$NODE_DIR" --nodekey "$NODE_DIR/geth/nodekey" \
        --port "$P2P_PORT" --http --http.addr 127.0.0.1 --http.port "$HTTP_PORT" \
        --http.api eth,net,admin,debug --http.corsdomain '*' \
        --ws --ws.addr 127.0.0.1 --ws.port "$WS_PORT" --ws.api eth,net,admin \
        --networkid "$CHAIN_ID" --bootnodes "$BOOT_ENODE" --discovery.v4 --maxpeers 50 \
        --syncmode full --gcmode full --rialtohash "$rialto_hash" \
        --override.passedforktime "$passed_fork" --override.lorentz "$passed_fork" \
        --override.maxwell "$passed_fork" --override.fermi "$passed_fork" \
        --override.osaka "$passed_fork" --override.mendel "$passed_fork" \
        --override.pasteur "$last_fork" \
        >> "$NODE_DIR/bsc-node.log" 2>&1 &
    echo $! > "$NODE_DIR/pid"
    echo "started $ROLE (pid $(cat "$NODE_DIR/pid"), p2p=$P2P_PORT, http=$HTTP_PORT)"
}

case "$ACTION" in
    start)
        if [ "$ROLE" = normal-sync ]; then
            if [ ! -f "$NODE_DIR/geth/chaindata/CURRENT" ]; then
                prepare_node
            fi
        else
            [ -f "$NODE_DIR/config.toml" ] || ./dl_experiment.sh setup
        fi
        start_node
        ;;
    stop) stop_node ;;
    *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac
