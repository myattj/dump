#!/usr/bin/env bash
set -euo pipefail

# Launches the actual built app from a clean profile and storage root while
# injecting hostile qmd paths. This covers the production controller wiring,
# directory creation, bundled runtime launch, and graceful qmd child cleanup that
# the direct qmd integration test intentionally bypasses.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/build/local/Dump.app"
BASE_TMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
BASE_TMP="${BASE_TMP%/}"

ORIGINAL_HOME="${HOME-}"
ORIGINAL_XDG_CACHE_HOME="${XDG_CACHE_HOME-}"
ORIGINAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME-}"
ORIGINAL_QMD_CONFIG_DIR="${QMD_CONFIG_DIR-}"
ORIGINAL_INDEX_PATH="${INDEX_PATH-}"

TEST_ROOT=""
APP_PID=""
QMD_PID=""
CHILD_PIDS=""
APP_OUTPUT=""

usage() {
  cat <<'EOF'
Usage: ./Scripts/test-app-storage-isolation.sh [--app PATH]

Launch the built Dump app with a disposable profile and storage directory,
prove that it overrides inherited qmd paths, then quit it gracefully and
verify its owned qmd children exit. No models are downloaded and normal Dump
preferences and qmd state are checked for changes.

Default app: build/local/Dump.app
EOF
}

log() { printf '\033[35m[app-storage-smoke]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[app-storage-smoke]\033[0m FAIL: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

pid_running() {
  kill -0 "$1" >/dev/null 2>&1
}

wait_for_pid_exit() {
  local pid="$1"
  local attempts="$2"
  local attempt=0
  while pid_running "$pid" && [[ "$attempt" -lt "$attempts" ]]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  ! pid_running "$pid"
}

request_app_quit() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  xcrun swift -e '
    import AppKit
    guard CommandLine.arguments.count == 2,
          let pid = Int32(CommandLine.arguments[1]),
          let app = NSRunningApplication(processIdentifier: pid),
          app.terminate()
    else { exit(1) }
  ' "$pid"
}

stop_app() {
  local pid="${APP_PID:-}"
  local forced=0
  [[ -n "$pid" ]] || return 0

  if pid_running "$pid"; then
    request_app_quit "$pid" >/dev/null 2>&1 || true
    if ! wait_for_pid_exit "$pid" 100; then
      forced=1
      kill -TERM "$pid" >/dev/null 2>&1 || true
      wait_for_pid_exit "$pid" 50 || kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  fi
  wait "$pid" >/dev/null 2>&1 || true
  APP_PID=""
  return "$forced"
}

qmd_pid_is_daemon() {
  [[ -n "${QMD_PID:-}" ]] || return 1
  local command
  command="$(ps -ww -p "$QMD_PID" -o command= 2>/dev/null || true)"
  [[ "$command" == *"$QMD_CLI mcp --http --port "* ]]
}

find_daemon_pid() {
  local child=""
  local command=""
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    command="$(ps -ww -p "$child" -o command= 2>/dev/null || true)"
    if [[ "$command" == *"$QMD_CLI mcp --http --port "* ]]; then
      printf '%s\n' "$child"
      return 0
    fi
  done < <(pgrep -P "$APP_PID" 2>/dev/null || true)
  return 1
}

daemon_owns_listener() {
  local pid="$1"
  local port="$2"
  lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null |
    grep -Fx -- "$pid" >/dev/null
}

qmd_process_matches_test_root() {
  local pid="$1"
  local details
  details="$(ps eww -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$details" == *"$QMD_CLI "* ]] &&
    [[ " $details " == *" INDEX_PATH=$EXPECTED_INDEX "* ]]
}

snapshot_owned_qmd_children() {
  local child=""
  [[ -n "${APP_PID:-}" ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    qmd_process_matches_test_root "$child" || continue
    case " $CHILD_PIDS " in
      *" $child "*) ;;
      *) CHILD_PIDS="${CHILD_PIDS:+$CHILD_PIDS }$child" ;;
    esac
  done < <(pgrep -P "$APP_PID" 2>/dev/null || true)
}

