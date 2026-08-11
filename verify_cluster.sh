#!/usr/bin/env bash
set -euo pipefail

basedir=$(cd "$(dirname "$0")" && pwd)
source "${basedir}/.env"

samples=${1:-2}
interval=${2:-5}
size=$((BSC_CLUSTER_SIZE))
declare -a previous=()

rpc() {
    local port=$1
    local method=$2
    curl -sS --max-time 5 \
        -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":[]}" \
        "http://127.0.0.1:${port}"
}

hex_to_dec() {
    local value=$1
    if [[ "${value}" == 0x* ]]; then
        printf '%d' "$((value))"
    else
        printf '%s' "${value}"
    fi
}

for ((sample=1; sample<=samples; sample++)); do
    echo "== sample ${sample}/${samples} $(date '+%Y-%m-%d %H:%M:%S %z') =="
    printf '%-6s %-12s %-8s %-8s %-10s %-12s %-8s\n' node pid/status block peers chainId syncing advance

    for ((i=0; i<size; i++)); do
        port=$((8545+i*2))
        pid_file="${basedir}/.local/node${i}/pid"
        pid="-"
        alive="dead"
        if [[ -f "${pid_file}" ]]; then
            pid=$(cat "${pid_file}")
            if kill -0 "${pid}" 2>/dev/null; then
                alive="alive"
            fi
        fi

        block_hex=$(rpc "${port}" eth_blockNumber | jq -r '.result // "rpc-error"')
        peers_hex=$(rpc "${port}" net_peerCount | jq -r '.result // "rpc-error"')
        chain_id=$(rpc "${port}" eth_chainId | jq -r '.result // "rpc-error"')
        syncing=$(rpc "${port}" eth_syncing | jq -c '.result')
        block=$(hex_to_dec "${block_hex}")
        peers=$(hex_to_dec "${peers_hex}")

        advance="-"
        if [[ -n "${previous[$i]:-}" && "${block}" =~ ^[0-9]+$ ]]; then
            advance=$((block-previous[$i]))
        fi
        previous[$i]="${block}"

        printf '%-6s %-12s %-8s %-8s %-10s %-12s %-8s\n' \
            "node${i}" "${pid}/${alive}" "${block}" "${peers}" "${chain_id}" "${syncing}" "${advance}"
    done

    if (( sample < samples )); then
        sleep "${interval}"
    fi
done
