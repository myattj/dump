#!/usr/bin/env bash
set -euo pipefail

# Downloads pinned Node.js (Apple Silicon) and qmd into Runtime/ so Xcode
# can bundle them into Dump.app/Contents/Resources/runtime/ at build time.
#
# Dump ships arm64-only — no Intel Mac support. That keeps native-module
# packaging simple: single-arch tarball, no lipo dance.
#
# Idempotent: skips work when the expected pinned output already exists.
# Force a refetch by deleting Runtime/node or Runtime/qmd/node_modules.

NODE_VERSION="22.16.0"
QMD_VERSION="2.1.0"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/Runtime"
NODE_DIR="$RUNTIME_DIR/node"
QMD_DIR="$RUNTIME_DIR/qmd"
WORK_DIR="$RUNTIME_DIR/.work"

mkdir -p "$RUNTIME_DIR" "$WORK_DIR"

log() { printf '\033[36m[fetch-runtime]\033[0m %s\n' "$*" >&2; }

fetch_node() {
  if [[ -x "$NODE_DIR/bin/node" ]]; then
    local installed
    installed="$("$NODE_DIR/bin/node" --version 2>/dev/null || true)"
    if [[ "$installed" == "v${NODE_VERSION}" ]]; then
      log "node ${NODE_VERSION} arm64 already present, skipping"
      return
    fi
    log "replacing node $installed with v${NODE_VERSION}"
    rm -rf "$NODE_DIR"
  fi

  local base="https://nodejs.org/dist/v${NODE_VERSION}"
  local arm_tar="node-v${NODE_VERSION}-darwin-arm64.tar.gz"

  log "downloading Node ${NODE_VERSION} arm64"
  curl -fsSL --retry 3 -o "$WORK_DIR/$arm_tar" "$base/$arm_tar"

  log "verifying SHASUMS256.txt"
  curl -fsSL --retry 3 -o "$WORK_DIR/SHASUMS256.txt" "$base/SHASUMS256.txt"
  (
    cd "$WORK_DIR"
    grep -E "( |\*)${arm_tar}\$" SHASUMS256.txt | shasum -a 256 -c -
  )

  log "extracting"
  rm -rf "$NODE_DIR"
  mkdir -p "$NODE_DIR"
  tar -xzf "$WORK_DIR/$arm_tar" -C "$NODE_DIR" --strip-components=1

  # Trim Node's own headers/share docs; the app doesn't need them.
  rm -rf "$NODE_DIR/include" "$NODE_DIR/share/doc" "$NODE_DIR/share/man" "$NODE_DIR/share/systemtap"

  log "node arm64 at $NODE_DIR/bin/node"
}

install_qmd() {
  if [[ -d "$QMD_DIR/node_modules/@tobilu/qmd" ]]; then
    local installed
    installed="$(node -p "require('$QMD_DIR/node_modules/@tobilu/qmd/package.json').version" 2>/dev/null || true)"
    if [[ "$installed" == "$QMD_VERSION" ]]; then
      log "qmd ${QMD_VERSION} already installed, skipping"
      return
    fi
    log "replacing qmd $installed with $QMD_VERSION"
    rm -rf "$QMD_DIR/node_modules"
  fi

  mkdir -p "$QMD_DIR"
  if [[ ! -f "$QMD_DIR/package-lock.json" ]]; then
    echo "fetch-runtime: Runtime/qmd/package-lock.json is required; restore it from git" >&2
    exit 1
  fi
  cat > "$QMD_DIR/package.json" <<JSON
{
  "name": "dump-runtime-qmd",
  "private": true,
  "dependencies": {
    "@tobilu/qmd": "${QMD_VERSION}"
  }
}
JSON

  log "npm ci for @tobilu/qmd@${QMD_VERSION} (this compiles native modules; takes a minute)"
  (
    cd "$QMD_DIR"
    # Use the bundled Node so native modules link against the same ABI we ship.
    PATH="$NODE_DIR/bin:$PATH" npm ci \
        --omit=dev --include=optional \
        --cpu=arm64 --os=darwin \
        --no-audit --no-fund --loglevel=error
  )

  # Strip prebuilt binaries for arches we don't ship. tree-sitter-* and similar
  # packages drop ~50MB of Windows / Linux / x64 .node binaries that just bloat
  # the .app.
  log "trimming non-arm64 prebuilt natives"
  find "$QMD_DIR/node_modules" -type d \( \
       -name "linux-*" -o \
       -name "win32-*" -o \
       -name "darwin-x64" -o \
       -name "darwin-ia32" \
     \) -prune -exec rm -rf {} + 2>/dev/null || true
  find "$QMD_DIR/node_modules" -type d \
       \( -name "*-darwin-x64" -o -name "*-linux-*" -o -name "*-win32-*" \) \
       -prune -exec rm -rf {} + 2>/dev/null || true

  # Sanity check the CLI entry QMDDaemonController launches.
  local cli_src="$QMD_DIR/node_modules/@tobilu/qmd/dist/cli/qmd.js"
  if [[ ! -f "$cli_src" ]]; then
    echo "fetch-runtime: expected qmd CLI at $cli_src — package layout changed; update QMDDaemonController.qmdEntryURL" >&2
    exit 1
  fi
  local cli_ver
  cli_ver="$("$NODE_DIR/bin/node" "$cli_src" --version 2>/dev/null || true)"
  log "qmd CLI version: ${cli_ver:-unknown}"

  log "qmd installed at $QMD_DIR"
}

fetch_node
install_qmd

rm -rf "$WORK_DIR"
log "done. Runtime ready at $RUNTIME_DIR"
