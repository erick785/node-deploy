#!/bin/bash
# start_bootnode.sh - 启动 Bootnode 节点

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source .env

BOOTNODE_DIR=".local/bootnode"
BOOTNODE_PORT=30301
BOOTNODE_KEY="$BOOTNODE_DIR/bootnode.key"

# bootnode serves discovery over UDP; advertise the discovery port explicitly.
function bootnode_enode() {
    local pubkey
    pubkey=$(./bin/bootnode -nodekey "$BOOTNODE_KEY" -writeaddress)
    printf 'enode://%s@127.0.0.1:0?discport=%s\n' "$pubkey" "$BOOTNODE_PORT"
}

echo "[bootnode] Starting BSC bootnode..."

# 创建 bootnode 目录
mkdir -p "$BOOTNODE_DIR"

# 生成 bootnode key（如果不存在）
if [ ! -f "$BOOTNODE_KEY" ]; then
    echo "[bootnode] Generating bootnode key..."
    ./bin/bootnode -genkey "$BOOTNODE_KEY"
    echo "[bootnode] Key generated at $BOOTNODE_KEY"
fi

# 检查是否已经运行
if [ -f "$BOOTNODE_DIR/pid" ]; then
    old_pid=$(cat "$BOOTNODE_DIR/pid")
    if kill -0 "$old_pid" 2>/dev/null; then
        echo "[bootnode] Bootnode already running (PID: $old_pid)"

        # 显示 enode
        bootnode_url=$(bootnode_enode)
        printf '%s\n' "$bootnode_url" > "$BOOTNODE_DIR/enode.txt"
        echo "[bootnode] Enode: $bootnode_url"
        exit 0
    fi
fi

# 启动 bootnode
echo "[bootnode] Starting bootnode on port $BOOTNODE_PORT..."
nohup ./bin/bootnode \
    -nodekey "$BOOTNODE_KEY" \
    -addr "127.0.0.1:$BOOTNODE_PORT" \
    -verbosity 4 \
    > "$BOOTNODE_DIR/bootnode.log" 2>&1 &

BOOTNODE_PID=$!
echo $BOOTNODE_PID > "$BOOTNODE_DIR/pid"

# 等待启动
sleep 2

if ! kill -0 "$BOOTNODE_PID" 2>/dev/null; then
    echo "[bootnode] ERROR: Bootnode failed to start"
    tail -20 "$BOOTNODE_DIR/bootnode.log"
    exit 1
fi

# 生成 enode URL
bootnode_url=$(bootnode_enode)
printf '%s\n' "$bootnode_url" > "$BOOTNODE_DIR/enode.txt"

echo "[bootnode] ✅ Bootnode started successfully"
echo "[bootnode] PID: $BOOTNODE_PID"
echo "[bootnode] Enode: $bootnode_url"
echo "[bootnode] Log: $BOOTNODE_DIR/bootnode.log"
echo ""
echo "Export this for other scripts:"
echo "export BOOT_ENODE='$bootnode_url'"
