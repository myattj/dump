#!/usr/bin/env bash
set -euo pipefail

# Packages a signed Dump.app into a DMG, submits it to Apple's notary
# service via notarytool, then staples the resulting ticket.
#
# Required env:
#   APP_PATH         absolute path to a fully-signed Dump.app
#   NOTARY_PROFILE   keychain profile created via:
#                      xcrun notarytool store-credentials NOTARY_PROFILE \
#                        --apple-id you@example.com \
#                        --team-id TEAMID \
#                        --password app-specific-password
#   DEVELOPER_ID     same signing identity used by sign.sh (used for the DMG)
# Optional env:
#   DMG_NAME         output dmg base name (default: Dump)
#   OUTPUT_DIR       defaults to build/
#   NOTARY_KEYCHAIN  explicit keychain path containing NOTARY_PROFILE
#   KEYCHAIN_PROFILE path to a custom keychain containing DEVELOPER_ID

: "${APP_PATH:?APP_PATH must point to the signed Dump.app}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE must be a keychain profile created by notarytool store-credentials}"
: "${DEVELOPER_ID:?DEVELOPER_ID must be set (Developer ID Application: ...)}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_NAME="${DMG_NAME:-Dump}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"

NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  [[ -f "$NOTARY_KEYCHAIN" ]] || {
    echo "notarize: keychain not found at $NOTARY_KEYCHAIN" >&2
    exit 1
  }
  NOTARY_AUTH_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi

DMG_CODESIGN_ARGS=(--force --sign "$DEVELOPER_ID")
if [[ -n "$KEYCHAIN_PROFILE" ]]; then
  [[ -f "$KEYCHAIN_PROFILE" ]] || {
    echo "notarize: signing keychain not found at $KEYCHAIN_PROFILE" >&2
    exit 1
  }
  DMG_CODESIGN_ARGS+=(--keychain "$KEYCHAIN_PROFILE")
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$OUTPUT_DIR/${DMG_NAME}-${VERSION}.dmg"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"

log() { printf '\033[33m[notarize]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[notarize]\033[0m %s\n' "$*" >&2
  exit 1
}

log "staging app for DMG"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

if [[ -f "$DMG_PATH" ]]; then
  log "removing stale $DMG_PATH"
  rm "$DMG_PATH"
fi

log "building $DMG_PATH"
hdiutil create \
        -volname "Dump $VERSION" \
        -srcfolder "$STAGE_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"

log "signing DMG"
codesign "${DMG_CODESIGN_ARGS[@]}" \
         --timestamp \
         "$DMG_PATH"

SUBMIT_JSON="$(mktemp)"
LOG_JSON="$(mktemp)"
trap 'rm -rf "$STAGE_DIR" "$SUBMIT_JSON" "$LOG_JSON"' EXIT

log "submitting to Apple (this typically takes 1–5 minutes)"
xcrun notarytool submit "$DMG_PATH" \
                  "${NOTARY_AUTH_ARGS[@]}" \
                  --wait \
                  --output-format json | tee "$SUBMIT_JSON"

SUBMISSION_ID="$(/usr/bin/plutil -extract id raw "$SUBMIT_JSON" 2>/dev/null || true)"
STATUS="$(/usr/bin/plutil -extract status raw "$SUBMIT_JSON" 2>/dev/null || true)"

if [[ "$STATUS" != "Accepted" ]]; then
  log "notarization status: ${STATUS:-unknown}"
  if [[ -n "$SUBMISSION_ID" ]]; then
    log "fetching Apple notary log for $SUBMISSION_ID"
    xcrun notarytool log "$SUBMISSION_ID" \
                    "${NOTARY_AUTH_ARGS[@]}" \
                    --output-format json | tee "$LOG_JSON"
  fi
  die "notarization failed; not stapling $DMG_PATH"
fi

log "stapling ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

log "Gatekeeper assess"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

log "done. Notarized DMG at $DMG_PATH"
