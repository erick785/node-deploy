#!/usr/bin/env python3
"""Collect RPC height samples and summarize Experiment 1 logs into CSV files."""

import csv
import glob
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get("EXPERIMENT_1_OUTPUT_DIR", ROOT / "data" / "experiment_1")).resolve()
NODE_DEPLOY = Path(__file__).resolve().parent
SAMPLE_INTERVAL = 5
TOTAL_SECONDS = 300
PERIOD_SECONDS = 30
RPCS = {
    "honest": 8545,
    "normal_sync": 8665,
    "victim": 8645,
}
EVENTS = {
    "sync_candidate": re.compile(r"sync_candidate"),
    "sync_start": re.compile(r"sync_start"),
    "sync_end": re.compile(r"sync_end"),
    "advertising_offset_td": re.compile(r"advertising offset TD"),
    "header_suppressed": re.compile(r"suppressing header response"),
    "timeout": re.compile(r"timeout|timed out|header delivery stalling|stalled", re.IGNORECASE),
    "peer_dropped": re.compile(r"useless peer|Dropping peer|Synchronisation failed, dropping peer", re.IGNORECASE),
    "synced_changed": re.compile(r"synced_changed"),
}
LOG_TIME = re.compile(r"(?P<monthday>\d{2}-\d{2})\|(?P<clock>\d{2}:\d{2}:\d{2}(?:\.\d+)?)")


def rpc(port, method, params=None):
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}).encode()
    request = Request(f"http://127.0.0.1:{port}", data=payload, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=3) as response:
        result = json.loads(response.read()).get("result")
    return result


def quantity(value):
    try:
        return int(value, 16) if isinstance(value, str) and value.startswith("0x") else ""
    except ValueError:
        return ""


def node_sample(role, port):
    sample = {f"{role}_height": ""}
    try:
        sample[f"{role}_height"] = quantity(rpc(port, "eth_blockNumber"))
    except (URLError, TimeoutError, ValueError, OSError, json.JSONDecodeError):
        pass
    return sample


def collect(start_epoch=None):
    OUT.mkdir(parents=True, exist_ok=True)
    samples_file = OUT / "samples.csv"
    fields = ["elapsed_seconds"]
    for role in RPCS:
        fields.append(f"{role}_height")
    started_wall = float(start_epoch) if start_epoch is not None else time.time()
    start = time.monotonic() - max(0, time.time() - started_wall)
    with samples_file.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        next_sample = start
        while True:
            elapsed = min(TOTAL_SECONDS, max(0, int(time.time() - started_wall)))
            row = {"elapsed_seconds": elapsed}
            for role, port in RPCS.items():
                row.update(node_sample(role, port))
            writer.writerow(row)
            output.flush()
            if elapsed >= TOTAL_SECONDS:
                break
            next_sample += SAMPLE_INTERVAL
            time.sleep(max(0, next_sample - time.monotonic()))
    return samples_file


def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def archived_logs():
    paths = {
        "honest": OUT / "logs/honest.log",
        "normal_sync": OUT / "logs/normal_sync.log",
        "victim": OUT / "logs/victim.log",
        "bootnode": OUT / "logs/bootnode.log",
    }
    for name in sorted(glob.glob(str(OUT / "logs/attackers/attacker-*.log"))):
        paths[Path(name).stem] = Path(name)
    return paths


def event_elapsed(line, started_epoch):
    match = LOG_TIME.search(line)
    if not match:
        return "", ""
    start_local = datetime.fromtimestamp(started_epoch).astimezone()
    value = f"{start_local.year}-{match.group('monthday')}|{match.group('clock')}"
    fmt = "%Y-%m-%d|%H:%M:%S.%f" if "." in value else "%Y-%m-%d|%H:%M:%S"
    try:
        parsed = datetime.strptime(value, fmt).astimezone()
    except ValueError:
        return "", ""
    candidates = [parsed.replace(year=parsed.year + offset) for offset in (-1, 0, 1)]
    event_time = min(candidates, key=lambda item: abs(item.timestamp() - started_epoch))
    elapsed = event_time.timestamp() - started_epoch
    if elapsed < -2 or elapsed > TOTAL_SECONDS:
        return "", event_time.astimezone(timezone.utc).isoformat()
    return max(0, round(elapsed)), event_time.astimezone(timezone.utc).isoformat()


def extract_events(started_epoch):
    output_path = OUT / "events.csv"
    with output_path.open("w", newline="") as output:
        writer = csv.writer(output)
        writer.writerow(["elapsed_seconds", "source", "event"])
        for source, path in archived_logs().items():
            if not path.exists():
                continue
            with path.open(errors="replace") as log_file:
                for line in log_file:
                    for event, pattern in EVENTS.items():
                        if pattern.search(line):
                            elapsed, _ = event_elapsed(line, started_epoch)
                            if elapsed == "":
                                continue
                            writer.writerow([elapsed, source, event])
    return output_path


def analyze():
    samples_path = OUT / "samples.csv"
    if not samples_path.exists():
        raise SystemExit(f"missing sample data: {samples_path}")
    with samples_path.open(newline="") as source:
        samples = list(csv.DictReader(source))
    if len(samples) < 60:
        raise SystemExit(f"incomplete experiment: expected about 61 five-second samples, found {len(samples)}")
    start_path = OUT / "run_start_epoch.txt"
    if not start_path.exists():
        raise SystemExit(f"missing run start marker: {start_path}")
    events_path = extract_events(float(start_path.read_text().strip()))
    fields = [
        "period", "start_seconds", "end_seconds",
        "honest_start_height", "honest_end_height",
        "normal_sync_start_height", "normal_sync_end_height",
        "victim_start_height", "victim_end_height",
    ]
    rows = []
    for period_idx in range(10):
        start = period_idx * PERIOD_SECONDS
        end = start + PERIOD_SECONDS
        segment = [row for row in samples if start <= (as_int(row.get("elapsed_seconds")) or 0) < end or (period_idx == 9 and as_int(row.get("elapsed_seconds")) == TOTAL_SECONDS)]
        if not segment:
            continue
        heights = {name: [as_int(row.get(f"{name}_height")) for row in segment] for name in ("honest", "normal_sync", "victim")}
        heights = {name: [value for value in vals if value is not None] for name, vals in heights.items()}
        def first(name): return heights[name][0] if heights[name] else ""
        def last(name): return heights[name][-1] if heights[name] else ""
        final_honest, final_normal, final_victim = last("honest"), last("normal_sync"), last("victim")
        rows.append({
            "period": f"P{period_idx+1:02d}", "start_seconds": start, "end_seconds": end,
            "honest_start_height": first("honest"), "honest_end_height": final_honest,
            "normal_sync_start_height": first("normal_sync"), "normal_sync_end_height": final_normal,
            "victim_start_height": first("victim"), "victim_end_height": final_victim,
        })
    with (OUT / "period_analysis.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    if len(rows) != 10:
        raise SystemExit(f"incomplete period analysis: expected 10 periods, generated {len(rows)}")
    print(f"Wrote {samples_path}")
    print(f"Wrote {events_path}")
    print(f"Wrote {OUT / 'period_analysis.csv'}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "run"
    if command == "collect":
        collect(sys.argv[2] if len(sys.argv) > 2 else None)
    elif command == "analyze":
        analyze()
    elif command == "run":
        collect(sys.argv[2] if len(sys.argv) > 2 else None)
        analyze()
    else:
        raise SystemExit("usage: analyze_experiment_1.py [collect|analyze|run]")
