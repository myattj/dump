#!/usr/bin/env bash
set -euo pipefail

# Generates the Xcode project, prepares the bundled runtime, and creates a
# locally signed Release build at build/local/Dump.app.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/Dump.xcodeproj"
BUILD_DIR="$ROOT_DIR/build/local"
DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
APP_PATH="$BUILD_DIR/Dump.app"
DESTINATION="platform=macOS,arch=arm64"

RUN_TESTS=0
OPEN_APP=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./Scripts/build-local.sh [options]

Build Dump from source for the current Apple-silicon Mac.

Options:
  --test       Run the unit tests before building the Release app
  --open       Open Dump after a successful build
  --dry-run    Print the build commands without running them
  -h, --help   Show this help

Output: build/local/Dump.app
EOF
}

log() { printf '\033[34m[build-local]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[build-local]\033[0m %s\n' "$*" >&2
  exit 1
}

quote_cmd() {
  local output=""
  local argument
  for argument in "$@"; do
    printf -v output '%s %q' "$output" "$argument"
  done
  printf '%s\n' "${output# }"
}

run() {
  log "$(quote_cmd "$@")"
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

check_environment() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Dump can only be built on macOS"
  [[ "$(uname -m)" == "arm64" ]] || die "Dump requires an Apple-silicon Mac and a native arm64 shell"

  local macos_version
  local macos_major
  macos_version="$(sw_vers -productVersion)"
  macos_major="${macos_version%%.*}"
  [[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 14 ]] || die "macOS 14 or newer is required (found $macos_version)"

  require_command xcode-select
  require_command xcodebuild
  require_command xcodegen
  require_command xcrun

  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [[ -z "$developer_dir" || ! -d "$developer_dir/Platforms/MacOSX.platform" ]]; then
    die "full Xcode is not selected; run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  fi

  local xcode_version
  local xcode_major
  xcode_version="$(xcodebuild -version | awk '/^Xcode / { print $2 }')"
  xcode_major="${xcode_version%%.*}"
  [[ "$xcode_major" =~ ^[0-9]+$ && "$xcode_major" -ge 16 ]] || die "Xcode 16 or newer is required (found ${xcode_version:-unknown})"

  if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    die "Xcode setup is incomplete; run: sudo xcodebuild -runFirstLaunch"
  fi
  xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || die "the macOS SDK is unavailable in the selected Xcode"

  log "macOS $macos_version, Xcode $xcode_version, arm64"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test)
      RUN_TESTS=1
      ;;
    --open)
      OPEN_APP=1
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

check_environment
cd "$ROOT_DIR"

run xcodegen generate
run "$ROOT_DIR/Scripts/fetch-runtime.sh"

if [[ "$RUN_TESTS" == "1" ]]; then
  run xcodebuild \
    -project "$PROJECT" \
    -scheme Dump \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -destination "$DESTINATION" \
    CODE_SIGNING_ALLOWED=NO \
    test
fi

run xcodebuild \
  -project "$PROJECT" \
  -scheme Dump \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination "$DESTINATION" \
  "CONFIGURATION_BUILD_DIR=$BUILD_DIR" \
  build

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -d "$APP_PATH" ]] || die "build completed but $APP_PATH was not created"
  [[ -x "$APP_PATH/Contents/Resources/runtime/node/bin/node" ]] || die "the built app is missing its Node runtime"
  [[ -f "$APP_PATH/Contents/Resources/runtime/qmd/node_modules/@tobilu/qmd/dist/cli/qmd.js" ]] || die "the built app is missing its qmd CLI"
  [[ -f "$APP_PATH/Contents/Resources/runtime/qmd/node_modules/.runtime-ready" ]] || die "the built app contains an unvalidated runtime"
  log "app ready at $APP_PATH"

  if [[ "$OPEN_APP" == "1" ]]; then
    run open "$APP_PATH"
  fi
fi
