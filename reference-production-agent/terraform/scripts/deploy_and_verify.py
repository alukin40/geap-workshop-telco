#!/usr/bin/env python3
"""Deploy and validate the standalone production reference agent (pulse-concierge-prod).

Invoked by `terraform apply` whenever the agent code, its configuration or the Agent Gateway
binding changes (or directly via CLI). It keeps all state inside
`reference-production-agent/pulse-concierge-prod/` and never touches `workshop.env` or `labs/`.

Steps: write `.env` -> `agents-cli deploy` (optionally bound to an egress Agent Gateway) ->
grant the agent's own identity its IAM roles -> verify (remote text + MCP + A2A, local
multimodal Chat -> Voice -> Chat, delegated BigQuery 200 / 403). Exits non-zero on any failure.
"""
import os

# Workstations with Certificate-Based Access set these; the Python clients below must use plain TLS.
os.environ.pop("GOOGLE_API_CERTIFICATE_CONFIG", None)
os.environ["GOOGLE_API_USE_CLIENT_CERTIFICATE"] = "false"

import argparse
import asyncio
from datetime import datetime
import json
import pathlib
import subprocess
import sys
import time
import traceback
from types import SimpleNamespace

import google.auth
from google.auth.transport.requests import Request
import requests
import vertexai

PROD_ROOT = pathlib.Path(__file__).resolve().parents[2]
PROD_AGENT_DIR = PROD_ROOT / "pulse-concierge-prod"

AGENT_ROLES = [
    "roles/aiplatform.user",
    "roles/bigquery.dataViewer",
    "roles/bigquery.jobUser",
    "roles/dataplex.catalogViewer",
    "roles/mcp.toolUser",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/agentregistry.viewer",
    "roles/modelarmor.user",
    "roles/logging.logWriter",
    "roles/cloudtrace.agent",
    "roles/monitoring.metricWriter",
]


def gcp_token() -> str:
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(Request())
    return creds.token


def sh(cmd: str, retries: int = 1, delay: int = 10, cwd=None) -> subprocess.CompletedProcess:
    """Run a shell command, retrying (IAM propagation); raise with stderr after the last attempt."""
    for attempt in range(retries):
        r = subprocess.run(cmd, shell=True, cwd=cwd, text=True, capture_output=True)
        if r.returncode == 0:
            return r
        if attempt < retries - 1:
            time.sleep(delay)
    raise RuntimeError(f"command failed: {cmd}\n{r.stderr[-1500:]}")


def _gateway_key(name: str) -> str:
    """Compare gateway bindings independent of project ID vs number: '<location>/<gateway>'."""
    parts = (name or "").strip("/").split("/")
    return f"{parts[3]}/{parts[5]}" if len(parts) == 6 else ""


def gateway_root_certificates(gateway: str) -> str:
    """Root CA(s) of the egress Agent Gateway, newline-escaped for the AGENT_GATEWAY_ROOT_CERTIFICATES build arg."""
    _, project, _, location, _, name = gateway.strip("/").split("/")
    cmd = (f"gcloud network-services agent-gateways describe {name} --location={location} --project={project} "
           "--format=\"value[delimiter='\\n'](agentGatewayCard.rootCertificates)\"")
    for attempt in range(20):
        pem = subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()
        if "BEGIN CERTIFICATE" in pem:
            return pem.replace("\n", "\\n") + "\\n"
        print(f"  gateway root certificate not published yet ({attempt * 15}s), waiting")
        time.sleep(15)
    raise RuntimeError(f"{gateway} has not published its root certificate after 5 minutes")


def check_single_egress_gateway(gateway: str) -> None:
    """Agent Runtime accepts only one egress (AGENT_TO_ANYWHERE) gateway per project."""
    _, project, _, location, _, name = gateway.strip("/").split("/")
    others = subprocess.run(
        f"gcloud network-services agent-gateways list --location={location} --project={project} "
        "--filter=googleManaged.governedAccessPath=AGENT_TO_ANYWHERE --format='value(name.basename())'",
        shell=True, capture_output=True, text=True,
    ).stdout.split()
    others = [g for g in others if g != name]
    if others:
        raise RuntimeError(f"Agent Runtime allows one egress Agent Gateway per project; {others} already exists in "
                           f"{project}/{location}. Delete it (unbind its agents first) or disable enable_agent_gateway.")


