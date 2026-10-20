#!/usr/bin/env python3
"""Instructor helper for the Agent Gateway demo (see ../../AGENT_GATEWAY_DEMO.md).

  ask  "<prompt>" [--user ID]   send one prompt to the deployed pulse-concierge-prod and show tool calls
  logs [--minutes N] [--all]    show pulse-prod-egress-gateway decisions from Cloud Logging
  mode DRY_RUN|ENFORCED         flip the gateway's IAP extension in ~10 s (terraform apply does the same, slower)

Project, region and engine are read from pulse-concierge-prod/.env and deployment_metadata.json,
which `terraform apply` writes. Run from the repository root:
  uv run python3 reference-production-agent/terraform/scripts/gateway_demo.py ask "..."
"""
import os

# Workstations with Certificate-Based Access set these; the Python clients below must use plain TLS.
os.environ.pop("GOOGLE_API_CERTIFICATE_CONFIG", None)
os.environ["GOOGLE_API_USE_CLIENT_CERTIFICATE"] = "false"

import argparse
import asyncio
import json
import pathlib
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

AGENT_DIR = pathlib.Path(__file__).resolve().parents[2] / "pulse-concierge-prod"
GATEWAY = "pulse-prod-egress-gateway"
IAP_EXT = "pulse-prod-iap-authz-ext"


def config() -> tuple[str, str, str]:
    env = dict(line.split("=", 1) for line in (AGENT_DIR / ".env").read_text().splitlines() if "=" in line)
    engine = json.loads((AGENT_DIR / "deployment_metadata.json").read_text())["remote_agent_runtime_id"]
    return env["GOOGLE_CLOUD_PROJECT"], env["PULSE_REGISTRY_LOCATION"], engine


async def ask(prompt: str, user: str) -> None:
    import vertexai

    project, region, engine = config()
    client = vertexai.Client(project=project, location=region)
    agent = client.agent_engines.get(name=engine)
    session = (await agent.async_create_session(user_id=user))["id"]
    print(f"USER ({user}): {prompt}")
    final = ""
    async for event in agent.async_stream_query(user_id=user, session_id=session, message=prompt):
        for part in (event.get("content") or {}).get("parts") or []:
            if call := (part.get("function_call") or part.get("functionCall")):
                print(f"  [tool call] {call['name']}({json.dumps(call.get('args'))[:160]})")
            if resp := (part.get("function_response") or part.get("functionResponse")):
                print(f"  [tool resp] {resp['name']}: {json.dumps(resp.get('response'))[:220]}")
            if part.get("text") and not part.get("thought"):
                final = part["text"]
    print(f"PULSE: {final.strip()[:900]}")


def logs(minutes: int, show_all: bool) -> None:
    project, _, _ = config()
    since = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
    query = (f'resource.type="networkservices.googleapis.com/Gateway" resource.labels.gateway_name="{GATEWAY}" '
             f'-httpRequest.requestMethod="CONNECT" timestamp>="{since}"')
    if not show_all:
        query += ' (jsonPayload.agentGatewayInfo.mcpInfo.method="tools/call" OR httpRequest.status>=400 OR jsonPayload.agentGatewayInfo.agentRegistryResource:"/agents/")'
    out = subprocess.run(["gcloud", "logging", "read", query, f"--project={project}", "--limit=60", "--format=json", "--order=asc"],
                         capture_output=True, text=True, check=True).stdout
    entries = json.loads(out or "[]")
    for e in entries:
        req, jp = e.get("httpRequest", {}), e.get("jsonPayload", {})
        mcp = jp.get("agentGatewayInfo", {}).get("mcpInfo", {})
        target = f"{mcp.get('method')}/{mcp.get('parameter')}" if mcp else req.get("requestUrl", "")[:60]
        policies = {p["name"].split("/")[-1]: p.get("result") for p in jp.get("authzPolicyInfo", {}).get("policies", []) if p.get("name")}
        print(f"{e['timestamp'][11:19]}  HTTP {req.get('status')}  {target:<48} {policies}")
    print(f"({len(entries)} entries in the last {minutes} min; log ingestion lags ~30-60 s)")


def mode(value: str) -> None:
    project, region, _ = config()
    meta = '  iapPolicyVersion: "V2"\n' + ('  iamEnforcementMode: "DRY_RUN"\n' if value == "DRY_RUN" else "")
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(f"name: {IAP_EXT}\nservice: iap.googleapis.com\nfailOpen: false\ntimeout: 1s\nmetadata:\n{meta}")
    subprocess.run(["gcloud", "beta", "service-extensions", "authz-extensions", "import", IAP_EXT, f"--source={f.name}",
                    f"--location={region}", f"--project={project}", "--quiet"], check=True)
    print(f"{IAP_EXT} is now {value}. Allow ~60 s to propagate. "
          f"Run `terraform apply -var agent_gateway_enforcement={value}` later to keep Terraform in sync.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_ask = sub.add_parser("ask")
    p_ask.add_argument("prompt")
    p_ask.add_argument("--user", default="persona-alex-exec", help="session user_id; BigQuery tools act as persona-alex-exec / persona-elena-care")
    p_logs = sub.add_parser("logs")
    p_logs.add_argument("--minutes", type=int, default=5)
    p_logs.add_argument("--all", action="store_true", help="every request, not only tool calls / A2A / denials")
    p_mode = sub.add_parser("mode")
    p_mode.add_argument("value", choices=["DRY_RUN", "ENFORCED"])
    args = parser.parse_args()
    if args.cmd == "ask":
        asyncio.run(ask(args.prompt, args.user))
    elif args.cmd == "logs":
        logs(args.minutes, args.all)
    else:
        mode(args.value)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
