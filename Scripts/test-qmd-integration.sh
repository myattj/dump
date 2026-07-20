#!/usr/bin/env bash
set -euo pipefail

# End-to-end smoke test for the exact Node + qmd runtime shipped by Dump.
# Every qmd process is pointed at a disposable HOME, config directory, cache,
# and SQLite index. The MCP server runs in the foreground as this script's
# child so cleanup never relies on a shared PID file or process-name matching.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

APP_PATH=""
RUNTIME_DIR=""
EMBED_MODEL=""
ALLOW_DOWNLOADS=0
SKIP_EMBED=0
REQUIRE_EMBED=0
PORT=""
QMD_COMMAND_TIMEOUT_MS="${QMD_COMMAND_TIMEOUT_MS:-600000}"

ORIGINAL_HOME="${HOME-}"
ORIGINAL_XDG_CACHE_HOME="${XDG_CACHE_HOME-}"
ORIGINAL_XDG_CONFIG_HOME="${XDG_CONFIG_HOME-}"
ORIGINAL_QMD_CONFIG_DIR="${QMD_CONFIG_DIR-}"
ORIGINAL_INDEX_PATH="${INDEX_PATH-}"
ORIGINAL_EMBED_MODEL="${QMD_EMBED_MODEL-}"

TEST_ROOT=""
MCP_PID=""
MCP_LOG=""
TMPDIR_ORIGINAL="${TMPDIR:-/tmp}"

usage() {
  cat <<'EOF'
Usage: ./Scripts/test-qmd-integration.sh [options]

Run a real collection -> index -> MCP query flow with Dump's bundled qmd.
The test uses disposable config/cache/index paths and never calls `qmd mcp
stop`, so it cannot stop or modify another qmd instance.

Options:
  --app PATH           Test PATH/Contents/Resources/runtime
  --runtime PATH       Test a runtime directory directly
  --port PORT          Use a specific local port (default: choose a free port)
  --embed-model PATH   Use this local GGUF model and require embed coverage
  --allow-downloads    Download a missing embedding model into the temp cache
  --require-embed      Fail instead of skipping when no cached model is found
  --skip-embed         Fast lexical-only test, even if a model is cached
  -h, --help           Show this help

Default runtime: build/local/Dump.app when present, otherwise Runtime/.
Default model policy: no downloads; embed only when the default model is
already cached. MCP lexical search is always exercised.
EOF
}

log() { printf '\033[36m[qmd-integration]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[31m[qmd-integration]\033[0m %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

daemon_pid_matches() {
  local pid="$1"
  local command=""
  local expected=""
  [[ -n "${NODE:-}" && -n "${QMD_CLI:-}" && -n "${PORT:-}" ]] || return 1
  command="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  expected="$NODE $QMD_CLI mcp --http --port $PORT"
  [[ "$command" == "$expected" || "$command" == *" $expected" ]]
}

daemon_owns_listener() {
  local pid="$1"
  lsof -nP -a -p "$pid" -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null |
    grep -Fx -- "$pid" >/dev/null
}

stop_daemon() {
  local pid="${MCP_PID:-}"
  local attempts=0
  local forced=0
  MCP_PID=""
  [[ -n "$pid" ]] || return 0

  if daemon_pid_matches "$pid"; then
    log "stopping owned qmd daemon (PID $pid)"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    while daemon_pid_matches "$pid" && [[ "$attempts" -lt 50 ]]; do
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if daemon_pid_matches "$pid"; then
      forced=1
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  elif kill -0 "$pid" >/dev/null 2>&1; then
    log "refusing to signal PID $pid because it is not the owned qmd daemon"
    return 1
  fi
  wait "$pid" >/dev/null 2>&1 || true
  return "$forced"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ "$status" -ne 0 && -n "${MCP_LOG:-}" && -f "$MCP_LOG" ]]; then
    log "qmd daemon log (last 40 lines):"
    tail -n 40 "$MCP_LOG" >&2
  fi
  stop_daemon >/dev/null 2>&1
  if [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]]; then
    case "$TEST_ROOT" in
      "${TMPDIR_ORIGINAL%/}"/dump-qmd-integration.*)
        rm -rf -- "$TEST_ROOT"
        ;;
      *)
        log "refusing to remove unexpected temp path: $TEST_ROOT"
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
    --runtime)
      [[ $# -ge 2 ]] || die "--runtime requires a path"
      RUNTIME_DIR="$2"
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      PORT="$2"
      shift
      ;;
    --embed-model)
      [[ $# -ge 2 ]] || die "--embed-model requires a path"
      EMBED_MODEL="$2"
      REQUIRE_EMBED=1
      shift
      ;;
    --allow-downloads)
      ALLOW_DOWNLOADS=1
      REQUIRE_EMBED=1
      ;;
    --require-embed)
      REQUIRE_EMBED=1
      ;;
    --skip-embed|--no-embed)
      SKIP_EMBED=1
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

