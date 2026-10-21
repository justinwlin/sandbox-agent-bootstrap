#!/bin/bash
# Bootstraps the Kimi Code agent inside a Runpod Sandbox and keeps it running.
#
# Sandbox images run as an unprivileged user with no root, no apt and no sshd,
# so everything installs under $HOME and this script arrives as the container's
# entrypoint rather than being copied in. See README.md for the full contract.
#
# Ports the sandbox must publish:
#   AGENT_PORT/http   Kimi Code's web UI and REST/WebSocket API, bearer-authenticated
#   LOG_PORT/http     /<LOG_PATH_SECRET>/{setup.log,status.json,health.json}
#
# Required env: LLM_BASE_URL, LLM_API_KEY, AGENT_TOKEN, LOG_PATH_SECRET.
# Everything else is optional; the defaults live in the "Configuration" block.
#
# Secrets are read from the environment, written to 0600 files, and then unset,
# so neither the agent's shell nor a setup hook can read them back out.

set -uo pipefail

# ---------- Configuration ----------

: "${LOG_PATH_SECRET:?LOG_PATH_SECRET is required}"
AGENT_PORT="${AGENT_PORT:-8080}"
LOG_PORT="${LOG_PORT:-8081}"
AGENT_TITLE="${AGENT_TITLE:-Sandbox agent}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-.proxy.runpod.net,.dev-proxy.runpod.net}"

KIMI_VERSION="${KIMI_VERSION:-}"                  # empty = latest
MCP_VERSION="${MCP_VERSION:-latest}"
RUNPODCTL_VERSION="${RUNPODCTL_VERSION:-latest}"

INSTALL_SKILLS="${INSTALL_SKILLS:-1}"
# auto = install when RUNPOD_API_KEY is set, since neither is useful without it.
INSTALL_MCP="${INSTALL_MCP:-auto}"
INSTALL_RUNPODCTL="${INSTALL_RUNPODCTL:-auto}"
SKILLS_REPO="${SKILLS_REPO:-https://github.com/runpod/runpod-plugins-official}"

AGENT_MAX_RESTARTS="${AGENT_MAX_RESTARTS:-5}"
HEARTBEAT_SECONDS="${HEARTBEAT_SECONDS:-15}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-60}"
# info logs every heartbeat probe into a public log; this script's own lines
# already cover the lifecycle.
AGENT_LOG_LEVEL="${AGENT_LOG_LEVEL:-warn}"

export HOME="${HOME:-/home/$(whoami)}"
export KIMI_CODE_HOME="$HOME/.kimi-code"
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PATH="$KIMI_CODE_HOME/bin:$NPM_CONFIG_PREFIX/bin:$HOME/.local/bin:$PATH"
WORKDIR="${WORKDIR:-$HOME/workspace}"

PUB="${LOG_ROOT:-/tmp/pub}"
LOGDIR="$PUB/$LOG_PATH_SECRET"
LOG="$LOGDIR/setup.log"
STATUS="$LOGDIR/status.json"
HEALTH="$LOGDIR/health.json"

# ---------- Logging and status ----------

mkdir -p "$LOGDIR" "$WORKDIR" "$KIMI_CODE_HOME" "$HOME/.agents/skills"

# Served before anything else, so a caller can watch a boot that fails early.
python3 -m http.server "$LOG_PORT" --bind 0.0.0.0 --directory "$PUB" >/dev/null 2>&1 &
LOG_SERVER_PID=$!
# Also to stdout: that is what the platform's /v2/sandboxes/{id}/logs streams,
# which gives an authenticated copy of this log alongside the public one.
exec > >(tee -a "$LOG") 2>&1

now() { date -u +%FT%TZ; }
json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# Written to a temp file and renamed, so a poller never reads half a document.
write_json() {
  printf '%s\n' "$2" >"$1.tmp" && mv -f "$1.tmp" "$1"
}

