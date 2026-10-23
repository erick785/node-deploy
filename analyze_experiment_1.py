#!/usr/bin/env python3
"""Collect chart-ready Experiment 1 CSVs and derive peer attack sequences."""

import argparse
import csv
import json
import os
import re
import time
from collections import defaultdict, deque
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


DEPLOY = Path(__file__).resolve().parent
ROOT = DEPLOY.parent
RUNTIME = Path(os.environ.get("EXPERIMENT_1_RUNTIME_DIR", DEPLOY / ".local/experiment_1_v2"))
RPCS = {"consensus": 8545, "normal_sync": 8665, "victim": 8645}
LOG_TIME = re.compile(r"t=(?P<stamp>\d{2}-\d{2}\|\d{2}:\d{2}:\d{2}(?:\.\d+)?)")
SYNC_EVENT = re.compile(r'msg="\[DL-ATTACK-EXP\] (?P<event>sync_candidate|sync_start|sync_end)"')
KV = re.compile(r'(?P<key>[A-Za-z][A-Za-z0-9_]*)=(?P<value>"[^"]*"|[^\s]+)')


def rpc(port, method, params=None, timeout=2):
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}).encode()
    request = Request(f"http://127.0.0.1:{port}", data=payload, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=timeout) as response:
        result = json.loads(response.read())
    if "error" in result:
        raise RuntimeError(result["error"].get("message", "RPC error"))
    return result.get("result")


def node_height(port):
    value = rpc(port, "eth_blockNumber")
    return int(value, 16) if isinstance(value, str) and value.startswith("0x") else ""


def read_manifest(path):
    peers = {}
    with Path(path).open(newline="") as source:
        for row in csv.DictReader(source):
            peers[row["peer_id"].lower().removeprefix("0x")] = row
    return peers


def peer_snapshot(manifest):
    peers = rpc(RPCS["victim"], "admin_peers") or []
    normalized = {}
    for peer in peers:
        peer_id = str(peer.get("id", "")).lower().removeprefix("0x")
        if not peer_id:
            continue
        network = peer.get("network") or {}
        info = manifest.get(peer_id, {})
        normalized[peer_id] = {
            "label": info.get("label", "unclassified"),
            "cohort": info.get("cohort", "unclassified"),
            "role": info.get("role", "unclassified"),
            "direction": "inbound" if network.get("inbound") else "outbound",
        }
    return normalized


def collect(args):
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = read_manifest(Path(args.runtime_dir) / "peer_manifest.csv")
    started_wall = float(args.start_epoch)
    started_mono = time.monotonic() - max(0, time.time() - started_wall)
    height_path = out_dir / "sync_height.csv"
    counts_path = out_dir / "peer_counts.csv"
    height_fields = ["elapsed_seconds", "consensus_height", "normal_sync_height", "victim_height"]
    count_fields = [
        "elapsed_seconds", "total_peers", "inbound_peers", "outbound_peers",
        "honest_peers", "malicious_peers", "max_peers",
    ]
    sample_count = 0
    next_tick = started_mono

    with height_path.open("w", newline="") as height_file, counts_path.open("w", newline="") as count_file:
        height_writer = csv.DictWriter(height_file, fieldnames=height_fields)
        count_writer = csv.DictWriter(count_file, fieldnames=count_fields)
        height_writer.writeheader()
        count_writer.writeheader()
        while True:
            elapsed = min(args.duration, max(0, int(time.time() - started_wall)))
            heights = {"elapsed_seconds": elapsed}
            for role, port in RPCS.items():
                try:
                    heights[f"{role}_height"] = node_height(port)
                except (URLError, TimeoutError, OSError, ValueError, RuntimeError, json.JSONDecodeError):
                    heights[f"{role}_height"] = ""
            height_writer.writerow(heights)
            height_file.flush()

            try:
                current = peer_snapshot(manifest)
                available = True
            except (URLError, TimeoutError, OSError, ValueError, RuntimeError, json.JSONDecodeError):
                current = None
                available = False
            row = {field: "" for field in count_fields}
            row.update({"elapsed_seconds": elapsed, "max_peers": args.max_peers})
            if available:
                for field in count_fields:
                    if field not in ("elapsed_seconds", "max_peers"):
                        row[field] = 0
                counts = defaultdict(int)
                for peer in current.values():
                    if peer["role"] in ("honest", "malicious"):
                        counts[f"{peer['cohort']}_{peer['role']}_peers"] += 1
                        counts[f"{peer['role']}_peers"] += 1
                    else:
                        counts["unclassified_peers"] += 1
                    counts[f"{peer['direction']}_peers"] += 1
                for field in count_fields:
                    if field in counts:
                        row[field] = counts[field]
                row["total_peers"] = len(current)

            count_writer.writerow(row)
            count_file.flush()
            sample_count += 1

            if elapsed >= args.duration:
                break
            next_tick += 1
            time.sleep(max(0, next_tick - time.monotonic()))

    if sample_count < args.duration * 0.9:
        raise SystemExit(f"incomplete sampling: {sample_count} rows for {args.duration}s")
    with counts_path.open(newline="") as source:
        available_samples = sum(bool(row.get("total_peers")) for row in csv.DictReader(source))
    if available_samples < args.duration * 0.8:
        raise SystemExit(f"victim peer RPC available for only {available_samples}/{args.duration + 1} samples")
    print(f"Collected {sample_count} chart samples")