[[ -z "$APP_PATH" || -z "$RUNTIME_DIR" ]] || die "use only one of --app or --runtime"
if [[ "$SKIP_EMBED" == "1" && ( "$REQUIRE_EMBED" == "1" || -n "$EMBED_MODEL" ) ]]; then
  die "--skip-embed cannot be combined with an embed requirement"
fi

if [[ -n "$APP_PATH" ]]; then
  RUNTIME_DIR="${APP_PATH%/}/Contents/Resources/runtime"
elif [[ -z "$RUNTIME_DIR" ]]; then
  if [[ -d "$ROOT_DIR/build/local/Dump.app/Contents/Resources/runtime" ]]; then
    APP_PATH="$ROOT_DIR/build/local/Dump.app"
    RUNTIME_DIR="$APP_PATH/Contents/Resources/runtime"
  else
    RUNTIME_DIR="$ROOT_DIR/Runtime"
  fi
fi

NODE="$RUNTIME_DIR/node/bin/node"
QMD_CLI="$RUNTIME_DIR/qmd/node_modules/@tobilu/qmd/dist/cli/qmd.js"
[[ -x "$NODE" ]] || die "bundled Node is missing or not executable: $NODE"
[[ -f "$QMD_CLI" ]] || die "bundled qmd CLI is missing: $QMD_CLI"

require_command curl
require_command cmp
require_command find
require_command grep
require_command lsof
require_command mktemp
require_command ps
require_command tail
[[ "$QMD_COMMAND_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]] \
  || die "QMD_COMMAND_TIMEOUT_MS must be a positive integer"

if [[ -z "$ORIGINAL_HOME" ]]; then
  ORIGINAL_HOME="$("$NODE" -e 'process.stdout.write(require("node:os").homedir())')"
fi

resolve_path() {
  "$NODE" -e 'process.stdout.write(require("node:path").resolve(process.argv[1]))' "$1"
}

real_path() {
  "$NODE" -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$1"
}

RUNTIME_DIR="$(resolve_path "$RUNTIME_DIR")"
NODE="$RUNTIME_DIR/node/bin/node"
QMD_CLI="$RUNTIME_DIR/qmd/node_modules/@tobilu/qmd/dist/cli/qmd.js"

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

TEST_ROOT="$(mktemp -d "${TMPDIR_ORIGINAL%/}/dump-qmd-integration.XXXXXX")"
case "$TEST_ROOT" in
  "${TMPDIR_ORIGINAL%/}"/dump-qmd-integration.*) ;;
  *) die "mktemp returned an unexpected path: $TEST_ROOT" ;;
esac

mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/cache/qmd/models" \
  "$TEST_ROOT/config/qmd" "$TEST_ROOT/tmp" "$TEST_ROOT/fixture"

TEST_HOME="$TEST_ROOT/home"
TEST_XDG_CACHE_HOME="$TEST_ROOT/cache"
TEST_XDG_CONFIG_HOME="$TEST_ROOT/config"
TEST_QMD_CONFIG_DIR="$TEST_ROOT/config/qmd"
TEST_INDEX_PATH="$TEST_ROOT/cache/qmd/index.sqlite"
TEST_TMPDIR="$TEST_ROOT/tmp"
ACTIVE_EMBED_MODEL=""
QMD_BASE_ENV=(
  -u QMD_EMBED_MODEL
  "HOME=$TEST_HOME"
  "XDG_CACHE_HOME=$TEST_XDG_CACHE_HOME"
  "XDG_CONFIG_HOME=$TEST_XDG_CONFIG_HOME"
  "QMD_CONFIG_DIR=$TEST_QMD_CONFIG_DIR"
  "INDEX_PATH=$TEST_INDEX_PATH"
  "TMPDIR=$TEST_TMPDIR"
  "NO_COLOR=1"
)

