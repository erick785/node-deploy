#!/usr/bin/env python3
"""Collect and summarize repeated peer-composition attack experiments."""

import argparse
import csv
import json
import os
import time
from collections import Counter
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


DEPLOY = Path(__file__).resolve().parent
ROOT = DEPLOY.parent
RUNTIME = Path(os.environ.get("EXPERIMENT_2_RUNTIME_DIR", DEPLOY / ".local/experiment_2"))
RPCS = {"consensus_height": 8545, "normal_sync_height": 8665, "victim_height": 8645}


def rpc(port, method, timeout=2):
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": [], "id": 1}).encode()
    request = Request(f"http://127.0.0.1:{port}", data=payload, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=timeout) as response:
        result = json.loads(response.read())
    if "error" in result:
        raise RuntimeError(result["error"].get("message", "RPC error"))
    return result.get("result")


def node_height(port):
    value = rpc(port, "eth_blockNumber")
    if not isinstance(value, str) or not value.startswith("0x"):
        raise ValueError("eth_blockNumber returned an invalid quantity")
    return int(value, 16)


def read_manifest(path):
    peers = {}
    with Path(path).open(newline="") as source:
        for row in csv.DictReader(source):
            peers[row["peer_id"].lower().removeprefix("0x")] = row
    return peers


def peer_snapshot(manifest):
    peers = rpc(8645, "admin_peers")
    if not isinstance(peers, list):
        raise ValueError("admin_peers returned a non-list result")
    normalized = []
    for peer in peers:
        peer_id = str(peer.get("id", "")).lower().removeprefix("0x")
        if not peer_id:
            continue
        info = manifest.get(peer_id, {})
        network = peer.get("network") or {}
        normalized.append({
            "peer_id": peer_id,
            "peer_label": info.get("label", "unclassified"),
            "cohort": info.get("cohort", "unclassified"),
            "role": info.get("role", "unclassified"),
            "direction": "inbound" if network.get("inbound") else "outbound",
        })
    return normalized


