#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="${DUMP_LOG_DIR:-$HOME/Library/Logs/Dump}"
APP_LOG="$LOG_DIR/dump.jsonl"
NETWORK_LOG="$LOG_DIR/network.jsonl"

mkdir -p "$LOG_DIR"
touch "$APP_LOG" "$NETWORK_LOG"

printf 'Tailing Dump logs:\n  %s\n  %s\n\n' "$APP_LOG" "$NETWORK_LOG"
tail -F "$APP_LOG" "$NETWORK_LOG"