[[ "$TEST_INDEX_PATH" != "$GLOBAL_INDEX" ]] || die "temporary and global index paths unexpectedly match"
[[ "$TEST_QMD_CONFIG_DIR/index.yml" != "$GLOBAL_CONFIG_FILE" ]] || die "temporary and global config paths unexpectedly match"

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
    "$GLOBAL_INDEX" "$GLOBAL_INDEX-wal" "$GLOBAL_INDEX-shm" \
    "$GLOBAL_INDEX-journal" "$GLOBAL_CONFIG_FILE"
}

GLOBAL_BEFORE="$TEST_ROOT/global-before.json"
GLOBAL_AFTER="$TEST_ROOT/global-after.json"
snapshot_global_state "$GLOBAL_BEFORE"

run_qmd() {
  local qmd_env=("${QMD_BASE_ENV[@]}")
  if [[ -n "$ACTIVE_EMBED_MODEL" ]]; then
    qmd_env+=("QMD_EMBED_MODEL=$ACTIVE_EMBED_MODEL")
  fi
  log "qmd $*"
  env "${qmd_env[@]}" "$NODE" -e '
    const { spawnSync } = require("node:child_process");
    const timeout = Number(process.argv[1]);
    const executable = process.argv[2];
    const args = process.argv.slice(3);
    const result = spawnSync(executable, args, {
      env: process.env,
      stdio: "inherit",
      timeout,
      killSignal: "SIGKILL",
    });
    if (result.error) {
      if (result.error.code === "ETIMEDOUT") {
        console.error(`qmd command exceeded ${timeout}ms`);
        process.exit(124);
      }
      console.error(result.error.message || String(result.error));
      process.exit(125);
    }
    if (result.signal) {
      console.error(`qmd command ended by ${result.signal}`);
      process.exit(128);
    }
    process.exit(result.status == null ? 1 : result.status);
  ' "$QMD_COMMAND_TIMEOUT_MS" "$NODE" "$QMD_CLI" "$@"
}

NODE_VERSION="$("$NODE" --version)"
QMD_VERSION="$(env "${QMD_BASE_ENV[@]}" "$NODE" "$QMD_CLI" --version)"
log "runtime: $RUNTIME_DIR"
log "versions: Node $NODE_VERSION, $QMD_VERSION"
log "isolated index: $TEST_INDEX_PATH"

HELP_OUTPUT="$TEST_ROOT/help.txt"
env "${QMD_BASE_ENV[@]}" "$NODE" "$QMD_CLI" --help >"$HELP_OUTPUT"
grep -F -- "Index: $TEST_INDEX_PATH" "$HELP_OUTPUT" >/dev/null \
  || die "qmd did not report the isolated INDEX_PATH"

COLLECTION="dump-integration-smoke"
FIXTURE_DIR="$TEST_ROOT/fixture"
FIXTURE_FILE="$FIXTURE_DIR/consumer-smoke.md"
MARKER="dumpconsumerprobe7319"
printf '%s\n' \
  '# Dump consumer smoke fixture' \
  '' \
  'This file begins without the final verification marker.' \
  >"$FIXTURE_FILE"

FIXTURE_REAL="$(real_path "$FIXTURE_DIR")"
run_qmd collection add "$FIXTURE_REAL" --name "$COLLECTION"
printf '%s\n' '' "Updated consumer marker: $MARKER" >>"$FIXTURE_FILE"
run_qmd update

[[ -f "$TEST_INDEX_PATH" ]] || die "qmd did not create the isolated SQLite index"
[[ -f "$TEST_QMD_CONFIG_DIR/index.yml" ]] || die "qmd did not create the isolated collection config"
grep -F -- "$COLLECTION" "$TEST_QMD_CONFIG_DIR/index.yml" >/dev/null \
  || die "isolated config does not contain the smoke collection"
