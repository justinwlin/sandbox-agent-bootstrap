#!/usr/bin/env python3
"""Create a Runpod Sandbox running bootstrap.sh, wait until the agent answers, print how to reach it.

Standard library only. Reads RUNPOD_API_KEY, LLM_BASE_URL and LLM_API_KEY from the environment.

    # fetch a pinned commit of bootstrap.sh from GitHub at boot
    python3 examples/create_sandbox.py --ref <commit-sha>

    # or ship the local file inside the request, with no fetch at boot
    python3 examples/create_sandbox.py --inline bootstrap.sh

    # give the agent the Runpod MCP server, using RUNPOD_API_KEY
    python3 examples/create_sandbox.py --ref <sha> --with-mcp

    python3 examples/create_sandbox.py --terminate <sandbox-id>
"""

import argparse
import base64
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

REPO_RAW = "https://raw.githubusercontent.com/justinwlin/sandbox-agent-bootstrap"
ENVIRONMENTS = {
    "prod": {"api": "https://api.runpod.io", "proxy": "proxy.runpod.net"},
    "dev": {"api": "https://api.runpod.dev", "proxy": "dev-proxy.runpod.net"},
}

CREATE = """
mutation($input: CreateSandboxInput!) {
  createSandbox(input: $input) {
    __typename
    ... on CreateSandboxSuccess { sandbox { id state imageName pod { id } } }
    ... on CreateSandboxFailure { code message }
  }
}"""
TERMINATE = "mutation($id: String!) { terminateSandbox(input: {id: $id}) { id state } }"


def fail(message):
    sys.exit(f"error: {message}")


def require_env(name):
    value = os.environ.get(name)
    if not value:
        fail(f"{name} is not set")
    return value


def http(url, data=None, headers=None, timeout=30):
    """GET, or POST JSON when data is given. Returns the decoded body, or None on a non-2xx."""
    body = json.dumps(data).encode() if data is not None else None
    # The default Python-urllib agent is refused by Cloudflare in front of the proxy.
    request = urllib.request.Request(url, body, {"User-Agent": "sandbox-agent-bootstrap", **(headers or {})})
    if body:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            text = response.read().decode()
            return json.loads(text) if text.lstrip().startswith(("{", "[")) else text
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return None


def graphql(env, query, variables):
    result = http(f"{env['api']}/graphql", {"query": query, "variables": variables},
                  {"Authorization": f"Bearer {require_env('RUNPOD_API_KEY')}"}, timeout=60)
    if result is None:
        fail("GraphQL request failed (check RUNPOD_API_KEY and --env)")
    if result.get("errors"):
        fail(json.dumps(result["errors"]))
    return result["data"]


def entrypoint(args):
    """The container command, and any env it needs to find the script."""
    if args.inline:
        with open(args.inline, "rb") as f:
            script = base64.b64encode(f.read()).decode()
        cmd = 'echo "$BOOTSTRAP_B64" | base64 -d > /tmp/bootstrap.sh && exec bash /tmp/bootstrap.sh'
        return cmd, {"BOOTSTRAP_B64": script}
    url = f"{REPO_RAW}/{args.ref}/bootstrap.sh"
    return f"curl -fsSL {url} -o /tmp/bootstrap.sh && exec bash /tmp/bootstrap.sh", {}


