#!/bin/bash
# Lifecycle tests for bootstrap.sh, run on this machine rather than in a sandbox.
#
# Needs no secrets: Kimi Code answers its health endpoint without contacting the
# model, so LLM_BASE_URL can point nowhere. Needs network to download Kimi Code.
#
#   test/lifecycle.sh            run every case
#   test/lifecycle.sh happy      run one case
#
# Each case gets its own $HOME, log root and ports, and only ever signals the
# processes it started.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/bootstrap.sh"
WORK=$(mktemp -d)
KIMI_VERSION="${KIMI_VERSION:-2.3.0}"
FAILURES=0
BOOT_PID=

# Kimi Code is shared across cases so it downloads once.
SHARED_KIMI="$WORK/kimi-cache"

cleanup() {
  [ -n "$BOOT_PID" ] && kill -TERM "$BOOT_PID" 2>/dev/null
  [ -n "${SQUATTER_PID:-}" ] && kill "$SQUATTER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "  ok    $*"; }
flunk() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }
check() { # check <description> <command...>
  local what=$1
  shift
  if "$@"; then pass "$what"; else flunk "$what"; fi
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# boot <case> [extra env...]: starts bootstrap.sh in the background with an
# isolated home, and sets STATUS / HEALTH / LOG / AGENT_PORT for the case.
boot() {
  local name=$1
  shift
  CASE_DIR="$WORK/$name"
  mkdir -p "$CASE_DIR/home/.kimi-code"
  [ -d "$SHARED_KIMI/bin" ] && cp -r "$SHARED_KIMI/bin" "$CASE_DIR/home/.kimi-code/"
  AGENT_PORT=$(free_port)
  LOG_PORT=$(free_port)
  STATUS="$CASE_DIR/logs/s/status.json"
  HEALTH="$CASE_DIR/logs/s/health.json"
  LOG="$CASE_DIR/logs/s/setup.log"
  env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$CASE_DIR/home" \
    LOG_ROOT="$CASE_DIR/logs" LOG_PATH_SECRET=s \
    AGENT_PORT="$AGENT_PORT" LOG_PORT="$LOG_PORT" \
    LLM_BASE_URL=http://127.0.0.1:9 LLM_API_KEY=test-llm-key AGENT_TOKEN=test-agent-token \
    KIMI_VERSION="$KIMI_VERSION" INSTALL_SKILLS=0 INSTALL_MCP=0 INSTALL_RUNPODCTL=0 \
    HEARTBEAT_SECONDS=1 READY_TIMEOUT_SECONDS=30 AGENT_MAX_RESTARTS=1 FAIL_LINGER_SECONDS=30 \
    "$@" bash "$SCRIPT" >/dev/null 2>&1 &
  BOOT_PID=$!
}

state() { sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$STATUS" 2>/dev/null; }

# await_state <state> <seconds>
await_state() {
  local deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(state)" = "$1" ] && return 0
    sleep 0.5
  done
  echo "    (state is '$(state)', wanted '$1'; last log lines:)"
  tail -5 "$LOG" 2>/dev/null | sed 's/^/      /'
  return 1
}

finish() { # stop the case's bootstrap and wait for it
  [ -n "$BOOT_PID" ] && kill -TERM "$BOOT_PID" 2>/dev/null && wait "$BOOT_PID" 2>/dev/null
  BOOT_PID=
}

agent_pid() { pgrep -P "$BOOT_PID" -x kimi-code; }
healthz() { curl -fs -o /dev/null --max-time 5 "http://127.0.0.1:$AGENT_PORT/api/v1/healthz" -H "Authorization: Bearer test-agent-token"; }
served() { curl -fs --max-time 5 -o /dev/null "http://127.0.0.1:$LOG_PORT/s/$1"; }
state_is() { [ "$(state)" = "$1" ]; }
log_lacks() { ! grep -qF "$1" "$LOG"; }
agent_down() { ! healthz; }
log_server_down() { ! curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:$LOG_PORT/"; }
all_served() { served status.json && served health.json && served setup.log; }
secrets_private() {
  [ "$(stat -c %a "$CASE_DIR"/home/.kimi-code/{config.toml,mcp.json,server.token} | sort -u)" = 600 ]
}

# ---------- Cases ----------

case_missing_env() {
  echo "missing required env"
  boot missing_env LLM_API_KEY=
  check "reports failed" await_state failed 15
  check "names the missing variable" grep -q 'LLM_API_KEY is required' "$STATUS"
  check "status is served over HTTP while it lingers" served status.json
  finish
  check "SIGTERM during the linger stops the log server" log_server_down
}

case_happy() {
  echo "happy path"
  local hook
  # shellcheck disable=SC2016 # the hook's own code, expanded inside the sandbox
  hook=$(printf '%s\n' 'echo "hook-cwd=$PWD"' '[ -z "${LLM_API_KEY:-}${AGENT_TOKEN:-}" ] && echo hook-sees-no-secrets' | base64 -w0)
  boot happy SETUP_HOOK_B64="$hook"
  check "becomes ready" await_state ready 120
  # Seed the shared cache so later cases skip the download.
  [ -d "$SHARED_KIMI/bin" ] || { mkdir -p "$SHARED_KIMI" && cp -r "$CASE_DIR/home/.kimi-code/bin" "$SHARED_KIMI/"; }
  check "answers healthz on the requested port" healthz
  sleep 2
  check "heartbeat reports healthy" grep -q '"healthy":true' "$HEALTH"
  check "status, health and log are served over HTTP" all_served
  check "bearer token never reaches the log" log_lacks test-agent-token
  check "LLM key never reaches the log" log_lacks test-llm-key
  check "secrets are written 0600" secrets_private
  check "MCP server is present but disabled without RUNPOD_API_KEY" grep -q '"enabled": false' "$CASE_DIR/home/.kimi-code/mcp.json"
  check "setup hook ran in the workdir" grep -q "hook-cwd=$CASE_DIR/home/workspace" "$LOG"
  check "setup hook cannot see secrets" grep -q hook-sees-no-secrets "$LOG"
  check "AGENTS.md is written" test -s "$CASE_DIR/home/workspace/AGENTS.md"

  echo "crash and restart"
  kill -9 "$(agent_pid)"
  check "reports restarting" await_state restarting 10
  check "comes back ready" await_state ready 40
  check "counts the restart" grep -q '"restarts":1' "$STATUS"
  check "answers healthz after the restart" healthz

  echo "SIGTERM"
  local pid=$BOOT_PID
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  BOOT_PID=
  check "reports stopped" state_is stopped
  check "releases the agent port" agent_down
  check "stops the log server" log_server_down
}

case_custom_agents_md() {
  echo "custom AGENTS.md"
  boot agents_md AGENTS_MD_B64="$(printf '# custom instructions\n' | base64 -w0)"
  check "becomes ready" await_state ready 60
  check "uses the supplied AGENTS.md" grep -qx '# custom instructions' "$CASE_DIR/home/workspace/AGENTS.md"
  finish
}

case_port_busy() {
  echo "agent port already taken"
  # Kimi Code would silently move to another port here; the script must refuse.
  local port
  port=$(free_port)
  python3 -m http.server "$port" --bind 0.0.0.0 >/dev/null 2>&1 &
  SQUATTER_PID=$!
  sleep 1
  boot port_busy AGENT_PORT="$port"
  AGENT_PORT=$port
  check "reports failed" await_state failed 60
  check "says the port is in use" grep -q "port $port is already in use" "$STATUS"
  finish
  kill "$SQUATTER_PID" 2>/dev/null
  SQUATTER_PID=
}

case_crash_loop() {
  echo "crash loop gives up"
  boot crash_loop
  await_state ready 60 || { flunk "never became ready"; finish; return; }
  kill -9 "$(agent_pid)"
  # Wait for the supervisor to notice; right after the kill the state still reads ready.
  await_state restarting 10 >/dev/null && await_state ready 40 >/dev/null
  kill -9 "$(agent_pid)"
  check "reports failed after AGENT_MAX_RESTARTS" await_state failed 20
  check "says it gave up" grep -q 'gave up after 1 restarts' "$STATUS"
  finish
}

# ---------- Run ----------

CASES=(happy missing_env custom_agents_md port_busy crash_loop)
[ $# -gt 0 ] && CASES=("$@")
for c in "${CASES[@]}"; do
  "case_$c"
  finish
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES check(s) failed"
  exit 1
fi