RESTARTS=0
# status.json is the lifecycle: installing -> ready, or restarting / failed.
# It tells a slow boot from a dead one, which the agent's health endpoint cannot.
status() {
  write_json "$STATUS" "{\"state\":$(json_str "$1"),\"step\":$(json_str "$2"),\"restarts\":$RESTARTS,\"at\":\"$(now)\"}"
}
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
step() { log "$*"; status installing "$*"; }
# Exiting would end PID 1 and take the log server with it, leaving nobody able
# to read why the boot failed. Linger instead; the sandbox's idle timeout reaps it.
fail() {
  log "FAILED: $*"
  status failed "$*"
  sleep "${FAIL_LINGER_SECONDS:-900}"
  exit 1
}

# Missing variables are reported in status.json, not only on stderr.
for var in LLM_BASE_URL LLM_API_KEY AGENT_TOKEN; do
  [ -n "${!var:-}" ] || fail "$var is required"
done

wants() { # wants <setting>: is a 1 / auto(RUNPOD_API_KEY) toggle on?
  case "$1" in
    1 | true | yes) return 0 ;;
    auto) [ -n "${RUNPOD_API_KEY:-}" ] ;;
    *) return 1 ;;
  esac
}

# ---------- Install ----------

step "user=$(whoami) uid=$(id -u) home=$HOME"
# shellcheck source=/dev/null
step "os: $(. /etc/os-release && echo "$PRETTY_NAME"), kernel: $(uname -r), cpus: $(nproc)"
step "tools: python $(python3 --version 2>&1 | cut -d' ' -f2), node $(node --version 2>/dev/null), uv $(uv --version 2>/dev/null | cut -d' ' -f2)"

# installed <command> <wanted version, empty or "latest" for any>: lets an image
# that already carries the tools skip the downloads and only write config.
installed() {
  command -v "$1" >/dev/null || return 1
  case "$2" in "" | latest) return 0 ;; esac
  "$1" --version 2>&1 | grep -qF "$2"
}

if installed kimi "$KIMI_VERSION"; then
  step "kimi $(kimi --version 2>&1) already installed"
else
  step "installing Kimi Code ${KIMI_VERSION:-latest}"
  curl -fsSL https://code.kimi.com/kimi-code/install.sh |
    KIMI_NO_MODIFY_PATH=1 KIMI_VERSION="$KIMI_VERSION" bash || fail "Kimi Code install"
  command -v kimi >/dev/null || fail "kimi is not on PATH after install"
  step "kimi $(kimi --version 2>&1)"
fi

if wants "$INSTALL_SKILLS"; then
  step "installing agent skills from $SKILLS_REPO"
  if git clone -q --depth 1 "$SKILLS_REPO" /tmp/agent-skills; then
    # Plugin repos nest skills at different depths; take every skills/ directory.
    while IFS= read -r dir; do
      cp -r "$dir"/. "$HOME/.agents/skills/"
    done < <(find /tmp/agent-skills -type d -name skills -not -path '*/.git/*')
    step "skills: $(find "$HOME/.agents/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tr '\n' ' ')"
  else
    log "skills: could not clone $SKILLS_REPO, continuing without them"
  fi
fi

if wants "$INSTALL_MCP"; then
  if installed runpod-mcp "$MCP_VERSION"; then
    step "runpod-mcp already installed"
  else
    step "installing @runpod/mcp-server@$MCP_VERSION"
    npm install -g --silent "@runpod/mcp-server@$MCP_VERSION" || fail "@runpod/mcp-server install"
  fi
fi

if wants "$INSTALL_RUNPODCTL" && installed runpodctl "$RUNPODCTL_VERSION"; then
  step "runpodctl already installed"
elif wants "$INSTALL_RUNPODCTL"; then
  step "installing runpodctl $RUNPODCTL_VERSION"
  if [ "$RUNPODCTL_VERSION" = latest ]; then
    url="https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-linux-amd64"
  else
    url="https://github.com/runpod/runpodctl/releases/download/$RUNPODCTL_VERSION/runpodctl-linux-amd64"
  fi
  mkdir -p "$HOME/.local/bin"
  if curl -fsSL "$url" -o "$HOME/.local/bin/runpodctl" && chmod +x "$HOME/.local/bin/runpodctl"; then
    step "runpodctl $(runpodctl version 2>&1 | head -1)"
  else
    log "runpodctl: download failed, continuing without it"
  fi
