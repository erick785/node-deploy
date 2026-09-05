#!/bin/bash
# start_multi_attackers.sh - 启动多个攻击节点（bootnode-only）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env

# 配置参数
ATTACKER_COUNT=${1:-20}  # 默认 20 个攻击节点

# 攻击参数（可通过环境变量覆盖）
TD_OFFSET=${DL_EXP_TD_OFFSET:-10000000}  # TD 偏移量（默认 1000万）
ATTACK_MODE=${DL_EXP_MODE:-silent-header}  # 攻击模式
VICTIM_NODE_ID_FILE=".local/victim/node-id.txt"
ENODES_CACHE=".local/experiment-enodes.env"

# 检查依赖
if [ -f "$VICTIM_NODE_ID_FILE" ]; then
    VICTIM_NODE_ID=$(cat "$VICTIM_NODE_ID_FILE")
elif [ -f "$ENODES_CACHE" ]; then
    # dl_experiment.sh setup stores the keccak256 peer ID in this cache.
    source "$ENODES_CACHE"
else
    echo "[start-attackers] ERROR: Victim node ID not found at $VICTIM_NODE_ID_FILE"
    echo "Please setup victim first with: ./dl_experiment.sh setup"
    exit 1
fi

if [ ! -f ".local/bootnode/enode.txt" ]; then
    echo "[start-attackers] ERROR: Bootnode not found"
    echo "Please start bootnode first with: ./start_bootnode.sh"
    exit 1
fi

BOOT_ENODE=$(cat .local/bootnode/enode.txt)

echo "[start-attackers] Starting $ATTACKER_COUNT attacker nodes..."
echo "[start-attackers] Target victim: $VICTIM_NODE_ID"
echo "[start-attackers] TD offset: $TD_OFFSET"
echo "[start-attackers] Attack mode: $ATTACK_MODE"
echo "[start-attackers] Bootnode: $BOOT_ENODE"
echo ""

# 启动所有攻击节点
for i in $(seq 0 $((ATTACKER_COUNT - 1))); do
    node_name="attacker-$i"
    node_dir=".local/attackers/$node_name"

    if [ ! -d "$node_dir" ]; then
        echo "[start-attackers] ERROR: $node_name not found. Run ./setup_multi_attackers.sh first"
        exit 1
    fi

    # 检查是否已运行
    if [ -f "$node_dir/pid" ]; then
        old_pid=$(cat "$node_dir/pid")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "[start-attackers] $node_name already running (PID: $old_pid), skipping..."
            continue
        fi
    fi

    # 启动攻击节点
    BSC_DOWNLOADER_EXPERIMENT_ENABLED=1 \
    BSC_DOWNLOADER_EXPERIMENT_LOCAL_ONLY_ACK=LOCAL_TEST_ONLY \
    BSC_DOWNLOADER_EXPERIMENT_NETWORK_ID="$CHAIN_ID" \
    BSC_DOWNLOADER_EXPERIMENT_VICTIM_IDS="$VICTIM_NODE_ID" \
    BSC_DOWNLOADER_EXPERIMENT_TD_OFFSET=$TD_OFFSET \
    BSC_DOWNLOADER_EXPERIMENT_MODE=$ATTACK_MODE \
    BSC_DOWNLOADER_EXPERIMENT_NODE_TIER="attacker" \
    nohup ./bin/geth \
        --datadir "$node_dir" \
        --config "$node_dir/config.toml" \
        --networkid $CHAIN_ID \
        --bootnodes "$BOOT_ENODE" \
        --maxpeers 50 \
        --discovery.v4 \
        >> "$node_dir/attacker.log" 2>&1 &

    echo $! > "$node_dir/pid"

    # 进度显示（每10个显示一次）
    if [ $((i % 10)) -eq 9 ]; then
        echo "[start-attackers] Started: $((i+1))/$ATTACKER_COUNT nodes"
    fi

    # 避免同时启动太多（降低系统压力）
    sleep 0.1
done

echo ""
echo "[start-attackers] All attacker nodes started, waiting 5 seconds for initialization..."
sleep 5

echo "[start-attackers] ✅ Bootnode-only startup completed"
echo "[start-attackers] No admin.addPeer calls were made; peers must be discovered through bootnode"
echo ""
echo "Monitor attack status with:"
echo "  ./monitor_multi_attack.sh status"
echo ""
echo "View attacker logs:"
echo "  tail -f .local/attackers/attacker-0/attacker.log"