snapshot_test_root_qmd_processes() {
  local candidate=""
  [[ -n "${QMD_CLI:-}" && -n "${EXPECTED_INDEX:-}" ]] || return 0
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    qmd_process_matches_test_root "$candidate" || continue
    case " $CHILD_PIDS " in
      *" $candidate "*) ;;
      *) CHILD_PIDS="${CHILD_PIDS:+$CHILD_PIDS }$candidate" ;;
    esac
  done < <(pgrep -f "$QMD_CLI" 2>/dev/null || true)
}

has_active_qmd_cli_child() {
  local child=""
  local command=""
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    command="$(ps -ww -p "$child" -o command= 2>/dev/null || true)"
    if [[ "$command" == *"$QMD_CLI "* ]] &&
       [[ "$command" != *"$QMD_CLI mcp --http --port "* ]]; then
      return 0
    fi
  done < <(pgrep -P "$APP_PID" 2>/dev/null || true)
  return 1
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e

  if [[ "$status" -ne 0 ]]; then
    if [[ -n "${APP_OUTPUT:-}" && -f "$APP_OUTPUT" ]]; then
      log "app output (last 80 lines):"
      tail -n 80 "$APP_OUTPUT" >&2
    fi
    if [[ -n "${TEST_ROOT:-}" && -f "$TEST_ROOT/profile/Library/Logs/Dump/dump.jsonl" ]]; then
      log "Dump diagnostics (last 80 lines):"
      tail -n 80 "$TEST_ROOT/profile/Library/Logs/Dump/dump.jsonl" >&2
    fi
  fi

  # Capture direct qmd children before any forced app termination can orphan
  # them and change their parent PID.
  snapshot_owned_qmd_children
  snapshot_test_root_qmd_processes
  stop_app >/dev/null 2>&1 || true
  # A child can appear or be reparented while the app processes its graceful
  # termination reply. Re-scan by this test's exact INDEX_PATH before the
  # disposable state it references is deleted.
  snapshot_test_root_qmd_processes
  if qmd_pid_is_daemon; then
    kill -TERM "$QMD_PID" >/dev/null 2>&1 || true
    wait_for_pid_exit "$QMD_PID" 50 || kill -KILL "$QMD_PID" >/dev/null 2>&1 || true
  fi
  for child in $CHILD_PIDS; do
    if qmd_process_matches_test_root "$child"; then
      kill -TERM "$child" >/dev/null 2>&1 || true
      if ! wait_for_pid_exit "$child" 50 && qmd_process_matches_test_root "$child"; then
        kill -KILL "$child" >/dev/null 2>&1 || true
      fi
    fi
  done

  if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
    case "$TEST_ROOT" in
      "$BASE_TMP"/dump-app-storage.*)
        rm -rf -- "$TEST_ROOT"
        ;;
      *)
        log "refusing to remove unexpected temporary path: $TEST_ROOT"
        ;;
    esac
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || die "--app requires a path"
      APP_PATH="$2"
      shift
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

[[ "$(uname -s)" == "Darwin" ]] || die "this smoke test requires macOS"
require_command cmp
require_command curl
require_command find
require_command grep
require_command awk
require_command lsof
require_command mktemp
require_command pgrep
require_command ps
require_command tail
require_command tr
require_command xcrun

APP_PATH="${APP_PATH%/}"
APP_EXEC="$APP_PATH/Contents/MacOS/Dump"
APP_RUNTIME="$APP_PATH/Contents/Resources/runtime"
NODE="$APP_RUNTIME/node/bin/node"
QMD_CLI="$APP_RUNTIME/qmd/node_modules/@tobilu/qmd/dist/cli/qmd.js"
[[ -x "$APP_EXEC" ]] || die "app executable is missing: $APP_EXEC"
[[ -x "$NODE" ]] || die "bundled Node is missing or not executable: $NODE"
[[ -f "$QMD_CLI" ]] || die "bundled qmd CLI is missing: $QMD_CLI"

