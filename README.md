# sandbox-agent-bootstrap

Runs the [Kimi Code](https://code.kimi.com) agent inside a [Runpod Sandbox](https://docs.runpod.io), reachable over HTTP, and keeps it running.

A sandbox has no root, no `apt` and no sshd, so there is nothing to `scp` a setup script into and no package manager to install with. `bootstrap.sh` works within those limits: it installs everything under `$HOME`, arrives as the container's entrypoint rather than being copied in, and then supervises the agent.

## What you get

- Kimi Code's web UI and its REST + WebSocket API on a bearer-authenticated `/http` port.
- Agent skills, and optionally the [Runpod MCP server](https://www.npmjs.com/package/@runpod/mcp-server) and `runpodctl`, so the agent can manage pods, endpoints, templates and volumes.
- A supervisor that restarts a crashed agent, forwards `SIGTERM` for a clean shutdown, and publishes machine-readable **status** and **health** documents a monitor can poll.

Measured on Runpod: the sandbox is allocated in ~25 seconds and the script finishes in ~10 more.

## Quick start

```bash
export RUNPOD_API_KEY=...                      # creates the sandbox
export LLM_BASE_URL=https://your-openai-compatible-host LLM_API_KEY=...

python3 examples/create_sandbox.py --ref <commit-sha>              # fetch bootstrap.sh at boot
python3 examples/create_sandbox.py --inline bootstrap.sh           # or ship it in the request
python3 examples/create_sandbox.py --ref <commit-sha> --with-mcp   # give the agent the Runpod MCP server
python3 examples/create_sandbox.py --terminate <sandbox-id>
```

It waits until the agent answers, then prints the agent URL, its token, and the status, health and log URLs. The example is standard-library Python; read it for the exact `createSandbox` call.

## How it works

Create the sandbox through **GraphQL** `createSandbox` — `POST /v2/sandboxes` accepts no `ports` and no `dockerArgs`, and this needs both. Publish two ports and set the entrypoint to fetch and run the script:

```json
{
  "ports": "8080/http,8081/http",
  "dockerArgs": "{\"entrypoint\":[\"bash\",\"-c\"],\"cmd\":[\"curl -fsSL https://raw.githubusercontent.com/justinwlin/sandbox-agent-bootstrap/<sha>/bootstrap.sh -o /tmp/bootstrap.sh && exec bash /tmp/bootstrap.sh\"]}",
  "env": [
    {"key": "LLM_BASE_URL",    "value": "https://your-openai-compatible-host"},
    {"key": "LLM_API_KEY",     "value": "..."},
    {"key": "AGENT_TOKEN",     "value": "<random>"},
    {"key": "LOG_PATH_SECRET", "value": "<random>"}
  ]
}
```

To avoid depending on GitHub at boot, base64 the script into `BOOTSTRAP_B64` and use `echo "$BOOTSTRAP_B64" | base64 -d > /tmp/bootstrap.sh && exec bash /tmp/bootstrap.sh` instead. You get no network fetch, and exactly the bytes you reviewed.

**The proxy hostname uses the sandbox's `pod.id`, not the sandbox id.** `https://<pod-id>-8080.proxy.runpod.net` reaches the agent; the sandbox id in that position just 404s. On Runpod's dev environment the host is `dev-proxy.runpod.net`.

## Talking to the agent

`--prompt` on the example runs one prompt end to end and prints the reply and the tools the agent called:

```bash
python3 examples/create_sandbox.py --ref <sha> --with-mcp \
  --prompt "Using the Runpod MCP tools, count my serverless endpoints and templates."
```

To drive the API yourself, every request carries `Authorization: Bearer $AGENT_TOKEN`, and every response is enveloped as `{"code": 0, "msg": "success", "data": {...}}`. The sequence:

1. `POST /api/v1/sessions` with `{"metadata": {"cwd": "/home/user/workspace"}}`.
2. `POST /api/v1/sessions/{id}/profile` with `{"agent_config": {"model": "agent/default", "thinking": "high", "permission_mode": "yolo"}}`.
3. `POST /api/v1/sessions/{id}/prompts` with `{"model": "agent/default", "content": [{"type": "text", "text": "..."}]}`.
4. Wait for the turn. `GET /api/v1/sessions/{id}` reports `busy` and `main_turn_active`; for streaming, subscribe on the `/api/v1/ws` WebSocket and wait for `prompt.completed`.
5. `GET /api/v1/sessions/{id}/messages` — newest first. Assistant messages carry `text` and `tool_use` parts.

**Skip step 2 and every prompt fails with `model.not_configured: Model not set`.** Kimi Code applies `config.toml`'s `default_model` to its own UI, not to sessions created over the API. `agent/default` is the name `bootstrap.sh` registers the model under.

## Monitoring

Two documents under the log port, deliberately separate:

| URL | Answers | Shape |
| --- | --- | --- |
| `/<LOG_PATH_SECRET>/status.json` | Where is it in its lifecycle? | `{"state", "step", "restarts", "at"}` |
| `/<LOG_PATH_SECRET>/health.json` | Is the agent answering right now? | `{"healthy", "healthy_at", "checked_at"}` |
| `/<LOG_PATH_SECRET>/setup.log` | What happened? | text |

`state` moves `installing` → `ready`, and can then become `restarting`, `failed` or `stopped`. **`ready` means the agent answered its health endpoint on the expected port, not merely that it was launched.** `health.json` is refreshed every `HEARTBEAT_SECONDS` and catches an agent that booted fine but later stopped answering — `status.json` alone would still say `ready`.

Both are written atomically, so a poller never reads half a document.

On a boot failure the script does not exit: exiting would end the container and take the log server with it. It writes `failed` with the reason and lingers for `FAIL_LINGER_SECONDS` so you can read why.

The log also goes to the container's stdout, which is what Runpod's `GET /v2/sandboxes/{id}/logs` streams. That gives an authenticated copy alongside the public one.

## Environment

**Required**

| Variable | Meaning |
| --- | --- |
| `LLM_BASE_URL` | OpenAI-compatible base URL, **without** `/v1` |
| `LLM_API_KEY` | Key for that endpoint |
| `AGENT_TOKEN` | Bearer token clients present to the agent's API |
| `LOG_PATH_SECRET` | Random path segment the log server is mounted under |

**Model**

| Variable | Default | Meaning |
| --- | --- | --- |
| `LLM_MODEL` | `moonshotai/Kimi-K3` | Model id at `LLM_BASE_URL` |
| `LLM_CONTEXT` | `262144` | Max context size, in tokens |
| `LLM_EFFORTS` | `low,high,max` | Thinking efforts the model accepts |
| `LLM_EFFORT` | `high` | Default thinking effort |
| `PERMISSION_MODE` | `yolo` | Kimi Code's tool-approval mode |

`LLM_EFFORTS` exists because some models reject the CLI's default `medium` effort and return a 400 on every request.

**What gets installed**

| Variable | Default | Meaning |
| --- | --- | --- |
| `KIMI_VERSION` | latest | Kimi Code version |
| `MCP_VERSION` | `latest` | `@runpod/mcp-server` version |
| `RUNPODCTL_VERSION` | `latest` | `runpodctl` release tag |
| `INSTALL_SKILLS` | `1` | Clone `SKILLS_REPO` into `~/.agents/skills` |
| `INSTALL_MCP` | `auto` | `auto` installs when `RUNPOD_API_KEY` is set |
| `INSTALL_RUNPODCTL` | `auto` | As above |
| `SKILLS_REPO` | `runpod-plugins-official` | Git repo of agent skills; every `skills/` directory in it is copied |
| `RUNPOD_API_KEY` | | Enables the Runpod MCP server |
| `MCP_ENV_JSON` | | Extra env for the MCP server, as a JSON object (point it at another environment) |

A tool that is already installed at an acceptable version is not downloaded again, so the same script works on an image that carries the tools and only needs configuring.

**Customizing**

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENTS_MD_B64` | built-in | Base64 instructions written to the workspace's `AGENTS.md` |
| `SETUP_HOOK_B64` | | Base64 shell script run in `WORKDIR` before the agent starts |
| `WORKDIR` | `$HOME/workspace` | The agent's working directory |
| `AGENT_TITLE` | `Sandbox agent` | Web UI title and model display name |

The setup hook runs **after** the secrets are unset, so it cannot read them, and its output lands in the public log. A non-zero exit fails the boot.

**Runtime**

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGENT_PORT` | `8080` | Agent port |
| `LOG_PORT` | `8081` | Status, health and log port |
| `ALLOWED_HOSTS` | `.proxy.runpod.net,.dev-proxy.runpod.net` | Hosts the agent's web server accepts |
| `AGENT_LOG_LEVEL` | `warn` | Agent log level; `info` logs every health probe |
| `READY_TIMEOUT_SECONDS` | `60` | How long a start may take to answer before it counts as a crash |
| `HEARTBEAT_SECONDS` | `15` | Health check interval |
| `AGENT_MAX_RESTARTS` | `5` | Restarts before giving up, with linear backoff |
| `FAIL_LINGER_SECONDS` | `900` | How long a failed boot keeps serving its status |
| `LOG_ROOT` | `/tmp/pub` | Directory the log server serves |

## Trust

**This script runs with whatever you put in the sandbox's environment, including your Runpod API key.**

1. **Pin a commit SHA, not `main`.** Fetching `main` means your sandboxes run whatever this file says at boot, including a change you have not read.
2. **Read it first.** It is one shell file, with no minified or generated content.
3. **Pin what it installs** if you need reproducible boots. By default it fetches the latest Kimi Code and `@runpod/mcp-server`, so the agent's version moves under you.

## Secrets

The script reads secrets from the environment, writes them to `0600` files under `~/.kimi-code`, and unsets them, so neither the agent's shell nor the setup hook can read them back. The agent's startup banner prints its bearer token; that is scrubbed from the log, because the log is served over HTTP. The tests check both.

Two things it does **not** fix:

- **The sandbox's environment is readable through the Runpod API** by anyone who can read your account. Values passed as env are not private to the container. Beyond a prototype, pass a single-use bootstrap token and have the sandbox exchange it for real credentials.
- **The `/http` ports are public.** The agent port is bearer-authenticated; the log port is protected only by the unguessable path. Treat the log as world-readable.

## Sandbox behaviour worth knowing

- **`state: RUNNING` arrives ~25 seconds before the container is usable.** Poll `status.json`, not `state`.
- **Traffic on `/http` ports does not count as sandbox activity.** Only exec calls and open log streams reset the idle timer. An agent you are actively chatting with can therefore be reaped by the idle timeout. Call `recordSandboxActivity` from your client while it is in use, or set `idleTimeoutSeconds` to cover a session.
- Commands run as an unprivileged user. `apt-get` fails on the dpkg lock, which is why everything installs under `$HOME`.
- There is no GPU. This is for an agent that *manages* compute, not one that uses it.

## Tests

```bash
test/lifecycle.sh          # every case, ~45s
test/lifecycle.sh happy    # one case
```

They run the real script on your machine, in isolated temp homes and ports, and need no secrets: the agent answers its health endpoint without reaching a model. Cases cover the happy path, secret handling, a crash and restart, `SIGTERM`, a missing variable, a custom `AGENTS.md`, a busy port, and a crash loop that gives up. CI runs them on every push, alongside `shellcheck`.

The busy-port case exists because Kimi Code silently binds a different port, still logging `server ready`, when the one it was given is taken. In a sandbox that port is unpublished, so the script refuses to start instead.

## License

MIT