async def remote_ask(agent, user_id: str, message: str) -> tuple[str, list[str]]:
    """One turn against the deployed engine: returns (final text, names of the tools / sub-agents it called)."""
    last_calls: list[str] = []
    for attempt in range(3):
        session = (await agent.async_create_session(user_id=user_id))["id"]
        texts, calls = [], []
        async for ev in agent.async_stream_query(user_id=user_id, session_id=session, message=message):
            for p in (ev.get("content") or {}).get("parts") or []:
                if fc := (p.get("function_call") or p.get("functionCall")):
                    calls.append(fc["name"])
                if p.get("text") and not p.get("thought"):
                    texts.append(p["text"])
        reply = "\n".join(texts).strip()
        if reply:
            return reply, calls
        last_calls = calls
        if attempt < 2:
            print(f"  [remote_ask retry {attempt + 1}/2 after empty text; tools={calls}]")
            await asyncio.sleep(5)
    return "", last_calls


async def verify_production_agent(args, engine_name: str, principal: str, noc_enabled: bool) -> dict:
    """[1/3] deployed engine (BigQuery, MCP, A2A), [2/3] local Chat -> Voice -> Chat, [3/3] delegated BigQuery 200 / 403."""
    os.environ["GOOGLE_GENAI_USE_VERTEXAI"] = "1"
    os.environ["GOOGLE_CLOUD_PROJECT"] = args.project_id
    os.environ["GOOGLE_CLOUD_LOCATION"] = args.model_location

    # 1. Deployed Agent Runtime engine over HTTPS
    print("\n=== [1/3] Deployed Agent Runtime engine: BigQuery as session user, IAM Context MCP, NOC A2A ===")
    vclient = vertexai.Client(project=args.project_id, location=args.region)
    remote_agent = vclient.agent_engines.get(name=engine_name)
    cloud_text, calls = await remote_ask(
        remote_agent,
        "persona-alex-exec",
        "Call query_crm_domain directly for region_code='PRG', segment='ALL', only_high_churn=True and report how many High Churn Risk active subscribers we have in PRG.",
    )
    print(f"  [BigQuery] tools={calls}\n  {cloud_text[:400]}")
    assert cloud_text, "deployed agent returned no text"

    mcp_text, mcp_calls = await remote_ask(remote_agent, "persona-alex-exec", "Call resolve_user_context for token tok_marek_netops and list the allowed datasets.")
    print(f"  [MCP] tools={mcp_calls}\n  {mcp_text[:300]}")
    assert "resolve_user_context" in mcp_calls, f"IAM Context MCP tool was not called: {mcp_calls}"

    noc_text = ""
    if noc_enabled:
        noc_text, noc_calls = await remote_ask(remote_agent, "netops-marek", "Ask the NOC desk to diagnose tower TWR-PRG-02.")
        print(f"  [A2A] tools={noc_calls}\n  {noc_text[:300]}")
        assert "pulse_network_ops_desk" in noc_calls, f"NOC A2A agent was not called: {noc_calls}"

    # 2. Local multimodal check: the same app code, run in-process (Text Chat -> Live Voice -> Text Chat)
    print("\n=== [2/3] Local multimodal check, same code as deployed (Text Chat -> Live Voice -> Text Chat) ===")
    sys.path.insert(0, str(PROD_AGENT_DIR))
    from google.adk.agents.live_request_queue import LiveRequestQueue
    from google.adk.agents.run_config import RunConfig, StreamingMode
    from google.adk.memory import InMemoryMemoryService
    from google.adk.runners import Runner
    from google.adk.sessions import InMemorySessionService
    from google.genai import types
    from app.agent import app as prod_app
    from app.tools import query_billing_domain

    runner = Runner(app=prod_app, session_service=InMemorySessionService(), memory_service=InMemoryMemoryService(), auto_create_session=True)
    shared_session = "prod-multimodal-session-01"
    user_id = "persona-alex-exec"

    async def text_turn(text: str) -> str:
        reply = ""
        async for ev in runner.run_async(user_id=user_id, session_id=shared_session,
                                         new_message=types.Content(role="user", parts=[types.Part.from_text(text=text)])):
            for p in (ev.content.parts if ev.content and ev.content.parts else []):
                if p.text and not getattr(p, "thought", False):
                    reply = p.text
        return reply

    turn1_reply = await text_turn("Query CRM for PRG high churn subscribers.")
    print(f"  [Turn 1 Text Chat]: {turn1_reply[:220]}...")
    assert turn1_reply, "turn 1 returned no text"

    audio_out, out_transcript = bytearray(), []
    for live_attempt in range(3):
        live_queue = LiveRequestQueue()
        live_queue.send_content(types.Content(role="user", parts=[types.Part.from_text(
            text="Call query_billing_domain for 2026-08 overdue invoices in telco_billing and state our Delinquent billing exposure.")]))
        try:
            async with asyncio.timeout(60):
                async for ev in runner.run_live(
                    user_id=user_id, session_id=shared_session, live_request_queue=live_queue,
                    run_config=RunConfig(streaming_mode=StreamingMode.BIDI, response_modalities=["AUDIO"],
                                         input_audio_transcription=types.AudioTranscriptionConfig(),
                                         output_audio_transcription=types.AudioTranscriptionConfig()),
                ):
                    if ev.output_transcription and ev.output_transcription.finished:
                        out_transcript.append(ev.output_transcription.text)
                    for p in (ev.content.parts if ev.content and ev.content.parts else []):
                        if p.inline_data and p.inline_data.data:
                            audio_out.extend(p.inline_data.data)
                    if ev.turn_complete and (out_transcript or audio_out):
                        break
        except TimeoutError:
            print(f"  [Turn 2 Live Voice]: attempt {live_attempt + 1}/3 timed out after 60 s")
        if audio_out:
            break
    voice_text = " ".join(out_transcript).strip()
    print(f"  [Turn 2 Live Voice @ {os.environ.get('PULSE_LIVE_LOCATION')}]: audio_bytes={len(audio_out)}, transcript={voice_text[:220]}...")
    assert audio_out, "Live Voice returned no audio"

    turn3_reply = await text_turn("Summarize both the PRG high-churn count from Turn 1 and the delinquent billing exposure from Turn 2.")
    print(f"  [Turn 3 Text Chat]: {turn3_reply[:240]}...")
    assert turn3_reply, "turn 3 returned no text"

    # 3. Delegated OAuth 2.0: the identity comes from the session user_id, BigQuery IAM decides
    print("\n=== [3/3] Delegated OAuth 2.0 BigQuery IAM enforcement (session user -> persona) ===")
    admin_res = query_billing_domain("2026-08", "overdue", "ALL", tool_context=SimpleNamespace(user_id="persona-alex-exec"))
    spec_res = query_billing_domain("2026-08", "overdue", "ALL", tool_context=SimpleNamespace(user_id="persona-elena-care"))
    print(f"  Admin (persona-alex-exec)       -> status={admin_res['status']} (job {admin_res.get('bigquery_job_id')})")
    print(f"  Specialist (persona-elena-care) -> status={spec_res['status']} (HTTP {spec_res.get('http_status')})")
    assert admin_res["status"] == "success" and admin_res.get("bigquery_job_id"), admin_res
    assert spec_res["status"] == "iam_access_denied" and spec_res.get("http_status") == 403, spec_res

    report = {
        "status": "VERIFIED",
        "agent_engine": engine_name,
        "agent_identity": principal,
        "agent_gateway": args.agent_gateway or None,
        "cloud_reply_preview": cloud_text[:300],
        "mcp_reply_preview": mcp_text[:300],
        "noc_reply_preview": noc_text[:300],
        "live_voice_location": os.environ.get("PULSE_LIVE_LOCATION"),
        "live_voice_audio_bytes": len(audio_out),
        "live_voice_transcript": voice_text,
        "turn3_summary_preview": turn3_reply[:300],
        "oauth_admin_http_status": admin_res.get("http_status", 200),
        "oauth_specialist_http_status": spec_res.get("http_status"),
    }
    report_path = PROD_AGENT_DIR / ".prod_verification_report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"\nSaved verification report to {report_path}")
    return report