grep -F -- "$FIXTURE_REAL" "$TEST_QMD_CONFIG_DIR/index.yml" >/dev/null \
  || die "isolated config does not contain the fixture path"

find_cached_embed_model() {
  local candidate=""
  local directory=""
  if [[ -n "$EMBED_MODEL" ]]; then
    [[ -f "$EMBED_MODEL" ]] || die "embedding model not found: $EMBED_MODEL"
    resolve_path "$EMBED_MODEL"
    return
  fi
  if [[ -n "$ORIGINAL_EMBED_MODEL" && "$ORIGINAL_EMBED_MODEL" != hf:* && -f "$ORIGINAL_EMBED_MODEL" ]]; then
    resolve_path "$ORIGINAL_EMBED_MODEL"
    return
  fi
  for directory in "$RUNTIME_DIR/qmd/models" "$GLOBAL_CACHE_ROOT/qmd/models"; do
    [[ -d "$directory" ]] || continue
    candidate="$(find "$directory" -maxdepth 1 -type f -iname '*embeddinggemma*Q8_0.gguf' -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      resolve_path "$candidate"
      return
    fi
  done
}

EMBEDDED=0
if [[ "$SKIP_EMBED" == "0" ]]; then
  CACHED_EMBED_MODEL="$(find_cached_embed_model)"
  if [[ -n "$CACHED_EMBED_MODEL" ]]; then
    ACTIVE_EMBED_MODEL="$CACHED_EMBED_MODEL"
    log "embedding with cached read-only model: $CACHED_EMBED_MODEL"
    run_qmd embed --max-docs-per-batch 1 --max-batch-mb 1
    EMBEDDED=1
  elif [[ "$ALLOW_DOWNLOADS" == "1" ]]; then
    log "no cached model found; download is enabled for the disposable cache"
    run_qmd embed --max-docs-per-batch 1 --max-batch-mb 1
    EMBEDDED=1
  elif [[ "$REQUIRE_EMBED" == "1" ]]; then
    die "no cached embedding model found; pass --embed-model PATH or --allow-downloads"
  else
    log "no cached embedding model found; continuing with the no-download lexical smoke test"
  fi
else
  log "embedding skipped (--skip-embed)"
fi

if [[ -z "$PORT" ]]; then
  PORT="$("$NODE" -e '
    const net = require("node:net");
    const server = net.createServer();
    server.unref();
    server.listen(0, "localhost", () => {
      process.stdout.write(String(server.address().port));
      server.close();
    });
  ')"
fi
[[ "$PORT" =~ ^[0-9]+$ ]] || die "invalid port: $PORT"
[[ "$PORT" -ge 1024 && "$PORT" -le 65535 ]] || die "port must be between 1024 and 65535"

MCP_LOG="$TEST_ROOT/mcp.log"
log "starting owned MCP daemon on localhost:$PORT"
QMD_DAEMON_ENV=("${QMD_BASE_ENV[@]}")
if [[ -n "$ACTIVE_EMBED_MODEL" ]]; then
  QMD_DAEMON_ENV+=("QMD_EMBED_MODEL=$ACTIVE_EMBED_MODEL")
fi
env "${QMD_DAEMON_ENV[@]}" "$NODE" "$QMD_CLI" mcp --http --port "$PORT" >"$MCP_LOG" 2>&1 &
MCP_PID=$!

READY=0
ATTEMPTS=0
while [[ "$ATTEMPTS" -lt 120 ]]; do
  if ! kill -0 "$MCP_PID" >/dev/null 2>&1; then
    set +e
    wait "$MCP_PID"
    DAEMON_STATUS=$?
    set -e
    MCP_PID=""
    die "qmd daemon exited before becoming healthy (status $DAEMON_STATUS)"
  fi
  if daemon_pid_matches "$MCP_PID" && daemon_owns_listener "$MCP_PID" &&
     curl --silent --show-error --max-time 1 --noproxy localhost "http://localhost:$PORT/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.25
  ATTEMPTS=$((ATTEMPTS + 1))
done
[[ "$READY" == "1" ]] || die "qmd daemon did not become healthy within 30 seconds"

