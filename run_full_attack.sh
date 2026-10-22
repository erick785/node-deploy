#!/usr/bin/env bash
# Backwards-compatible entry point for the single-run Experiment 1.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/run_experiment_1.sh" "$@"