def main() -> None:
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--region", required=True, help="Agent Runtime / Cloud Run / Agent Registry region")
    parser.add_argument("--model-location", default="eu")
    parser.add_argument("--live-location", default="eu")
    parser.add_argument("--bq-location", default="EU")
    parser.add_argument("--ma-input-template", required=True, help="Full name of the Model Armor prompt template")
    parser.add_argument("--ma-output-template", required=True, help="Full name of the Model Armor response template")
    parser.add_argument("--iam-mcp-url", required=True, help="URL of the IAM Context MCP server (…/mcp)")
    parser.add_argument("--network-ops-agent-url", default="", help="Base URL of the NOC A2A agent (adds pulse_network_ops_desk).")
    parser.add_argument("--agent-gateway", default="", help="Full name of an egress Agent Gateway to bind the agent to (empty = no gateway; unbinds an existing one).")
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args()

    project_id, region = args.project_id, args.region
    project_number = sh(f"gcloud projects describe {project_id} --format='value(projectNumber)'").stdout.strip()

    env_map = {
        "GOOGLE_GENAI_USE_VERTEXAI": "1",
        "GOOGLE_CLOUD_PROJECT": project_id,
        "PROJECT_NUMBER": project_number,
        "GOOGLE_CLOUD_LOCATION": args.model_location,
        "PULSE_LIVE_MODEL": "gemini-3.8-live",
        "PULSE_LIVE_LOCATION": args.live_location,
        "MODEL": "gemini-3.8-flash",
        "BQ_LOCATION": args.bq_location,
        "BQ_DATASET_CRM": "telco_crm",
        "BQ_DATASET_BILLING": "telco_billing",
        "BQ_DATASET_NETWORK": "telco_network",
        "PERSONA_ADMIN_SA": f"persona-alex-exec@{project_id}.iam.gserviceaccount.com",
        "PERSONA_SPECIALIST_SA": f"persona-elena-care@{project_id}.iam.gserviceaccount.com",
        "PULSE_REGISTRY_LOCATION": region,
        "PULSE_SKILLS_LOCATION": "eu",
        "PULSE_IAM_MCP_URL": args.iam_mcp_url,
        "PULSE_MODEL_ARMOR_INPUT_TEMPLATE": args.ma_input_template,
        "PULSE_MODEL_ARMOR_OUTPUT_TEMPLATE": args.ma_output_template,
        "GOOGLE_API_USE_CLIENT_CERTIFICATE": "false",
        "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES": "false",
        "UV_NO_SYNC": "1",
        "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY": "true",
        "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": "true",
    }
    if args.network_ops_agent_url:
        env_map["PULSE_NETWORK_OPS_AGENT_CARD"] = args.network_ops_agent_url.rstrip("/") + "/.well-known/agent-card.json"
    (PROD_AGENT_DIR / ".env").write_text("\n".join(f"{k}={v}" for k, v in env_map.items()) + "\n")

    # Reuse the engine recorded in deployment_metadata.json only if it belongs to this project.
    meta_file = PROD_AGENT_DIR / "deployment_metadata.json"
    current_gateway = ""
    need_deploy = True
    if meta_file.exists():
        meta = json.loads(meta_file.read_text())
        rid = meta.get("remote_agent_runtime_id") or ""
        chk = requests.get(f"https://{region}-aiplatform.googleapis.com/v1/{rid}", headers={"Authorization": f"Bearer {gcp_token()}"}) if rid else None
        if rid and f"projects/{project_number}/locations/{region}/" in rid and chk.status_code == 200:
            dep_spec = chk.json().get("spec", {}).get("deploymentSpec", {})
            gw_cfg = dep_spec.get("agentGatewayConfig") or {}
            current_gateway = (gw_cfg.get("agentToAnywhereConfig") or {}).get("agentGateway", "")
            remote_env = {e["name"]: e.get("value", "") for e in dep_spec.get("env") or [] if "name" in e}
            env_matches = all(remote_env.get(k) == v for k, v in env_map.items() if k != "GOOGLE_CLOUD_PROJECT")
            deploy_ts = datetime.fromisoformat(meta["deployment_timestamp"]).timestamp() if meta.get("deployment_timestamp") else 0
            src_mtime = max(p.stat().st_mtime for p in [*(PROD_AGENT_DIR / "app").rglob("*"), PROD_AGENT_DIR / "pyproject.toml", PROD_AGENT_DIR / "Dockerfile"] if p.is_file() and "__pycache__" not in str(p))
            if _gateway_key(current_gateway) == _gateway_key(args.agent_gateway) and env_matches and deploy_ts >= src_mtime:
                print(f"Reusing up-to-date engine {rid} (egress gateway: {current_gateway or 'none'})")
                need_deploy = False
            else:
                print(f"Updating existing engine {rid} (egress gateway: {current_gateway or 'none'} -> {args.agent_gateway or 'none'})")
        else:
            print(f"deployment_metadata.json points to another project/region or a deleted engine ({rid}); creating a new engine")
            meta_file.unlink()

    if need_deploy:
        print(f"Deploying pulse-concierge-prod to Agent Runtime ({region})...")
        sh("uv lock --no-config --default-index https://pypi.org/simple", cwd=PROD_AGENT_DIR)
        cmd = f"agents-cli deploy --project {project_id} --region {region} --agent-identity --no-confirm-project"
        if args.agent_gateway:
            check_single_egress_gateway(args.agent_gateway)
            # The gateway terminates TLS, so the image must trust its root CA (see Dockerfile).
            cert = gateway_root_certificates(args.agent_gateway)
            cmd += f' --agent-gateway-egress {args.agent_gateway} --build-args "AGENT_GATEWAY_ROOT_CERTIFICATES={cert}"'
        elif current_gateway:
            cmd += ' --agent-gateway-egress ""'
        r = subprocess.run(cmd, shell=True, cwd=PROD_AGENT_DIR, text=True, capture_output=True)
        print(r.stdout[-2500:])
        if r.returncode != 0:
            print(r.stderr[-2500:], file=sys.stderr)
            raise RuntimeError("pulse-concierge-prod deploy failed")

    meta = json.loads(meta_file.read_text())
    engine_name = meta.get("remote_agent_runtime_id") or meta.get("remote_agent_engine_id")
    info = requests.get(f"https://{region}-aiplatform.googleapis.com/v1/{engine_name}", headers={"Authorization": f"Bearer {gcp_token()}"}).json()
    raw_id = info.get("spec", {}).get("effectiveIdentity", "")
    assert raw_id, f"engine has no Agent Identity: {info}"
    principal = raw_id if raw_id.startswith("principal://") else f"principal://{raw_id}"
    print(f"Deployed pulse-concierge-prod: {engine_name}\nAgent Identity: {principal}")
    print(f"Egress gateway binding: {info.get('spec', {}).get('deploymentSpec', {}).get('agentGatewayConfig')}")

    iam_check = subprocess.run(
        f'gcloud projects get-iam-policy {project_id} --flatten="bindings[].members" '
        f'--filter="bindings.role:roles/monitoring.metricWriter AND bindings.members:{principal}" --format="value(bindings.role)"',
        shell=True, capture_output=True, text=True,
    ).stdout.strip()
    if need_deploy or not iam_check:
        for role in AGENT_ROLES:
            sh(f'gcloud projects add-iam-policy-binding {project_id} --member="{principal}" --role={role} --condition=None --quiet', retries=6)
        for persona in ["persona-alex-exec", "persona-elena-care"]:
            sh(f'gcloud iam service-accounts add-iam-policy-binding {persona}@{project_id}.iam.gserviceaccount.com '
               f'--member="{principal}" --role=roles/iam.serviceAccountTokenCreator --project={project_id} --quiet', retries=6)
        # The local verification ([2/3], [3/3]) impersonates the personas with the deploying user's ADC.
        account = sh("gcloud config get-value account").stdout.strip()
        member = f"serviceAccount:{account}" if account.endswith("gserviceaccount.com") else f"user:{account}"
        for persona in ["persona-alex-exec", "persona-elena-care"]:
            sh(f'gcloud iam service-accounts add-iam-policy-binding {persona}@{project_id}.iam.gserviceaccount.com '
               f'--member="{member}" --role=roles/iam.serviceAccountTokenCreator --project={project_id} --quiet', retries=6)
        print("Agent Identity and verifier roles granted; waiting 30 s for IAM propagation...")
        time.sleep(30)
    else:
        print("Agent Identity and verifier roles already bound.")

    if not args.skip_verify:
        asyncio.run(verify_production_agent(args, engine_name, principal, bool(args.network_ops_agent_url)))


if __name__ == "__main__":
    # os._exit: the Live API / gRPC client threads can keep the interpreter alive after asyncio.run returns.
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1)
    sys.stdout.flush()
    os._exit(0)