if [[ -z "$ORIGINAL_HOME" ]]; then
  ORIGINAL_HOME="$("$NODE" -e 'process.stdout.write(require("node:os").homedir())')"
fi

resolve_path() {
  "$NODE" -e 'process.stdout.write(require("node:path").resolve(process.argv[1]))' "$1"
}

if [[ -n "$ORIGINAL_XDG_CACHE_HOME" ]]; then
  GLOBAL_CACHE_ROOT="$(resolve_path "$ORIGINAL_XDG_CACHE_HOME")"
else
  GLOBAL_CACHE_ROOT="$(resolve_path "$ORIGINAL_HOME/.cache")"
fi
if [[ -n "$ORIGINAL_INDEX_PATH" ]]; then
  GLOBAL_INDEX="$(resolve_path "$ORIGINAL_INDEX_PATH")"
else
  GLOBAL_INDEX="$GLOBAL_CACHE_ROOT/qmd/index.sqlite"
fi
if [[ -n "$ORIGINAL_QMD_CONFIG_DIR" ]]; then
  GLOBAL_CONFIG_DIR="$(resolve_path "$ORIGINAL_QMD_CONFIG_DIR")"
elif [[ -n "$ORIGINAL_XDG_CONFIG_HOME" ]]; then
  GLOBAL_CONFIG_DIR="$(resolve_path "$ORIGINAL_XDG_CONFIG_HOME/qmd")"
else
  GLOBAL_CONFIG_DIR="$(resolve_path "$ORIGINAL_HOME/.config/qmd")"
fi
GLOBAL_CONFIG_FILE="$GLOBAL_CONFIG_DIR/index.yml"
GLOBAL_PREFERENCES="$(resolve_path "$ORIGINAL_HOME/Library/Preferences/com.joshmyatt.dump.plist")"

TEST_ROOT="$(mktemp -d "$BASE_TMP/dump-app-storage.XXXXXX")"
case "$TEST_ROOT" in
  "$BASE_TMP"/dump-app-storage.*) ;;
  *) die "mktemp returned an unexpected path: $TEST_ROOT" ;;
esac

PROFILE="$TEST_ROOT/profile"
STORAGE="$TEST_ROOT/storage"
APP_OUTPUT="$TEST_ROOT/app-output.log"
HOSTILE_INDEX="$TEST_ROOT/hostile-index/index.sqlite"
HOSTILE_CONFIG="$TEST_ROOT/hostile-config"
HOSTILE_CACHE="$TEST_ROOT/hostile-cache"
HOSTILE_XDG_CONFIG="$TEST_ROOT/hostile-xdg-config"
MISSING_MODEL="$TEST_ROOT/intentionally-missing-model.gguf"
QMD_ROOT="$STORAGE/.dump-qmd"
EXPECTED_INDEX="$QMD_ROOT/qmd/index.sqlite"
EXPECTED_CONFIG="$QMD_ROOT/config/index.yml"
EXPECTED_MODELS="$QMD_ROOT/qmd/models"
GLOBAL_BEFORE="$TEST_ROOT/global-before.json"
GLOBAL_AFTER="$TEST_ROOT/global-after.json"

snapshot_global_state() {
  local output="$1"
  "$NODE" -e '
    const fs = require("node:fs");
    const crypto = require("node:crypto");
    const output = process.argv[1];
    const result = {};
    for (const path of process.argv.slice(2).sort()) {
      try {
        const stat = fs.lstatSync(path);
        const item = { exists: true, size: stat.size, mtimeMs: stat.mtimeMs };
        if (stat.isFile()) item.sha256 = crypto.createHash("sha256").update(fs.readFileSync(path)).digest("hex");
        if (stat.isSymbolicLink()) item.target = fs.readlinkSync(path);
        result[path] = item;
      } catch (error) {
        if (error && error.code === "ENOENT") result[path] = { exists: false };
        else throw error;
      }
    }
    fs.writeFileSync(output, JSON.stringify(result));
  ' "$output" \
    "$GLOBAL_INDEX" "$GLOBAL_INDEX-wal" "$GLOBAL_INDEX-shm" "$GLOBAL_INDEX-journal" \
    "$GLOBAL_CONFIG_FILE" "$GLOBAL_PREFERENCES"
}

