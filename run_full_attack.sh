#!/bin/bash
# run_full_attack.sh - 完整的多节点攻击实验流程

set -e

export PATH=/usr/local/go/bin:/home/ubuntu/.foundry/bin:$PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================="
echo "多节点完全压制攻击实验 - 完整流程"
echo "========================================="
echo ""

# 步骤1: 启动 bootnode，后续所有节点都使用它进行发现
echo "[Step 1/7] Starting bootnode..."
if [ ! -d ".local/bootnode" ]; then
    ./start_bootnode.sh
    echo "✅ Bootnode started"
else
    echo "ℹ️  Bootnode directory exists, checking if running..."
    if [ -f ".local/bootnode/pid" ] && kill -0 $(cat .local/bootnode/pid) 2>/dev/null; then
        echo "✅ Bootnode already running"
    else
        ./start_bootnode.sh
        echo "✅ Bootnode restarted"
    fi
fi
echo ""

BOOT_ENODE=$(cat .local/bootnode/enode.txt)
export BOOT_ENODE

# 步骤2: 初始化或重启诚实验证节点集群
echo "[Step 2/7] Starting honest validator cluster through bootnode..."
if [ ! -d ".local/node0" ]; then
    BOOT_ENODE="$BOOT_ENODE" ./bsc_cluster.sh reset
    echo "✅ Honest cluster initialized"
else
    BOOT_ENODE="$BOOT_ENODE" ./bsc_cluster.sh restart
    echo "✅ Honest cluster restarted with bootnode discovery"
fi
echo ""

# 等待诚实节点启动并出块
echo "[Step 2.5/7] Waiting for honest nodes to produce blocks (30 seconds)..."
sleep 30
echo ""

# 步骤3: 初始化 victim 节点
echo "[Step 3/7] Setting up victim node..."
if [ ! -d ".local/victim" ]; then
    ./dl_experiment.sh setup
    echo "✅ Victim node initialized"
else
    echo "✅ Victim already exists, skipping..."
fi
echo ""

# 步骤4: 生成 20 个攻击节点
echo "[Step 4/7] Generating 20 attacker nodes..."
ATTACKER_COUNT=20
if [ ! -d ".local/attackers/attacker-0" ]; then
    ./setup_multi_attackers.sh $ATTACKER_COUNT
    echo "✅ $ATTACKER_COUNT attacker nodes generated"
else
    echo "✅ Attacker nodes already exist, skipping..."
fi
echo ""

# 步骤5: 启动所有攻击节点（仅通过 bootnode 发现）
echo "[Step 5/7] Starting $ATTACKER_COUNT attacker nodes (bootnode-only)..."
./start_multi_attackers.sh $ATTACKER_COUNT
echo "✅ Attacker nodes started through bootnode discovery"
echo ""

# 步骤6: 启动 victim (让它自然连接到恶意节点)
echo "[Step 6/7] Starting victim node..."
if [ -f ".local/victim/pid" ] && kill -0 $(cat .local/victim/pid) 2>/dev/null; then
    echo "ℹ️  Victim already running, skipping..."
else
    # 让 victim 只通过 bootnode 发现 peers，不使用静态节点。
    python3 - ".local/victim/config.toml" <<'PYEOF'
import re
from pathlib import Path

path = Path(".local/victim/config.toml")
content = path.read_text()
section = '''[Node.P2P]
MaxPeers = 20
NoDiscovery = false
ListenAddr = ":30401"
StaticNodes = []
TrustedNodes = []
BootstrapNodes = []
EnableMsgEvents = false
PeerFilterPatterns = []
'''
content = re.sub(r'\[Node\.P2P\].*\Z', section, content, flags=re.DOTALL)
path.write_text(content)
PYEOF

    python3 - ".local/victim/config.toml" "$BOOT_ENODE" <<'PYEOF'
import re, sys
path, bootnode = sys.argv[1:]
content = open(path).read()
content = re.sub(r'NoDiscovery\s*=\s*true', 'NoDiscovery = false', content)
content = re.sub(r'StaticNodes\s*=\s*\[[^\]]*\]', 'StaticNodes = []', content)
content = re.sub(r'BootstrapNodes\s*=\s*\[[^\]]*\]', f'BootstrapNodes = ["{bootnode}"]', content)
open(path, 'w').write(content)
PYEOF

    # 读取 hardfork 时间
    PassedForkTime=$(cat .local/node0/hardforkTime.txt | grep passedHardforkTime | awk -F" " '{print $NF}')
    LastHardforkTime=$((PassedForkTime + 10))

    BOOT_ENODE=$(cat .local/bootnode/enode.txt)

    nohup ./bin/geth \
        --datadir .local/victim \
        --config .local/victim/config.toml \
        --networkid 714 \
        --bootnodes "$BOOT_ENODE" \
        --maxpeers 20 \
        --discovery.v4 \
        --override.passedforktime ${PassedForkTime} \
        --override.lorentz ${PassedForkTime} \
        --override.maxwell ${PassedForkTime} \
        --override.fermi ${PassedForkTime} \
        --override.osaka ${PassedForkTime} \
        --override.mendel ${PassedForkTime} \
        --override.pasteur ${LastHardforkTime} \
        >> .local/victim/bsc-node.log 2>&1 &

    echo $! > .local/victim/pid
    echo "✅ Victim node started with hardfork overrides"
fi

echo ""

# 步骤7: 等待连接建立
echo "[Step 7/7] Waiting for connections to establish (10 seconds)..."
sleep 10
echo ""

# 显示攻击状态
echo "========================================="
echo "攻击已启动！"
echo "========================================="
echo ""
./monitor_multi_attack.sh status

echo ""
echo "========================================="
echo "监控命令:"
echo "========================================="
echo "实时监控:   ./monitor_multi_attack.sh watch"
echo "查看状态:   ./monitor_multi_attack.sh status"
echo "查看日志:   ./monitor_multi_attack.sh logs attacker-0"
echo "搜索事件:   ./monitor_multi_attack.sh grep sync_candidate"
echo ""
echo "Victim HTTP: http://127.0.0.1:8645"
echo "Victim logs: tail -f .local/victim/bsc-node.log"
echo ""