def create(args, env):
    token = secrets.token_urlsafe(32)
    log_secret = secrets.token_urlsafe(12)
    cmd, delivery_env = entrypoint(args)
    sandbox_env = {
        **delivery_env,
        "LLM_BASE_URL": require_env("LLM_BASE_URL"),
        "LLM_API_KEY": require_env("LLM_API_KEY"),
        "AGENT_TOKEN": token,
        "LOG_PATH_SECRET": log_secret,
    }
    if os.environ.get("LLM_MODEL"):
        sandbox_env["LLM_MODEL"] = os.environ["LLM_MODEL"]
    if args.with_mcp:
        sandbox_env["RUNPOD_API_KEY"] = require_env("RUNPOD_API_KEY")
        if args.env != "prod":
            sandbox_env["MCP_ENV_JSON"] = json.dumps({
                "RUNPOD_API_BASE_URL": env["api"],
                "RUNPOD_PUBLIC_GRAPHQL_URL": f"{env['api']}/graphql",
                "RUNPOD_AUTHED_GRAPHQL_URL": f"{env['api']}/graphql",
            })
    for pair in args.set or []:
        key, _, value = pair.partition("=")
        sandbox_env[key] = value

    sandbox_input = {
        "name": args.name,
        "vcpuCount": args.vcpu,
        "containerDiskInGb": 20,
        "ports": "8080/http,8081/http",
        "dockerArgs": json.dumps({"entrypoint": ["bash", "-c"], "cmd": [cmd]}),
        "env": [{"key": k, "value": v} for k, v in sandbox_env.items()],
        "idleTimeoutSeconds": args.idle_timeout,
        "maxLifetimeSeconds": args.max_lifetime,
        "labels": {"app": "sandbox-agent-bootstrap"},
        # Makes a retried create return the same sandbox instead of a second one.
        "idempotencyKey": f"sandbox-agent-{secrets.token_hex(8)}",
    }
    if args.data_center:
        sandbox_input["dataCenterIds"] = args.data_center

    outcome = graphql(env, CREATE, {"input": sandbox_input})["createSandbox"]
    if outcome["__typename"] != "CreateSandboxSuccess":
        fail(f"{outcome['code']}: {outcome['message']}")
    sandbox = outcome["sandbox"]
    print(f"sandbox {sandbox['id']} (pod {sandbox['pod']['id']}) on {sandbox['imageName']}", file=sys.stderr)
    return sandbox, token, log_secret


def wait_until_ready(env, pod_id, log_secret, timeout):
    # The proxy hostname is the pod id; the sandbox id there just 404s.
    status_url = f"https://{pod_id}-8081.{env['proxy']}/{log_secret}/status.json"
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        status = http(status_url, timeout=10)
        if isinstance(status, dict):
            if status != last:
                print(f"  {status['state']:<11} {status['step']}", file=sys.stderr)
                last = status
            if status["state"] == "ready":
                return status
            if status["state"] == "failed":
                fail(f"bootstrap failed: {status['step']}")
        time.sleep(3)
    fail(f"not ready after {timeout}s (status: {last})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--ref", help="commit SHA (or branch) of bootstrap.sh to fetch at boot")
    source.add_argument("--inline", metavar="PATH", help="ship a local bootstrap.sh in the request")
    source.add_argument("--terminate", metavar="SANDBOX_ID", help="terminate a sandbox and exit")
    parser.add_argument("--env", choices=ENVIRONMENTS, default="prod")
    parser.add_argument("--with-mcp", action="store_true", help="pass RUNPOD_API_KEY to the agent's MCP server")
    parser.add_argument("--set", action="append", metavar="KEY=VALUE", help="extra sandbox env, repeatable")
    parser.add_argument("--name", default="sandbox-agent")
    parser.add_argument("--vcpu", type=int, default=4)
    parser.add_argument("--data-center", action="append", help="repeatable")
    parser.add_argument("--idle-timeout", type=int, default=3600)
    parser.add_argument("--max-lifetime", type=int, default=14400)
    parser.add_argument("--timeout", type=int, default=300, help="seconds to wait for ready")
    args = parser.parse_args()
    env = ENVIRONMENTS[args.env]

    if args.terminate:
        print(json.dumps(graphql(env, TERMINATE, {"id": args.terminate})["terminateSandbox"]))
        return
    if not (args.ref or args.inline):
        parser.error("one of --ref, --inline or --terminate is required")

    sandbox, token, log_secret = create(args, env)
    pod = sandbox["pod"]["id"]
    started = time.monotonic()
    wait_until_ready(env, pod, log_secret, args.timeout)
    print(f"ready in {time.monotonic() - started:.0f}s after create", file=sys.stderr)

    print(json.dumps({
        "sandboxId": sandbox["id"],
        "podId": pod,
        "agentUrl": f"https://{pod}-8080.{env['proxy']}",
        "agentToken": token,
        "webUi": f"https://{pod}-8080.{env['proxy']}/#token={token}",
        "status": f"https://{pod}-8081.{env['proxy']}/{log_secret}/status.json",
        "health": f"https://{pod}-8081.{env['proxy']}/{log_secret}/health.json",
        "log": f"https://{pod}-8081.{env['proxy']}/{log_secret}/setup.log",
    }, indent=2))


if __name__ == "__main__":
    main()
