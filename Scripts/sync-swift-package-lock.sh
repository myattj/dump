#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_LOCK="$ROOT_DIR/Package.resolved"
WORKSPACE_LOCK="$ROOT_DIR/Dump.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
MODE="${1:---install}"

[[ -f "$SOURCE_LOCK" ]] || {
  echo "swift-package-lock: tracked Package.resolved is missing" >&2
  exit 1
}

case "$MODE" in
  --install)
    mkdir -p "$(dirname "$WORKSPACE_LOCK")"
    cp "$SOURCE_LOCK" "$WORKSPACE_LOCK"
    ;;
  --check)
    if [[ ! -f "$WORKSPACE_LOCK" ]] || ! cmp -s "$SOURCE_LOCK" "$WORKSPACE_LOCK"; then
      echo "swift-package-lock: Xcode package resolution differs from tracked Package.resolved" >&2
      echo "Resolve the intended dependencies, review them, then run this script with --update." >&2
      exit 1
    fi
    ;;
  --update)
    [[ -f "$WORKSPACE_LOCK" ]] || {
      echo "swift-package-lock: generated workspace Package.resolved is missing" >&2
      exit 1
    }
    cp "$WORKSPACE_LOCK" "$SOURCE_LOCK"
    ;;
  *)
    echo "Usage: $0 [--install|--check|--update]" >&2
    exit 2
    ;;
esac