post_mcp() {
  local request_file="$1"
  local response_file="$2"
  local headers_file="$3"
  local with_session="$4"
  local status=""
  local curl_args=(
    --silent --show-error --connect-timeout 2 --max-time 60
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
    curl_args+=(--header "Mcp-Session-Id: $SESSION_ID")
  fi
  if ! status="$(curl "${curl_args[@]}" "http://localhost:$PORT/mcp")"; then
    die "MCP request failed: $request_file"
  fi
  case "$status" in
    2??) ;;
    *)
      sed -n '1,80p' "$response_file" >&2 || true
      die "MCP request returned HTTP $status"
      ;;
  esac
}

INIT_REQUEST="$TEST_ROOT/initialize-request.json"
INIT_RESPONSE="$TEST_ROOT/initialize-response.json"
INIT_HEADERS="$TEST_ROOT/initialize-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"dump-qmd-integration","version":"1.0"}}}' >"$INIT_REQUEST"
post_mcp "$INIT_REQUEST" "$INIT_RESPONSE" "$INIT_HEADERS" 0
"$NODE" -e '
  const response = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (response.error) throw new Error(`initialize failed: ${JSON.stringify(response.error)}`);
  if (!response.result || !response.result.serverInfo) throw new Error("initialize response is missing serverInfo");
' "$INIT_RESPONSE"
SESSION_ID="$(tr -d '\r' <"$INIT_HEADERS" | awk 'tolower($1) == "mcp-session-id:" { print $2; exit }')"
[[ -n "$SESSION_ID" ]] || die "initialize did not return Mcp-Session-Id"

NOTIFY_REQUEST="$TEST_ROOT/initialized-request.json"
NOTIFY_RESPONSE="$TEST_ROOT/initialized-response.txt"
NOTIFY_HEADERS="$TEST_ROOT/initialized-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >"$NOTIFY_REQUEST"
post_mcp "$NOTIFY_REQUEST" "$NOTIFY_RESPONSE" "$NOTIFY_HEADERS" 1

STATUS_REQUEST="$TEST_ROOT/status-request.json"
STATUS_RESPONSE="$TEST_ROOT/status-response.json"
STATUS_HEADERS="$TEST_ROOT/status-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":"status-1","method":"tools/call","params":{"name":"status","arguments":{}}}' >"$STATUS_REQUEST"
post_mcp "$STATUS_REQUEST" "$STATUS_RESPONSE" "$STATUS_HEADERS" 1
"$NODE" -e '
  const fs = require("node:fs");
  const response = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (response.error) throw new Error(`status failed: ${JSON.stringify(response.error)}`);
  const status = response.result && response.result.structuredContent;
  if (!status) throw new Error("status returned no structuredContent");
  if (status.totalDocuments !== 1) throw new Error(`expected 1 isolated document, got ${status.totalDocuments}`);
  if (!Array.isArray(status.collections) || status.collections.length !== 1) throw new Error("expected exactly one isolated collection");
  const collection = status.collections[0];
  if (collection.name !== process.argv[2]) throw new Error(`unexpected collection: ${collection.name}`);
  if (collection.path !== process.argv[3]) throw new Error(`unexpected collection path: ${collection.path}`);
  const embedded = process.argv[4] === "1";
  if (embedded && (!status.hasVectorIndex || status.needsEmbedding !== 0)) {
    throw new Error("embed completed but MCP status does not report a current vector index");
  }
' "$STATUS_RESPONSE" "$COLLECTION" "$FIXTURE_REAL" "$EMBEDDED"

QUERY_REQUEST="$TEST_ROOT/query-request.json"
QUERY_RESPONSE="$TEST_ROOT/query-response.json"
QUERY_HEADERS="$TEST_ROOT/query-headers.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":"query-1","method":"tools/call","params":{"name":"query","arguments":{"searches":[{"type":"lex","query":"dumpconsumerprobe7319"}],"collections":["dump-integration-smoke"],"limit":5,"minScore":0,"rerank":false}}}' >"$QUERY_REQUEST"
post_mcp "$QUERY_REQUEST" "$QUERY_RESPONSE" "$QUERY_HEADERS" 1
HIT_FILE="$("$NODE" -e '
  const response = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (response.error) throw new Error(`query failed: ${JSON.stringify(response.error)}`);
  const results = response.result && response.result.structuredContent && response.result.structuredContent.results;
  if (!Array.isArray(results)) throw new Error("query returned no structured results");
  const hit = results.find((item) => typeof item.file === "string" && (item.file === "consumer-smoke.md" || item.file.endsWith("/consumer-smoke.md")));
  if (!hit) throw new Error(`fixture missing from query results: ${JSON.stringify(results)}`);
  process.stdout.write(hit.file);
