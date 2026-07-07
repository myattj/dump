#!/usr/bin/env bash
set -euo pipefail

# Publishes a Sparkle appcast.xml that points at the notarized DMGs
# in $RELEASE_DIR. Uses Sparkle's generate_appcast, which signs each
# update with the EdDSA private key it finds in the user's keychain.
#
# Required env:
#   RELEASE_DIR     directory containing *.dmg releases (and the produced
#                   appcast.xml). Typically synced to GitHub Pages / S3.
#   APPCAST_URL     public URL where appcast.xml will be served from
#                   (so generate_appcast can write the right enclosures)
# Optional env:
#   GENERATE_APPCAST  path to Sparkle's generate_appcast tool. If unset,
#                     we look for it under Sparkle's SwiftPM checkout
#                     inside .build/, then fall back to PATH.
#   ED_KEY_PATH       path to a Sparkle EdDSA private key file. If unset,
#                     generate_appcast uses the system keychain entry
#                     created by `generate_keys`.

: "${RELEASE_DIR:?RELEASE_DIR must contain the .dmg files to publish}"
: "${APPCAST_URL:?APPCAST_URL must be the public URL of appcast.xml}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

find_generate_appcast() {
  if [[ -n "${GENERATE_APPCAST:-}" && -x "$GENERATE_APPCAST" ]]; then
    echo "$GENERATE_APPCAST"
    return
  fi
  local candidate
  candidate="$(find "$ROOT_DIR" -type f -name generate_appcast -perm +111 2>/dev/null | head -n1 || true)"
  if [[ -n "$candidate" ]]; then
    echo "$candidate"
    return
  fi
  if command -v generate_appcast >/dev/null 2>&1; then
    command -v generate_appcast
    return
  fi
  echo ""
}

log() { printf '\033[32m[appcast]\033[0m %s\n' "$*" >&2; }

TOOL="$(find_generate_appcast)"
if [[ -z "$TOOL" ]]; then
  cat >&2 <<EOF
release-appcast: cannot locate Sparkle's generate_appcast.
  - Run \`xcodebuild -resolvePackageDependencies\` so SwiftPM checks out Sparkle, OR
  - Install Sparkle release binaries from https://github.com/sparkle-project/Sparkle/releases and set GENERATE_APPCAST=/path/to/generate_appcast
EOF
  exit 1
fi

log "using $TOOL"

ARGS=("$RELEASE_DIR" --download-url-prefix "$(dirname "$APPCAST_URL")/")
if [[ -n "${ED_KEY_PATH:-}" ]]; then
  ARGS+=(--ed-key-file "$ED_KEY_PATH")
fi

log "generating appcast.xml against $RELEASE_DIR"
"$TOOL" "${ARGS[@]}"

if [[ ! -f "$RELEASE_DIR/appcast.xml" ]]; then
  echo "release-appcast: generate_appcast did not produce appcast.xml" >&2
  exit 1
fi

log "appcast at $RELEASE_DIR/appcast.xml"
log "next: upload \$RELEASE_DIR/* to your static host so $APPCAST_URL serves it"