fi

# ---------- Configure ----------

step "writing agent config"
python3 - <<'PY' || fail "writing agent config"
import json, os

home = os.environ["KIMI_CODE_HOME"]
efforts = [e.strip() for e in os.environ.get("LLM_EFFORTS", "low,high,max").split(",") if e.strip()]

# json.dumps yields valid TOML basic strings for these values.
config = f'''default_model = "agent/default"
default_permission_mode = {json.dumps(os.environ.get("PERMISSION_MODE", "yolo"))}
telemetry = false
auto_session_title = true

[providers.llm]
type = "openai"
base_url = {json.dumps(os.environ["LLM_BASE_URL"].rstrip("/") + "/v1")}
api_key = {json.dumps(os.environ["LLM_API_KEY"])}

[models."agent/default"]
provider = "llm"
model = {json.dumps(os.environ.get("LLM_MODEL", "moonshotai/Kimi-K3"))}
max_context_size = {int(os.environ.get("LLM_CONTEXT", "262144"))}
capabilities = ["thinking", "always_thinking", "tool_use"]
display_name = {json.dumps(os.environ.get("AGENT_TITLE", "Sandbox agent"))}
# Some models reject the CLI's default "medium" effort with a 400, so the set is explicit.
support_efforts = {json.dumps(efforts)}
default_effort = {json.dumps(os.environ.get("LLM_EFFORT", "high"))}
'''

mcp = {"mcpServers": {"runpod": {"command": "runpod-mcp", "args": []}}}
if os.environ.get("RUNPOD_API_KEY"):
    env = {"RUNPOD_API_KEY": os.environ["RUNPOD_API_KEY"]}
    env.update(json.loads(os.environ.get("MCP_ENV_JSON") or "{}"))
    mcp["mcpServers"]["runpod"]["env"] = env
else:
    # Present but disabled, so a caller can enable it later through the agent's API.
    mcp["mcpServers"]["runpod"]["enabled"] = False