assert_hostile_paths_untouched() {
  [[ ! -e "$HOSTILE_INDEX" ]] || die "inherited INDEX_PATH was written"
  [[ ! -e "$HOSTILE_CONFIG" ]] || die "inherited QMD_CONFIG_DIR was written"
  [[ ! -e "$HOSTILE_CACHE" ]] || die "inherited XDG_CACHE_HOME was written"
  [[ ! -e "$HOSTILE_XDG_CONFIG" ]] || die "inherited XDG_CONFIG_HOME was written"
}

assert_no_model_files() {
  if [[ -d "$EXPECTED_MODELS" ]] &&
     [[ -n "$(find "$EXPECTED_MODELS" -type f -print -quit 2>/dev/null)" ]]; then
    die "the no-download smoke unexpectedly wrote a model file"
  fi
}

post_app_mcp() {
  local request_file="$1"
  local response_file="$2"
  local headers_file="$3"
  local with_session="$4"
  local status=""
  local curl_args=(
    --silent --show-error --connect-timeout 2 --max-time 30
    --noproxy localhost
    --request POST
    --header 'Content-Type: application/json'
    --header 'Accept: application/json, text/event-stream'
    --data-binary "@$request_file"
    --dump-header "$headers_file"
    --output "$response_file"
    --write-out '%{http_code}'
  )
  if [[ "$with_session" == "1" ]]; then
    curl_args+=(--header "Mcp-Session-Id: $APP_MCP_SESSION_ID")
  fi
  status="$(curl "${curl_args[@]}" "http://localhost:$DAEMON_PORT/mcp")" \
    || die "app-owned MCP request failed: $request_file"
  case "$status" in
    2??) ;;
    *) die "app-owned MCP request returned HTTP $status" ;;
  esac
}

mkdir -p "$PROFILE/tmp" "$STORAGE/inbox"
printf '%s\n' \
  '# App storage isolation probe' \
  '' \
  'Marker: dump-app-storage-probe-7319' \
  >"$STORAGE/inbox/xdg-probe.md"
STORAGE_REAL="$(cd "$STORAGE" && pwd -P)"

[[ ! -e "$QMD_ROOT" ]] || die "qmd root was not clean before launch"
assert_hostile_paths_untouched
snapshot_global_state "$GLOBAL_BEFORE"

log "launching $APP_PATH with a clean qmd root"
env \
  -u CI \
  -u DUMP_UNIT_TESTING \
  -u XCTestConfigurationFilePath \
  -u XCTestBundlePath \
  CFFIXED_USER_HOME="$PROFILE" \
  CFPREFERENCES_AVOID_DAEMON=1 \
  TMPDIR="$PROFILE/tmp/" \
  INDEX_PATH="$HOSTILE_INDEX" \
  QMD_CONFIG_DIR="$HOSTILE_CONFIG" \
  XDG_CACHE_HOME="$HOSTILE_CACHE" \
  XDG_CONFIG_HOME="$HOSTILE_XDG_CONFIG" \
  QMD_EMBED_MODEL="$MISSING_MODEL" \
  NO_COLOR=1 \
  "$APP_EXEC" \
  -ApplePersistenceIgnoreState YES \
  -dump.onboarding.completed YES \
  -dump.storagePath "$STORAGE" \
  -dump.classifier.mode local \
  -SUEnableAutomaticChecks NO \
  >"$APP_OUTPUT" 2>&1 &
APP_PID=$!