def event_elapsed(line, started_epoch, duration):
    match = LOG_TIME.search(line)
    if not match:
        return None
    local_start = datetime.fromtimestamp(started_epoch).astimezone()
    stamp = f"{local_start.year}-{match.group('stamp')}"
    fmt = "%Y-%m-%d|%H:%M:%S.%f" if "." in stamp else "%Y-%m-%d|%H:%M:%S"
    try:
        parsed = datetime.strptime(stamp, fmt).astimezone()
    except ValueError:
        return None
    candidates = [parsed.replace(year=parsed.year + offset) for offset in (-1, 0, 1)]
    seconds = min(candidates, key=lambda item: abs(item.timestamp() - started_epoch)).timestamp() - started_epoch
    if seconds < -2 or seconds > duration:
        return None
    return max(0.0, seconds)


def fields_from_log(line):
    return {item.group("key"): item.group("value").strip('"') for item in KV.finditer(line)}


def finalize(args):
    out_dir = Path(args.out_dir).resolve()
    manifest = read_manifest(Path(args.runtime_dir) / "peer_manifest.csv")
    events = []
    logs = sorted((Path(args.runtime_dir) / "victim").glob("bsc.log.*"))
    for log_path in logs:
        if log_path.is_symlink():
            continue
        with log_path.open(errors="replace") as source:
            for line in source:
                match = SYNC_EVENT.search(line)
                if not match:
                    continue
                elapsed = event_elapsed(line, float(args.start_epoch), args.duration)
                if elapsed is None:
                    continue
                values = fields_from_log(line)
                peer_id = values.get("peer", "").lower().removeprefix("0x")
                info = manifest.get(peer_id, {})
                events.append({
                    "elapsed_seconds": round(elapsed, 3),
                    "event": match.group("event"),
                    "peer_id": peer_id,
                    "peer_label": info.get("label", "unclassified"),
                    "cohort": info.get("cohort", "unclassified"),
                    "role": info.get("role", "unclassified"),
                    "td": values.get("td", ""),
                    "error": values.get("err", ""),
                })
    events.sort(key=lambda row: (row["elapsed_seconds"], row["event"]))
    starts = defaultdict(deque)
    attempts = []
    sequence = defaultdict(int)
    for event in events:
        peer_id = event["peer_id"]
        if event["event"] == "sync_start":
            sequence[peer_id] += 1
            attempt = {
                "peer_id": peer_id,
                "peer_label": event["peer_label"],
                "cohort": event["cohort"],
                "role": event["role"],
                "attempt": sequence[peer_id],
                "sync_start_seconds": event["elapsed_seconds"],
                "sync_end_seconds": "",
                "sync_outcome": "pending",
                "error": "",
                "td": event["td"],
            }
            attempts.append(attempt)
            starts[peer_id].append(attempt)
        elif event["event"] == "sync_end" and starts[peer_id]:
            attempt = starts[peer_id].popleft()
            attempt["sync_end_seconds"] = event["elapsed_seconds"]
            error = event["error"].strip()
            if not error or error.lower() in ("<nil>", "nil"):
                attempt["sync_outcome"] = "cycle_ended"
            elif "timeout" in error.lower():
                attempt["sync_outcome"] = "timeout"
                attempt["error"] = error
            else:
                attempt["sync_outcome"] = "failed"
                attempt["error"] = error

    attempts.sort(key=lambda attempt: float(attempt["sync_start_seconds"]))
    for switch_order, attempt in enumerate(attempts, 1):
        attempt["switch_order"] = switch_order

    fields = [
        "switch_order", "peer_id", "peer_label", "cohort", "role", "attempt",
        "sync_start_seconds", "sync_end_seconds", "sync_outcome", "td", "error",
    ]
    with (out_dir / "sync_attempts.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(attempts)
    if not (out_dir / "sync_height.csv").is_file() or not (out_dir / "peer_counts.csv").is_file():
        raise SystemExit("sampling CSVs are missing")
    print(f"Wrote {len(attempts)} sync attempts to {out_dir / 'sync_attempts.csv'}")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    collect_parser = subparsers.add_parser("collect")
    collect_parser.add_argument("--start-epoch", required=True, type=float)
    collect_parser.add_argument("--duration", required=True, type=int)
    collect_parser.add_argument("--max-peers", type=int, default=50)
    collect_parser.add_argument("--runtime-dir", default=str(RUNTIME))
    collect_parser.add_argument("--out-dir", default=str(Path(os.environ.get("EXPERIMENT_1_OUTPUT_DIR", ROOT / "data/experiment_1"))))
    finalize_parser = subparsers.add_parser("finalize")
    finalize_parser.add_argument("--start-epoch", required=True, type=float)
    finalize_parser.add_argument("--duration", required=True, type=int)
    finalize_parser.add_argument("--runtime-dir", default=str(RUNTIME))
    finalize_parser.add_argument("--out-dir", default=str(Path(os.environ.get("EXPERIMENT_1_OUTPUT_DIR", ROOT / "data/experiment_1"))))
    args = parser.parse_args()
    if args.command == "collect":
        collect(args)
    else:
        finalize(args)


if __name__ == "__main__":
    main()