files = (
    ("config.toml", config),
    ("mcp.json", json.dumps(mcp, indent=2)),
    # Pre-seeded rather than generated, so the caller already knows the token.
    ("server.token", os.environ["AGENT_TOKEN"]),
)
for name, body in files:
    path = os.path.join(home, name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(body)
PY
log "runpod mcp: $([ -n "${RUNPOD_API_KEY:-}" ] && echo enabled || echo 'disabled (no RUNPOD_API_KEY)')"

if [ -n "${AGENTS_MD_B64:-}" ]; then
  base64 -d <<<"$AGENTS_MD_B64" >"$WORKDIR/AGENTS.md" || fail "decoding AGENTS_MD_B64"
elif [ ! -f "$WORKDIR/AGENTS.md" ]; then
  cat >"$WORKDIR/AGENTS.md" <<'MD'
# Sandbox workspace

You are running inside a Runpod Sandbox: a gVisor-isolated CPU container with no root, no
apt, no Docker and no GPU. Python (uv), Node and build tools are installed. Install Python
packages with `uv pip install --user` or a venv, and Node packages locally.

- Agent skills are in ~/.agents/skills. Load the relevant one before starting a task it covers.
- For anything that takes more than a minute, run it as a background task and check on it.
- Never print secrets from the environment or from ~/.kimi-code.
MD
fi

# From here the keys exist only in the 0600 config files.
unset LLM_API_KEY AGENT_TOKEN RUNPOD_API_KEY MCP_ENV_JSON BOOTSTRAP_B64

# Runs after the unset on purpose: a hook's output lands in the public log.
if [ -n "${SETUP_HOOK_B64:-}" ]; then
  step "running setup hook"
  (cd "$WORKDIR" && base64 -d <<<"$SETUP_HOOK_B64" | bash) || fail "setup hook exited non-zero"
fi
unset SETUP_HOOK_B64 AGENTS_MD_B64

# ---------- Run ----------

export KIMI_CODE_ALLOWED_HOSTS="$ALLOWED_HOSTS"
export KIMI_CODE_TRUST_WORKSPACE=1 KIMI_DISABLE_TELEMETRY=1
export KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT=1 KIMI_CODE_BACKGROUND_BASH_TASK_TIMEOUT_S=0

# One probe for both the readiness gate and the heartbeat: the agent answers
# healthz on the port it was asked for, which is the only port the sandbox publishes.
probe() {
  curl -fs --max-time 5 -o /dev/null "http://127.0.0.1:$AGENT_PORT/api/v1/healthz" \
    -H "Authorization: Bearer $(cat "$KIMI_CODE_HOME/server.token")" 2>/dev/null
}

# health.json is liveness, separate from the lifecycle in status.json, so a
# monitor can see an agent that booted fine but has since stopped answering.
heartbeat() {
  local healthy_at=null ok
  while sleep "$HEARTBEAT_SECONDS"; do
    if probe; then ok=true healthy_at="\"$(now)\""; else ok=false; fi
    write_json "$HEALTH" "{\"healthy\":$ok,\"healthy_at\":$healthy_at,\"checked_at\":\"$(now)\"}"
  done
}

# Kimi Code binds a higher port, still logging "server ready", when the one it
# was given is taken. In a sandbox that port is unpublished, so refuse to start.
port_free() {
  python3 -c 'import socket,sys; socket.socket().bind(("0.0.0.0", int(sys.argv[1])))' "$1" 2>/dev/null
}
[ "$AGENT_PORT" != "$LOG_PORT" ] || fail "AGENT_PORT and LOG_PORT are both $AGENT_PORT"
port_free "$AGENT_PORT" || fail "port $AGENT_PORT is already in use"

# Ready means answering, not launched; a start that never answers counts as a crash.
await_ready() {
  local deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    kill -0 "$AGENT_PID" 2>/dev/null || return 1
    probe && return 0
    sleep 1
  done
  return 1
}

heartbeat &
HEARTBEAT_PID=$!

# The startup banner echoes the bearer token, and this log is reachable over HTTP.
redact() { sed -u -E 's/(token=)[A-Za-z0-9_-]+/\1<redacted>/g'; }

# This shell stays PID 1 instead of exec'ing the agent: it reaps the agent's
# orphaned background tasks, forwards SIGTERM, and restarts a crashed agent.
AGENT_PID=
stop_agent() {
  [ -n "$AGENT_PID" ] && kill -TERM "$AGENT_PID" 2>/dev/null && wait "$AGENT_PID"
  AGENT_PID=
}
shutdown() {
  log "stopping"
  stop_agent
  kill "$HEARTBEAT_PID" "$LOG_SERVER_PID" 2>/dev/null
  status stopped "received SIGTERM"
  exit 0
}
trap shutdown TERM INT

cd "$WORKDIR" || fail "cannot enter $WORKDIR"
while :; do
  log "starting the agent on :$AGENT_PORT"
  kimi web --host 0.0.0.0 --port "$AGENT_PORT" --no-open --log-level "$AGENT_LOG_LEVEL" \
    --web-title "$AGENT_TITLE" > >(redact) 2>&1 &
  AGENT_PID=$!

  if await_ready; then
    log "agent is answering on :$AGENT_PORT"
    status ready "serving on :$AGENT_PORT"
    wait "$AGENT_PID"
    reason="agent exited with code $?"
  else
    reason="agent did not answer on :$AGENT_PORT within ${READY_TIMEOUT_SECONDS}s"
  fi
  stop_agent

  RESTARTS=$((RESTARTS + 1))
  if [ "$RESTARTS" -gt "$AGENT_MAX_RESTARTS" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null
    fail "$reason; gave up after $AGENT_MAX_RESTARTS restarts"
  fi
  backoff=$((RESTARTS * 2))
  log "$reason; restart $RESTARTS/$AGENT_MAX_RESTARTS in ${backoff}s"
  status restarting "$reason"
  sleep "$backoff"
done
