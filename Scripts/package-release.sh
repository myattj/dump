#!/usr/bin/env bash
set -euo pipefail

# One-command release packaging for Dump.
#
# Produces a Developer ID signed and notarized DMG suitable for installing on
# other Apple Silicon Macs.
#
# Optional env:
#   DEVELOPER_ID       inferred from Keychain when omitted
#   NOTARY_PROFILE     defaults to dump-notary
#   TEAM_ID            used to choose among multiple Developer ID identities
#   SCHEME             defaults to Dump
#   CONFIGURATION      defaults to Release
#   DERIVED_DATA_PATH  defaults to build/
#   OUTPUT_DIR         defaults to build/
#   DMG_NAME           defaults to Dump
#   ARCH               defaults to arm64
#   DESTINATION        defaults to "platform=macOS,arch=$ARCH"
#
# Flags:
#   --skip-tests       do not run unit tests before building the release app
#   --skip-xcodegen    do not regenerate Dump.xcodeproj from project.yml
#   --skip-sign        leave the app ad-hoc signed
#   --skip-notarize    do not create/submit/staple the DMG
#   --no-clean         build without xcodebuild clean
#   --dry-run          print commands without running them

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SCHEME="${SCHEME:-Dump}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build}"
DMG_NAME="${DMG_NAME:-Dump}"
NOTARY_PROFILE="${NOTARY_PROFILE:-dump-notary}"
TEAM_ID="${TEAM_ID:-}"
ARCH="${ARCH:-arm64}"
DESTINATION="${DESTINATION:-platform=macOS,arch=$ARCH}"
PROJECT="${PROJECT:-$ROOT_DIR/Dump.xcodeproj}"

RUN_TESTS=1
RUN_XCODEGEN=1
RUN_SIGN=1
RUN_NOTARIZE=1
CLEAN=1
DRY_RUN=0

usage() {
  awk '
    /^# One-command/ { show = 1 }
    show && /^#/ { sub(/^# ?/, ""); print; next }
    show { exit }
  ' "$0"
}

log() { printf '\033[34m[package]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[package]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[package]\033[0m %s\n' "$*" >&2
  exit 1
}

quote_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v out '%s %q' "$out" "$arg"
  done
  printf '%s\n' "${out# }"
}

run() {
  log "$(quote_cmd "$@")"
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name must be set"
}

infer_developer_id() {
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')"
  if [[ -z "$identities" ]]; then
    return 0
  fi

  if [[ -n "$TEAM_ID" ]]; then
    printf '%s\n' "$identities" | grep "($TEAM_ID)" | head -n1
    return 0
  fi

  printf '%s\n' "$identities" | head -n1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests)
      RUN_TESTS=0
      ;;
    --skip-xcodegen)
      RUN_XCODEGEN=0
      ;;
    --skip-sign)
      RUN_SIGN=0
      ;;
    --skip-notarize)
      RUN_NOTARIZE=0
      ;;
    --no-clean)
      CLEAN=0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

require_cmd xcodebuild
require_cmd /usr/libexec/PlistBuddy

if [[ "$RUN_NOTARIZE" == "1" ]]; then
  RUN_SIGN=1
fi

if [[ "$RUN_SIGN" == "1" ]]; then
  require_cmd codesign
  DEVELOPER_ID="${DEVELOPER_ID:-$(infer_developer_id)}"
  if [[ -z "$DEVELOPER_ID" ]]; then
    die "DEVELOPER_ID is not set and no Developer ID Application identity was found in Keychain"
  fi
  log "using signing identity: $DEVELOPER_ID"
fi

if [[ "$RUN_NOTARIZE" == "1" ]]; then
  require_cmd hdiutil
  require_cmd xcrun
  require_cmd spctl
  log "using notary profile: $NOTARY_PROFILE"
fi

cd "$ROOT_DIR"

if [[ "$RUN_XCODEGEN" == "1" ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    run xcodegen generate
  elif [[ ! -d "$PROJECT" ]]; then
    die "xcodegen is not installed and $PROJECT does not exist"
  else
    warn "xcodegen not found; using existing $PROJECT"
  fi
fi

run "$ROOT_DIR/Scripts/fetch-runtime.sh"

if [[ "$RUN_TESTS" == "1" ]]; then
  run xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION" \
    test
fi

build_args=(
  xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -destination "$DESTINATION"
)

if [[ "$CLEAN" == "1" ]]; then
  build_args+=(clean)
fi
build_args+=(build)

run "${build_args[@]}"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$SCHEME.app"

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -d "$APP_PATH" ]] || die "built app not found at $APP_PATH"
  [[ -x "$APP_PATH/Contents/Resources/runtime/node/bin/node" ]] || die "bundled node runtime missing from app"
  [[ -f "$APP_PATH/Contents/Resources/runtime/qmd/node_modules/@tobilu/qmd/dist/cli/qmd.js" ]] || die "bundled qmd runtime missing from app"
fi

if [[ "$RUN_SIGN" == "1" ]]; then
  run env \
    APP_PATH="$APP_PATH" \
    DEVELOPER_ID="$DEVELOPER_ID" \
    "$ROOT_DIR/Scripts/sign.sh"
else
  warn "skipping Developer ID signing"
fi

if [[ "$RUN_NOTARIZE" == "1" ]]; then
  run env \
    APP_PATH="$APP_PATH" \
    DEVELOPER_ID="$DEVELOPER_ID" \
    NOTARY_PROFILE="$NOTARY_PROFILE" \
    OUTPUT_DIR="$OUTPUT_DIR" \
    DMG_NAME="$DMG_NAME" \
    "$ROOT_DIR/Scripts/notarize.sh"

  if [[ "$DRY_RUN" != "1" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
    DMG_PATH="$OUTPUT_DIR/${DMG_NAME}-${VERSION}.dmg"
    [[ -f "$DMG_PATH" ]] || die "expected DMG not found at $DMG_PATH"
    log "release ready: $DMG_PATH"
  fi
else
  warn "skipping DMG notarization"
  if [[ "$RUN_SIGN" == "1" ]]; then
    log "signed app ready: $APP_PATH"
  else
    log "release app build ready: $APP_PATH"
  fi
fi