READY=0
QUIET_PASSES=0
LAST_DAEMON=""
for _ in {1..240}; do
  pid_running "$APP_PID" || die "Dump exited during startup"
  snapshot_owned_qmd_children
  snapshot_test_root_qmd_processes
  CANDIDATE="$(find_daemon_pid || true)"
  if [[ -n "$CANDIDATE" ]]; then
    if [[ "$CANDIDATE" != "$LAST_DAEMON" ]]; then
      QUIET_PASSES=0
      LAST_DAEMON="$CANDIDATE"
    fi
    QMD_PID="$CANDIDATE"
  fi

  if [[ -s "$EXPECTED_INDEX" && -f "$EXPECTED_CONFIG" &&
        -d "$STORAGE/inbox" && -d "$STORAGE/meetings" && -d "$STORAGE/pdfs" ]] &&
     grep -F -- "$STORAGE_REAL/inbox" "$EXPECTED_CONFIG" >/dev/null &&
     grep -F -- "$STORAGE_REAL/meetings" "$EXPECTED_CONFIG" >/dev/null &&
     grep -F -- "$STORAGE_REAL/pdfs" "$EXPECTED_CONFIG" >/dev/null &&
     [[ -n "$QMD_PID" ]] && ! has_active_qmd_cli_child; then
    QUIET_PASSES=$((QUIET_PASSES + 1))
    if [[ "$QUIET_PASSES" -ge 2 ]]; then
      READY=1
      break
    fi
  else
    QUIET_PASSES=0
  fi
  sleep 0.25
done

[[ "$READY" == "1" ]] || die "production app wiring was not ready within 60 seconds"
qmd_pid_is_daemon || die "owned qmd daemon was not running"
assert_hostile_paths_untouched
assert_no_model_files

DAEMON_ENV="$(ps eww -p "$QMD_PID" -o command=)"
for expected in \
  "INDEX_PATH=$EXPECTED_INDEX" \
  "QMD_CONFIG_DIR=$QMD_ROOT/config" \
  "XDG_CACHE_HOME=$QMD_ROOT"; do
  [[ " $DAEMON_ENV " == *" $expected "* ]] || die "daemon environment is missing $expected"
done

# Query the daemon launched by the app itself. This proves the production
# bootstrap indexed the seeded note; the direct qmd smoke cannot cover this
# controller/AppCoordinator path.
DAEMON_COMMAND="$(ps -ww -p "$QMD_PID" -o command=)"
DAEMON_PORT="$(printf '%s\n' "$DAEMON_COMMAND" | awk '{ for (i = 1; i <= NF; i++) if ($i == "--port") { print $(i + 1); exit } }')"
[[ "$DAEMON_PORT" =~ ^[0-9]+$ ]] || die "could not resolve the app-owned daemon port"
[[ "$DAEMON_PORT" -ge 1024 && "$DAEMON_PORT" -le 65535 ]] || die "invalid app-owned daemon port: $DAEMON_PORT"
daemon_owns_listener "$QMD_PID" "$DAEMON_PORT" \
  || die "app-owned qmd PID $QMD_PID does not own TCP listener $DAEMON_PORT"

APP_INIT_REQUEST="$TEST_ROOT/app-initialize-request.json"
APP_INIT_RESPONSE="$TEST_ROOT/app-initialize-response.json"
APP_INIT_HEADERS="$TEST_ROOT/app-initialize-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":"app-init-1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"dump-app-storage-smoke","version":"1.0"}}}' >"$APP_INIT_REQUEST"
post_app_mcp "$APP_INIT_REQUEST" "$APP_INIT_RESPONSE" "$APP_INIT_HEADERS" 0
APP_MCP_SESSION_ID="$(tr -d '\r' <"$APP_INIT_HEADERS" | awk 'tolower($1) == "mcp-session-id:" { print $2; exit }')"
[[ -n "$APP_MCP_SESSION_ID" ]] || die "app-owned daemon did not return an MCP session"

APP_NOTIFY_REQUEST="$TEST_ROOT/app-initialized-request.json"
APP_NOTIFY_RESPONSE="$TEST_ROOT/app-initialized-response.txt"
APP_NOTIFY_HEADERS="$TEST_ROOT/app-initialized-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >"$APP_NOTIFY_REQUEST"
post_app_mcp "$APP_NOTIFY_REQUEST" "$APP_NOTIFY_RESPONSE" "$APP_NOTIFY_HEADERS" 1

