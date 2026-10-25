#!/usr/bin/env python3
"""Summarize Experiment 3 valid trials as cumulative success-rate history."""

import argparse
import csv
import json
from pathlib import Path


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
    if metadata.get("experiment") != "experiment_3":
        raise SystemExit("metadata does not identify Experiment 3")
    planned = int(metadata["planned_trials"])
    rows = []
    incomplete = []

    for group in metadata["groups"]:
        group_id = group["group_id"]
        trial_results = []
        for trial_dir in sorted((root / "runs" / group_id).glob("trial_*")):
            result_path = trial_dir / "trial_result.json"
            if not result_path.is_file():
                continue
            result = json.loads(result_path.read_text())
            if result["group_id"] != group_id:
                raise SystemExit(f"group mismatch in {result_path}")
            expected = {
                "trial": int(trial_dir.name.removeprefix("trial_")),
                "ratio": f"maxpeers_{group['max_peers']}",
                "db_malicious": group["db_malicious"],
                "db_honest_including_validator": group["db_honest_including_validator"],
                "active_malicious": group["active_malicious"],
                "active_honest": group["active_honest"],
                "total_candidate_peers": group["total_candidate_peers"],
                "victim_max_peers": group["max_peers"],
            }
            if any(result.get(key) != value for key, value in expected.items()):
                raise SystemExit(f"trial configuration mismatch in {result_path}")
            trial_results.append(result)

        trial_results.sort(key=lambda item: int(item["trial"]))
        trial_numbers = [int(item["trial"]) for item in trial_results]
        if len(trial_results) > planned or len(trial_numbers) != len(set(trial_numbers)):
            raise SystemExit(f"invalid trial count or duplicate trials in {group_id}")

        successes = 0
        for valid_trials, result in enumerate(trial_results, 1):
            success = bool(result["attack_success"])
            successes += int(success)
            rows.append({
                "group_id": group_id,
                "total_candidate_peers": group["total_candidate_peers"],
                "max_peers": group["max_peers"],
                "trial": result["trial"],
                "planned_trials": planned,
                "trial_attack_success": str(success).lower(),
                "attack_successes": successes,
                "success_rate": f"{successes / valid_trials:.6f}",
                "actual_total_peers": result["actual_total_peers"],
                "actual_malicious_peers": result["actual_malicious_peers"],
                "actual_honest_peers": result["actual_honest_peers"],
                "victim_max_height": result["victim_max_height"],
            })

        if len(trial_results) != planned:
            incomplete.append(f"{group_id}={len(trial_results)}/{planned}")

    atomic_csv(root / "success_rate.csv", [
        "group_id", "total_candidate_peers", "max_peers", "trial", "planned_trials",
        "trial_attack_success", "attack_successes", "success_rate",
        "actual_total_peers", "actual_malicious_peers", "actual_honest_peers", "victim_max_height",
    ], rows)
    print(f"Updated {root / 'success_rate.csv'} with {len(rows)} valid trial rows")
    if args.require_complete and incomplete:
        raise SystemExit("experiment incomplete: " + ", ".join(incomplete))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="data/experiment_3")
    parser.add_argument("--require-complete", action="store_true")
    summarize(parser.parse_args())


if __name__ == "__main__":
    main()
