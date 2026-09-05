#!/bin/bash
# monitor_multi_attack.sh - 监控多节点攻击状态并自动重连

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env

VICTIM_HTTP="http://127.0.0.1:8645"
VICTIM_IPC=".local/victim/geth.ipc"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

cmd_status() {
    echo -e "${BLUE}[monitor] Checking multi-attacker experiment status...${NC}"
    echo ""

    # 1. 检查 victim peer 组成
    echo -e "${GREEN}=== Victim Peer Composition ===${NC}"

    if [ ! -S "$VICTIM_IPC" ]; then
        echo -e "${RED}ERROR: Victim not running${NC}"
        exit 1
    fi

    # 获取 peer 列表
    peers_json=$(echo 'admin.peers' | ./bin/geth attach "$VICTIM_IPC" 2>/dev/null)

    # 统计各类型 peer 数量（通过端口范围识别）
    attacker_count=$(echo "$peers_json" | grep -oE '"RemoteAddr":"127\.0\.0\.1:305[0-9]{2}"' | wc -l)
    honest_count=$(echo "$peers_json" | grep -oE '"RemoteAddr":"127\.0\.0\.1:303[0-9]{2}"' | wc -l)
    total_peers=$(echo "$peers_json" | grep -c '"RemoteAddr"')

    echo "Attacker nodes: $attacker_count"
    echo "Honest nodes: $honest_count"
    echo "Total peers: $total_peers / 20"
    echo ""

    # 2. 检查 victim 同步状态
    echo -e "${GREEN}=== Victim Sync Status ===${NC}"

    syncing=$(curl -s -X POST "$VICTIM_HTTP" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' 2>/dev/null)

    if [[ "$syncing" == *'"result":false'* ]]; then
        echo -e "${GREEN}Syncing: false (synced)${NC}"
    elif [[ "$syncing" == *'"result":true'* ]]; then
        echo -e "${YELLOW}Syncing: true (in progress)${NC}"
    else
        echo -e "${YELLOW}Syncing: $syncing${NC}"
    fi

    # 当前区块高度
    block_number=$(curl -s -X POST "$VICTIM_HTTP" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | \
        grep -oE '"result":"0x[0-9a-fA-F]+"' | cut -d'"' -f4)

    if [ -n "$block_number" ]; then
        block_decimal=$((16#${block_number#0x}))
        echo "Current block: $block_decimal ($block_number)"
    fi
    echo ""

    # 3. 检查攻击节点运行状态
    echo -e "${GREEN}=== Attacker Nodes Status ===${NC}"

    running_count=0
    stopped_count=0

    for node_dir in .local/attackers/attacker-*; do
        if [ -f "$node_dir/pid" ]; then
            pid=$(cat "$node_dir/pid")
            if kill -0 "$pid" 2>/dev/null; then
                ((running_count++))
            else
                ((stopped_count++))
            fi
        else
            ((stopped_count++))
        fi
    done

    total_attackers=$((running_count + stopped_count))
    echo "Running: $running_count"
    echo "Stopped: $stopped_count"
    echo "Total: $total_attackers"
    echo ""

    # 4. 最近的攻击事件
    echo -e "${GREEN}=== Recent Attack Events ===${NC}"
    echo "Victim log (last 5 sync events):"
    grep "DL-ATTACK-EXP" .local/victim/bsc-node.log 2>/dev/null | grep -E "sync_candidate|sync_start|sync_end" | tail -5 || echo "No events yet"
    echo ""
}

cmd_watch() {
    echo -e "${BLUE}[monitor] Starting continuous monitoring (Ctrl+C to stop)...${NC}"
    echo ""

    while true; do
        clear
        echo "=== Multi-Attacker Monitoring Dashboard ==="
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        cmd_status

        echo -e "${YELLOW}Refreshing in 5 seconds...${NC}"
        sleep 5
    done
}

cmd_logs() {
    node_name=${1:-"attacker-0"}
    log_file=".local/attackers/$node_name/attacker.log"

    if [ ! -f "$log_file" ]; then
        echo -e "${RED}ERROR: Log file not found: $log_file${NC}"
        exit 1
    fi

    echo -e "${BLUE}[monitor] Showing logs for $node_name${NC}"
    echo "File: $log_file"
    echo ""
    tail -f "$log_file"
}

cmd_grep() {
    pattern=${1:-"DL-ATTACK-EXP"}

    echo -e "${BLUE}[monitor] Searching for pattern: $pattern${NC}"
    echo ""

    echo "=== Victim logs ==="
    grep "$pattern" .local/victim/bsc-node.log 2>/dev/null | tail -20 || echo "No matches"
    echo ""

    echo "=== Attacker-0 logs ==="
    grep "$pattern" .local/attackers/attacker-0/attacker.log 2>/dev/null | tail -10 || echo "No matches"
}

# 主命令分发
case "$1" in
    status)
        cmd_status
        ;;
    watch)
        cmd_watch
        ;;
    logs)
        cmd_logs "$2"
        ;;
    grep)
        cmd_grep "$2"
        ;;
    *)
        echo "Usage: $0 {status|watch|logs [node]|grep [pattern]}"
        echo ""
        echo "Commands:"
        echo "  status     - Show current attack status (one-time)"
        echo "  watch      - Continuous monitoring (refresh every 5s)"
        echo "  logs       - Tail attacker logs (default: attacker-0)"
        echo "  grep       - Search logs for pattern (default: DL-ATTACK-EXP)"
        exit 1
        ;;
esac