APP_STATUS_REQUEST="$TEST_ROOT/app-status-request.json"
APP_STATUS_RESPONSE="$TEST_ROOT/app-status-response.json"
APP_STATUS_HEADERS="$TEST_ROOT/app-status-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":"app-status-1","method":"tools/call","params":{"name":"status","arguments":{}}}' >"$APP_STATUS_REQUEST"
post_app_mcp "$APP_STATUS_REQUEST" "$APP_STATUS_RESPONSE" "$APP_STATUS_HEADERS" 1
"$NODE" -e '
  const response = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (response.error) throw new Error(`app status failed: ${JSON.stringify(response.error)}`);
  const status = response.result && response.result.structuredContent;
  if (!status || status.totalDocuments < 1) throw new Error("app bootstrap indexed no documents");
  if (!Array.isArray(status.collections) || !status.collections.some((item) => item.name === "inbox")) {
    throw new Error("app bootstrap status is missing the inbox collection");
  }
' "$APP_STATUS_RESPONSE"

APP_QUERY_REQUEST="$TEST_ROOT/app-query-request.json"
APP_QUERY_RESPONSE="$TEST_ROOT/app-query-response.json"
APP_QUERY_HEADERS="$TEST_ROOT/app-query-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":"app-query-1","method":"tools/call","params":{"name":"query","arguments":{"searches":[{"type":"lex","query":"dump-app-storage-probe-7319"}],"collections":["inbox"],"limit":5,"minScore":0,"rerank":false}}}' >"$APP_QUERY_REQUEST"
post_app_mcp "$APP_QUERY_REQUEST" "$APP_QUERY_RESPONSE" "$APP_QUERY_HEADERS" 1
"$NODE" -e '
  const response = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (response.error) throw new Error(`app query failed: ${JSON.stringify(response.error)}`);
  const results = response.result && response.result.structuredContent && response.result.structuredContent.results;
  if (!Array.isArray(results) || !results.some((item) => typeof item.file === "string" && (item.file === "xdg-probe.md" || item.file.endsWith("/xdg-probe.md")))) {
    throw new Error(`seeded fixture missing from app-owned query: ${JSON.stringify(results)}`);
  }
' "$APP_QUERY_RESPONSE"

curl --silent --show-error --max-time 5 --noproxy localhost --request DELETE \
  --header "Mcp-Session-Id: $APP_MCP_SESSION_ID" \
  "http://localhost:$DAEMON_PORT/mcp" >/dev/null || true
assert_no_model_files

snapshot_owned_qmd_children
log "requesting graceful termination of Dump (PID $APP_PID)"
request_app_quit "$APP_PID" || die "NSRunningApplication refused graceful termination"
wait_for_pid_exit "$APP_PID" 150 || die "Dump did not terminate gracefully"
set +e
wait "$APP_PID"
APP_STATUS=$?
set -e
APP_PID=""
[[ "$APP_STATUS" -eq 0 ]] || die "Dump exited with status $APP_STATUS"

for child in $CHILD_PIDS; do
  if qmd_process_matches_test_root "$child"; then
    wait_for_pid_exit "$child" 50 || die "owned qmd child process $child survived app termination"
  fi
done
snapshot_test_root_qmd_processes
for child in $CHILD_PIDS; do
  qmd_process_matches_test_root "$child" && die "owned qmd process $child survived app termination"
done
QMD_PID=""
assert_hostile_paths_untouched

snapshot_global_state "$GLOBAL_AFTER"
if ! cmp -s "$GLOBAL_BEFORE" "$GLOBAL_AFTER"; then
  die "normal Dump preferences or qmd config/index changed during the isolated launch (stop any regular Dump/qmd activity and retry)"
fi

log "PASS: built app created isolated qmd state and stopped all owned qmd children"
