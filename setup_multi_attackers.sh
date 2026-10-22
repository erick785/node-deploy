#!/bin/bash
# setup_multi_attackers.sh - 批量生成恶意攻击节点

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env

# 配置参数
ATTACKER_COUNT=${1:-50}  # Experiment 1 default; maximum 100
ATTACKER_BASE_PORT=30500
ATTACKER_BASE_HTTP=8700

if ! [[ "$ATTACKER_COUNT" =~ ^[1-9][0-9]*$ ]] || [ "$ATTACKER_COUNT" -gt 100 ]; then
    echo "[setup-attackers] ERROR: attacker count must be between 1 and 100" >&2
    exit 1
fi

echo "[setup-attackers] Setting up $ATTACKER_COUNT attacker nodes..."

# Remove attacker directories outside the requested range so repeated runs
# with a smaller count do not leave stale nodes in the experiment.
for node_dir in .local/attackers/attacker-*; do
    [ -d "$node_dir" ] || continue
    node_index=${node_dir##*-}
    if [ "$node_index" -ge "$ATTACKER_COUNT" ]; then
        if [ -f "$node_dir/pid" ]; then
            old_pid=$(cat "$node_dir/pid")
            if kill -0 "$old_pid" 2>/dev/null; then
                kill "$old_pid" 2>/dev/null || true
                for _ in $(seq 1 10); do
                    kill -0 "$old_pid" 2>/dev/null || break
                    sleep 1
                done
                kill -9 "$old_pid" 2>/dev/null || true
            fi
        fi
        rm -rf "$node_dir"
    fi
done

# 检查 genesis.json
if [ ! -f "genesis/genesis.json" ]; then
    echo "[setup-attackers] ERROR: genesis/genesis.json not found"
    echo "Please run './bsc_cluster.sh reset' first to generate genesis"
    exit 1
fi

# 创建攻击节点目录
mkdir -p .local/attackers

for i in $(seq 0 $((ATTACKER_COUNT - 1))); do
    node_name="attacker-$i"
    node_dir=".local/attackers/$node_name"
    p2p_port=$((ATTACKER_BASE_PORT + i))
    http_port=$((ATTACKER_BASE_HTTP + i))

    echo "[setup-attackers] Setting up $node_name (P2P: $p2p_port, HTTP: $http_port)..."

    # 创建节点数据目录
    mkdir -p "$node_dir/geth"

    # 生成 nodekey
    if [ ! -f "$node_dir/geth/nodekey" ]; then
        openssl rand -hex 32 > "$node_dir/geth/nodekey"
    fi

    # 初始化创世块
    if [ ! -f "$node_dir/geth/chaindata/CURRENT" ]; then
        ./bin/geth --datadir "$node_dir" init genesis/genesis.json > /dev/null 2>&1
    fi

    # 创建配置文件
    cat > "$node_dir/config.toml" << CONFIG_EOF
[Eth]
NetworkId = $CHAIN_ID
SyncMode = "full"
NoPruning = false

[Eth.Miner]
GasFloor = 30000000
GasCeil = 40000000
GasPrice = 1000000000
Recommit = 3000000000

[Eth.TxPool]
NoLocals = true
Journal = "transactions.rlp"
Rejournal = 3600000000000
PriceLimit = 1000000000
PriceBump = 10
AccountSlots = 512
GlobalSlots = 10240
AccountQueue = 256
GlobalQueue = 5120

[Node]
IPCPath = "geth.ipc"
HTTPHost = "127.0.0.1"
HTTPPort = $http_port
HTTPVirtualHosts = ["*"]
HTTPModules = ["net", "web3", "eth", "admin", "personal"]

[Node.P2P]
MaxPeers = 50
NoDiscovery = false
ListenAddr = ":$p2p_port"
EnableMsgEvents = false

[Node.HTTPTimeouts]
ReadTimeout = 30000000000
WriteTimeout = 30000000000
IdleTimeout = 120000000000
CONFIG_EOF

    # 生成 enode
    node_id=$(./bin/bootnode -nodekey "$node_dir/geth/nodekey" -writeaddress)
    enode="enode://${node_id}@127.0.0.1:$p2p_port"
    echo "$enode" > "$node_dir/enode.txt"
    echo "$node_id" > "$node_dir/node-id.txt"

    # 进度显示
    if [ $((i % 10)) -eq 9 ]; then
        echo "[setup-attackers] Progress: $((i+1))/$ATTACKER_COUNT nodes created"
    fi
done

echo ""
echo "[setup-attackers] ✅ All $ATTACKER_COUNT attacker nodes created successfully"
echo "[setup-attackers] Directory: .local/attackers/"
echo "[setup-attackers] Port range: P2P $ATTACKER_BASE_PORT-$((ATTACKER_BASE_PORT + ATTACKER_COUNT - 1))"
echo "[setup-attackers] Port range: HTTP $ATTACKER_BASE_HTTP-$((ATTACKER_BASE_HTTP + ATTACKER_COUNT - 1))"