' "$QUERY_RESPONSE")"

if [[ "$EMBEDDED" == "1" ]]; then
  VECTOR_REQUEST="$TEST_ROOT/vector-query-request.json"
  VECTOR_RESPONSE="$TEST_ROOT/vector-query-response.json"
  VECTOR_HEADERS="$TEST_ROOT/vector-query-headers.txt"
  printf '%s\n' '{"jsonrpc":"2.0","id":"query-vector-1","method":"tools/call","params":{"name":"query","arguments":{"searches":[{"type":"vec","query":"Find the Dump consumer smoke fixture with the updated verification marker."}],"collections":["dump-integration-smoke"],"limit":5,"minScore":0,"rerank":false}}}' >"$VECTOR_REQUEST"
  post_mcp "$VECTOR_REQUEST" "$VECTOR_RESPONSE" "$VECTOR_HEADERS" 1
  "$NODE" -e '
    const response = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    if (response.error) throw new Error(`vector query failed: ${JSON.stringify(response.error)}`);
    const results = response.result && response.result.structuredContent && response.result.structuredContent.results;
    if (!Array.isArray(results)) throw new Error("vector query returned no structured results");
    const hit = results.find((item) => typeof item.file === "string" && (item.file === "consumer-smoke.md" || item.file.endsWith("/consumer-smoke.md")));
    if (!hit) throw new Error(`fixture missing from vector-only query results: ${JSON.stringify(results)}`);
  ' "$VECTOR_RESPONSE"
fi

GET_REQUEST="$TEST_ROOT/get-request.json"
GET_RESPONSE="$TEST_ROOT/get-response.json"
GET_HEADERS="$TEST_ROOT/get-headers.txt"
"$NODE" -e '
  const fs = require("node:fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    jsonrpc: "2.0", id: "get-1", method: "tools/call",
    params: { name: "get", arguments: { file: process.argv[2] } }
  }));
' "$GET_REQUEST" "$HIT_FILE"
post_mcp "$GET_REQUEST" "$GET_RESPONSE" "$GET_HEADERS" 1
"$NODE" -e '
  const response = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (response.error) throw new Error(`get failed: ${JSON.stringify(response.error)}`);
  const blocks = response.result && response.result.content;
  const text = Array.isArray(blocks) ? blocks.map((item) => item.text || (item.resource && item.resource.text) || "").join("\n") : "";
  if (!text.includes(process.argv[2])) throw new Error("retrieved fixture is missing the post-update marker");
' "$GET_RESPONSE" "$MARKER"

# Close only this MCP session, then stop only the foreground child we launched.
curl --silent --show-error --max-time 5 --noproxy localhost --request DELETE \
  --header "Mcp-Session-Id: $SESSION_ID" \
  "http://localhost:$PORT/mcp" >/dev/null || true
if ! stop_daemon; then
  die "owned qmd daemon did not terminate cleanly after SIGTERM"
fi

snapshot_global_state "$GLOBAL_AFTER"
if ! cmp -s "$GLOBAL_BEFORE" "$GLOBAL_AFTER"; then
  "$NODE" -e '
    const fs = require("node:fs");
    const before = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const after = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    for (const path of Object.keys(before)) {
      if (JSON.stringify(before[path]) !== JSON.stringify(after[path])) console.error(`global qmd path changed: ${path}`);
    }
  ' "$GLOBAL_BEFORE" "$GLOBAL_AFTER"
  die "global qmd config/index changed during the isolated smoke test (stop any regular Dump/qmd activity and retry)"
fi

if [[ "$EMBEDDED" == "1" ]]; then
  log "PASS: isolated add/update/embed + MCP initialize/query/get succeeded"
else
  log "PASS: isolated add/update + MCP initialize/query/get succeeded (embedding skipped)"
fi