def sample(args):
    trial_dir = Path(args.trial_dir).resolve()
    manifest = read_manifest(Path(args.runtime_dir) / "peer_manifest.csv")
    started_wall = float(args.start_epoch)
    started_mono = time.monotonic() - max(0, time.time() - started_wall)
    height_path = trial_dir / "height_samples.csv"
    peer_path = trial_dir / "peer_samples.jsonl"
    height_fields = ["elapsed_seconds", *RPCS]
    sample_count = 0
    last_elapsed = -1
    final_peers = None

    with height_path.open("w", newline="") as height_file, peer_path.open("w") as peer_file:
        height_writer = csv.DictWriter(height_file, fieldnames=height_fields)
        height_writer.writeheader()
        height_file.flush()
        next_tick = started_mono
        while True:
            elapsed = min(args.duration, max(0, int(time.time() - started_wall)))
            if elapsed <= last_elapsed and sample_count:
                next_tick += 0.05
                time.sleep(max(0, next_tick - time.monotonic()))
                continue
            heights = {"elapsed_seconds": elapsed}
            for name, port in RPCS.items():
                try:
                    heights[name] = node_height(port)
                except (URLError, TimeoutError, OSError, ValueError, RuntimeError, json.JSONDecodeError):
                    heights[name] = ""
            height_writer.writerow(heights)
            height_file.flush()

            try:
                peers = peer_snapshot(manifest)
                peer_record = {"elapsed_seconds": elapsed, "available": True, "peers": peers}
                if elapsed >= args.duration:
                    final_peers = peers
            except (URLError, TimeoutError, OSError, ValueError, RuntimeError, json.JSONDecodeError):
                peer_record = {"elapsed_seconds": elapsed, "available": False, "peers": None}
            peer_file.write(json.dumps(peer_record, separators=(",", ":")) + "\n")
            peer_file.flush()
            sample_count += 1
            last_elapsed = elapsed
            if elapsed >= args.duration:
                break
            next_tick = started_mono + sample_count
            time.sleep(max(0, next_tick - time.monotonic()))

    if final_peers is None:
        try:
            final_peers = peer_snapshot(manifest)
        except (URLError, TimeoutError, OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
            raise SystemExit(f"invalid environment: final peer snapshot unavailable: {error}")
    final_path = trial_dir / "final_peers.json"
    final_path.write_text(json.dumps({"captured_at_elapsed_seconds": args.duration, "peers": final_peers}, indent=2) + "\n")

    with height_path.open(newline="") as source:
        height_rows = list(csv.DictReader(source))
    peer_rows = [json.loads(line) for line in peer_path.read_text().splitlines()]
    min_rows = max(2, int(args.duration * 0.9))
    if sample_count < min_rows:
        raise SystemExit(f"invalid environment: only {sample_count}/{args.duration + 1} height samples")
    for field in ("consensus_height", "normal_sync_height"):
        available = [int(row[field]) for row in height_rows if row[field] != ""]
        if len(available) < int(sample_count * 0.9):
            raise SystemExit(f"invalid environment: {field} available for only {len(available)}/{sample_count} samples")
        if available[-1] <= available[0]:
            raise SystemExit(f"invalid environment: {field} did not advance")
        if height_rows[-1][field] == "":
            raise SystemExit(f"invalid environment: final {field} sample is unavailable")

    normal = [int(row["normal_sync_height"]) for row in height_rows if row["normal_sync_height"] != ""]
    consensus = [int(row["consensus_height"]) for row in height_rows if row["consensus_height"] != ""]
    if abs(normal[-1] - consensus[-1]) > 10:
        raise SystemExit("invalid environment: normal-sync control is more than 10 blocks behind consensus")

    victim = [int(row["victim_height"]) for row in height_rows if row["victim_height"] != ""]
    if len(victim) < int(sample_count * 0.8):
        raise SystemExit(f"invalid environment: victim height available for only {len(victim)}/{sample_count} samples")
    if height_rows[-1]["victim_height"] == "":
        raise SystemExit("invalid environment: final victim height sample is unavailable")
    available_peers = [row for row in peer_rows if row["available"]]
    if len(available_peers) < int(sample_count * 0.8):
        raise SystemExit(f"invalid environment: peer RPC available for only {len(available_peers)}/{sample_count} samples")
    if not peer_rows[-1]["available"]:
        raise SystemExit("invalid environment: final peer sample is unavailable")
    if not final_peers:
        raise SystemExit("invalid environment: victim has no connected peers at the end")
    if len(final_peers) > args.max_peers:
        raise SystemExit(f"invalid environment: final peer count {len(final_peers)} exceeds max_peers={args.max_peers}")

    heights = [int(row["victim_height"]) for row in height_rows if row["victim_height"] != ""]
    counts = Counter(peer["role"] for peer in final_peers)
    total_peers = len(final_peers)
    malicious = counts["malicious"]
    honest = counts["honest"]
    unclassified = total_peers - malicious - honest
    max_victim_height = max(heights)
    result = {
        "group_id": args.group_id,
        "ratio": args.ratio,
        "trial": args.trial,
        "duration_seconds": args.duration,
        "active_malicious": args.active_malicious,
        "active_honest": args.active_honest,
        "db_malicious": args.db_malicious,
        "db_honest_including_validator": args.db_honest_total,
        "total_candidate_peers": args.db_malicious + args.db_honest_total + args.active_malicious + args.active_honest,
        "victim_initial_height": heights[0],
        "victim_max_height": max_victim_height,
        "victim_final_height": heights[-1],
        "attack_success": max_victim_height == 0,
        "actual_total_peers": total_peers,
        "actual_malicious_peers": malicious,
        "actual_honest_peers": honest,
        "actual_unclassified_peers": unclassified,
        "malicious_share": round(malicious / total_peers, 6),
        "honest_share": round(honest / total_peers, 6),
        "consensus_start_height": consensus[0],
        "consensus_end_height": consensus[-1],
        "normal_sync_end_height": normal[-1],
        "height_sample_count": sample_count,
        "peer_available_sample_count": len(available_peers),
        "peer_manifest_count": len(manifest),
    }
    (trial_dir / "trial_result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, separators=(",", ":")))


def atomic_csv(path, fields, rows):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def summarize(args):
    root = Path(args.root).resolve()
    metadata_path = root / "experiment_metadata.json"
    if not metadata_path.is_file():
        raise SystemExit(f"experiment metadata missing: {metadata_path}")
    metadata = json.loads(metadata_path.read_text())
    groups = metadata["groups"]
    planned = int(metadata["planned_trials"])
    success_rows = []
    composition_rows = []
    incomplete = []
    for group in groups:
        group_dir = root / "runs" / group["group_id"]
        results = []
        for trial_dir in sorted(group_dir.glob("trial_*")):
            result_path = trial_dir / "trial_result.json"
            if result_path.is_file():
                result = json.loads(result_path.read_text())
                if result["group_id"] != group["group_id"]:
                    raise SystemExit(f"group mismatch in {result_path}")
                results.append(result)
        if len(results) > planned:
            raise SystemExit(f"too many valid trials for {group['group_id']}: {len(results)} > {planned}")
        results.sort(key=lambda row: int(row["trial"]))
        trial_numbers = [int(row["trial"]) for row in results]
        if len(trial_numbers) != len(set(trial_numbers)):
            raise SystemExit(f"duplicate valid trial number for {group['group_id']}")
        successes = 0
        valid = 0
        for row in results:
            valid += 1
            trial_success = bool(row["attack_success"])
            successes += int(trial_success)
            success_rows.append({
                "group_id": group["group_id"],
                "malicious_to_honest_ratio": group["ratio"],
                "trial": row["trial"],
                "active_malicious": group["active_malicious"],
                "active_honest": group["active_honest"],
                "active_total": group["active_malicious"] + group["active_honest"],
                "planned_trials": planned,
                "valid_trials": valid,
                "trial_attack_success": str(trial_success).lower(),
                "attack_successes": successes,
                "attack_failures": valid - successes,
                "success_rate": f"{successes / valid:.6f}",
            })
        if valid < planned:
            incomplete.append(f"{group['group_id']}={valid}/{planned}")
        for row in results:
            composition_rows.append({
                "group_id": row["group_id"],
                "malicious_to_honest_ratio": row["ratio"],
                "trial": row["trial"],
                "active_malicious": row["active_malicious"],
                "active_honest": row["active_honest"],
                "actual_total_peers": row["actual_total_peers"],
                "actual_malicious_peers": row["actual_malicious_peers"],
                "actual_honest_peers": row["actual_honest_peers"],
                "actual_unclassified_peers": row["actual_unclassified_peers"],
                "malicious_share": f"{row['malicious_share']:.6f}",
                "honest_share": f"{row['honest_share']:.6f}",
                "victim_initial_height": row["victim_initial_height"],
                "victim_max_height": row["victim_max_height"],
                "victim_final_height": row["victim_final_height"],
                "attack_success": str(bool(row["attack_success"])).lower(),
            })

    atomic_csv(root / "success_rate.csv", [
        "group_id", "malicious_to_honest_ratio", "trial", "active_malicious", "active_honest", "active_total",
        "planned_trials", "valid_trials", "trial_attack_success", "attack_successes", "attack_failures",
        "success_rate",
    ], success_rows)
    atomic_csv(root / "final_peer_composition.csv", [
        "group_id", "malicious_to_honest_ratio", "trial", "active_malicious", "active_honest",
        "actual_total_peers", "actual_malicious_peers", "actual_honest_peers", "actual_unclassified_peers",
        "malicious_share", "honest_share", "victim_initial_height", "victim_max_height", "victim_final_height",
        "attack_success",
    ], composition_rows)
    print(f"Updated {root / 'success_rate.csv'} and {root / 'final_peer_composition.csv'}")
    if args.require_complete and incomplete:
        raise SystemExit("experiment incomplete: " + ", ".join(incomplete))


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    collect = commands.add_parser("collect")
    collect.add_argument("--start-epoch", required=True, type=float)
    collect.add_argument("--duration", required=True, type=int)
    collect.add_argument("--max-peers", type=int, default=50)
    collect.add_argument("--active-malicious", required=True, type=int)
    collect.add_argument("--active-honest", required=True, type=int)
    collect.add_argument("--db-malicious", type=int, default=6)
    collect.add_argument("--db-honest-total", type=int, default=10)
    collect.add_argument("--group-id", required=True)
    collect.add_argument("--ratio", required=True)
    collect.add_argument("--trial", required=True, type=int)
    collect.add_argument("--runtime-dir", default=str(RUNTIME))
    collect.add_argument("--trial-dir", required=True)
    aggregate = commands.add_parser("summarize")
    aggregate.add_argument("--root", default=str(Path(os.environ.get("EXPERIMENT_2_OUTPUT_DIR", ROOT / "data/experiment_2"))))
    aggregate.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    if args.command == "collect":
        sample(args)
    else:
        summarize(args)


if __name__ == "__main__":
    main()
