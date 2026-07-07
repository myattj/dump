#!/usr/bin/env bash
set -euo pipefail

# Codesigns the bundled runtime (Node + every .node native module) and then
# the Dump.app outer bundle with hardened runtime + the entitlements file.
#
# Required env:
#   DEVELOPER_ID         e.g. "Developer ID Application: Josh Myatt (TEAMID)"
#   APP_PATH             absolute path to Dump.app
# Optional env:
#   ENTITLEMENTS         defaults to Resources/Dump.entitlements
#   KEYCHAIN_PROFILE     if your signing identity lives in a custom keychain

: "${DEVELOPER_ID:?DEVELOPER_ID must be set (e.g. 'Developer ID Application: Josh Myatt (TEAMID)')}"
: "${APP_PATH:?APP_PATH must point to the built Dump.app}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/Resources/Dump.entitlements}"
RUNTIME_INSIDE_APP="$APP_PATH/Contents/Resources/runtime"

if [[ ! -d "$APP_PATH" ]]; then
  echo "sign.sh: $APP_PATH not found" >&2
  exit 1
fi
if [[ ! -d "$RUNTIME_INSIDE_APP" ]]; then
  echo "sign.sh: bundled runtime missing at $RUNTIME_INSIDE_APP — did xcodebuild copy Runtime/?" >&2
  exit 1
fi

log() { printf '\033[35m[sign]\033[0m %s\n' "$*" >&2; }

codesign_one() {
  local file="$1"
  codesign --force \
           --sign "$DEVELOPER_ID" \
           --options runtime \
           --timestamp \
           "$file"
}

# Inside-out signing: every Mach-O binary in the runtime first, then the app.
log "signing every .node native module"
while IFS= read -r -d '' nodemod; do
  codesign_one "$nodemod"
done < <(find "$RUNTIME_INSIDE_APP" -type f -name "*.node" -print0)

log "signing every .dylib in the runtime"
while IFS= read -r -d '' dylib; do
  codesign_one "$dylib"
done < <(find "$RUNTIME_INSIDE_APP" -type f -name "*.dylib" -print0)

log "signing the bundled node binary"
codesign_one "$RUNTIME_INSIDE_APP/node/bin/node"

# Catch any other Mach-O slices we missed (e.g. helper executables in npm
# native module postinstall outputs).
log "sweeping for any remaining unsigned Mach-O binaries"
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q "Mach-O" && ! codesign -v "$candidate" >/dev/null 2>&1; then
    log "signing leftover $candidate"
    codesign_one "$candidate"
  fi
done < <(find "$RUNTIME_INSIDE_APP" -type f -print0)

log "signing Dump.app with entitlements"
codesign --force \
         --deep \
         --sign "$DEVELOPER_ID" \
         --options runtime \
         --timestamp \
         --entitlements "$ENTITLEMENTS" \
         "$APP_PATH"

log "verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH" || {
  log "spctl assess failed — expected before notarization; will pass once stapled"
}

log "done"
