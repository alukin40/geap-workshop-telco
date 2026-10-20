"""Pulse Telco Production Reference Agent Tools (pulse-concierge-prod).

Combines:
1. Delegated IAM User OAuth 2.0 BigQuery Execution as the session user (query_bigquery_as_user, query_crm_domain, query_billing_domain)
2. Knowledge Catalog Semantic & Governance Lookup (lookup_knowledge_catalog)
3. Managed Agent Runtime Code Execution Sandbox (run_python)
"""
import contextlib
import io
import json
import os
import pathlib
import re
import time

import google.auth
from google.adk.tools.tool_context import ToolContext
from google.api_core.exceptions import Forbidden
from google.auth import impersonated_credentials
from google.auth.transport.requests import Request
from google.cloud import bigquery
import google.oauth2.credentials
import vertexai
from vertexai import types as vtypes

_DATA = pathlib.Path(__file__).parent / "data"
_KC_SPECS = json.loads((_DATA / "knowledge_catalog_specs.json").read_text())

PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
BQ_LOCATION = os.environ.get("BQ_LOCATION", "EU")

PERSONA_ADMIN_SA = os.environ.get("PERSONA_ADMIN_SA", f"persona-alex-exec@{PROJECT_ID}.iam.gserviceaccount.com")
PERSONA_SPECIALIST_SA = os.environ.get("PERSONA_SPECIALIST_SA", f"persona-elena-care@{PROJECT_ID}.iam.gserviceaccount.com")

# The identity a BigQuery query runs as comes from the authenticated session (user_id of the
# Agent Runtime session), never from an LLM-chosen argument. Unknown users are rejected.
_SESSION_USERS = {
    "alex": PERSONA_ADMIN_SA,
    "persona-alex-exec": PERSONA_ADMIN_SA,
    "elena": PERSONA_SPECIALIST_SA,
    "persona-elena-care": PERSONA_SPECIALIST_SA,
}

_OAUTH_CACHE: dict[str, tuple[str, float]] = {}


def resolve_iam_principal(user_id: str) -> str | None:
    """Map an authenticated session user_id to the GCP IAM principal it may act as (None = unknown user)."""
    return _SESSION_USERS.get((user_id or "").strip().lower())


def _mint_user_token(iam_email: str) -> str:
    """Server-side only: short-lived BigQuery-scoped OAuth 2.0 token for a persona. Never returned to the LLM."""
    now = time.time()
    cached = _OAUTH_CACHE.get(iam_email)
    if cached and cached[1] > now + 60:
        return cached[0]
    source_creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    imp_creds = impersonated_credentials.Credentials(
        source_credentials=source_creds,
        target_principal=iam_email,
        target_scopes=["https://www.googleapis.com/auth/bigquery"],
        lifetime=3600,
    )
    imp_creds.refresh(Request())
    _OAUTH_CACHE[iam_email] = (imp_creds.token, now + 3500)
    return imp_creds.token


def query_bigquery_as_user(sql: str, tool_context: ToolContext) -> dict:
    """Execute a BigQuery SQL query on behalf of the signed-in user with their own short-lived OAuth 2.0 credentials.

    BigQuery IAM enforces dataset-level access (roles/bigquery.dataViewer) and writes a Cloud Audit Log record
    (cloudaudit.googleapis.com/data_access) containing the user's principalEmail; the job is labelled with the agent.

    Args:
        sql: Standard SQL query targeting BigQuery tables in PROJECT_ID.

    Returns:
        Dictionary with 'status' ('success', 'iam_access_denied', 'unknown_user' or 'query_error'), 'iam_principal', and 'rows' or 'error'.
    """
    user_id = tool_context.user_id
    iam_email = resolve_iam_principal(user_id)
    if not iam_email:
        return {
            "status": "unknown_user",
            "http_status": 401,
            "error": f"Session user '{user_id}' is not mapped to a Pulse Telco persona (alex / elena); no BigQuery access.",
        }
    short_user = re.sub(r"[^a-z0-9_-]", "_", iam_email.split("@")[0].lower())[:60]

    user_creds = google.oauth2.credentials.Credentials(token=_mint_user_token(iam_email))
    client = bigquery.Client(project=PROJECT_ID, credentials=user_creds, location=BQ_LOCATION)
    job_config = bigquery.QueryJobConfig(
        labels={
            "executed_by_agent": "pulse-concierge-prod",
            "on_behalf_of_user": short_user,
        }
    )
    try:
        job = client.query(sql, job_config=job_config)
        rows = [
            {k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in dict(r).items()}
            for r in job.result()
        ]
        return {
            "status": "success",
            "http_status": 200,
            "iam_principal": iam_email,
            "delegated_by_agent": "pulse-concierge-prod",
            "job_id": job.job_id,
            "row_count": len(rows),
            "rows": rows,
        }
    except Forbidden as exc:
        first_line = exc.message.splitlines()[0] if exc.message else str(exc)
        return {
            "status": "iam_access_denied",
            "http_status": 403,
            "iam_principal": iam_email,
            "delegated_by_agent": "pulse-concierge-prod",
            "error": f"BigQuery IAM 403 Access Denied: {first_line}",
        }
    except Exception as exc:
        return {
            "status": "query_error",
            "http_status": 400,
            "iam_principal": iam_email,
            "delegated_by_agent": "pulse-concierge-prod",
            "error": str(exc),
        }


def lookup_knowledge_catalog(search_query: str) -> dict:
    """Search Pulse Telco's Knowledge Catalog for table schemas, governance aspects, join keys, and official business KPI definitions.

    Args:
        search_query: Domain or metric keyword such as 'crm', 'billing', 'network', 'churn', 'arpu', 'delinquent', or 'all'.

    Returns:
        A dictionary containing matching table metadata (governance + semantics aspects) and canonical glossary terms.
    """
    q = search_query.strip().lower()
    tables = {}
    for name, meta in _KC_SPECS["table_metadata"].items():
        haystack = json.dumps(meta).lower() + " " + name.lower()
        if q in ("all", "*", "") or any(w in haystack for w in q.split()):
            tables[name] = meta
    if not tables:
        tables = _KC_SPECS["table_metadata"]
    return {
        "status": "success",
        "matched_tables": tables,
        "glossary_terms": _KC_SPECS["glossary_terms"],
    }


def query_crm_domain(
    region_code: str,
    segment: str,
    only_high_churn: bool,
    tool_context: ToolContext,
) -> dict:
    """Query the live BigQuery telco_crm dataset as the signed-in user (session user_id), with that user's own OAuth 2.0 credentials.

    Args:
        region_code: Region filter: 'PRG', 'BRN', 'OVA', 'BTS', 'VIE', or 'ALL'.
        segment: Customer segment filter: 'consumer', 'sme', 'enterprise', or 'ALL'.
        only_high_churn: If True, filter to High Churn Risk subscribers (churn_risk_score >= 0.70 per Knowledge Catalog).

    Returns:
        Dictionary with 'status', 'iam_principal', 'kpis', and 'sample_subscribers'.
    """
    reg = region_code.strip().upper()
    seg = segment.strip().lower()

    where_clauses = ["s.account_status = 'active'"]
    if reg not in ("ALL", "*", ""):
        where_clauses.append(f"UPPER(s.region_code) = '{reg}'")
    if seg not in ("all", "*", ""):
        where_clauses.append(f"LOWER(s.customer_segment) = '{seg}'")
    where_sql = " AND ".join(where_clauses)

    sql = f"""
    SELECT
        s.subscriber_id,
        s.region_code,
        s.customer_segment,
        s.tenure_months,
        s.churn_risk_score,
        s.nps_band,
        p.subscription_id,
        p.service_type,
        p.tariff_name,
        p.monthly_recurring_eur
    FROM `{PROJECT_ID}.telco_crm.subscribers` AS s
    LEFT JOIN `{PROJECT_ID}.telco_crm.subscriptions` AS p
      ON s.subscriber_id = p.subscriber_id AND p.subscription_status = 'active'
    WHERE {where_sql}
    ORDER BY s.churn_risk_score DESC, s.subscriber_id
    """
    res = query_bigquery_as_user(sql, tool_context)
    if res["status"] != "success":
        return res

    rows = res["rows"]
    seen_subs = {}
    active_plans = []
    for r in rows:
        sid = r["subscriber_id"]
        if sid not in seen_subs:
            seen_subs[sid] = {
                "subscriber_id": sid,
                "region_code": r["region_code"],
                "customer_segment": r["customer_segment"],
                "tenure_months": r["tenure_months"],
                "churn_risk_score": r["churn_risk_score"],
                "nps_band": r["nps_band"],
            }
        if r.get("subscription_id"):
            active_plans.append(r)

    all_active_subs = list(seen_subs.values())
    high_churn_subs = [s for s in all_active_subs if float(s["churn_risk_score"] or 0) >= 0.70]
    filtered_subs = high_churn_subs if only_high_churn else all_active_subs
    filtered_ids = {s["subscriber_id"] for s in filtered_subs}
    matching_plans = [p for p in active_plans if p["subscriber_id"] in filtered_ids]

    total_mrr = round(sum(float(p["monthly_recurring_eur"] or 0) for p in matching_plans), 2)
    arpu = round(total_mrr / len(matching_plans), 2) if matching_plans else 0.0
    churn_rate = round(100.0 * len(high_churn_subs) / len(all_active_subs), 1) if all_active_subs else 0.0

    return {
        "status": "success",
        "iam_principal": res["iam_principal"],
        "delegated_by_agent": res["delegated_by_agent"],
        "bigquery_job_id": res["job_id"],
        "filters": {"region_code": reg, "segment": seg, "only_high_churn": only_high_churn},
        "kpis": {
            "active_subscribers": len(all_active_subs),
            "high_churn_subscribers": len(high_churn_subs),
            "high_churn_rate_pct": churn_rate,
            "matching_active_subscriptions": len(matching_plans),
            "total_mrr_eur": total_mrr,
            "active_subscription_arpu_eur": arpu,
        },
        "sample_subscribers": filtered_subs[:12],
    }


def query_billing_domain(
    billing_period: str,
    payment_status: str,
    subscriber_id: str,
    tool_context: ToolContext,
) -> dict:
    """Query the live BigQuery telco_billing dataset as the signed-in user (session user_id), with that user's own OAuth 2.0 credentials.

    Args:
        billing_period: Billing month filter: '2026-07', '2026-08', or 'ALL'.
        payment_status: Invoice status filter: 'paid', 'overdue', 'disputed', or 'ALL'.
        subscriber_id: Optional subscriber ID (e.g. 'SUB-1001') or 'ALL' for aggregate analysis.

    Returns:
        Dictionary with 'status' ('success' or 'iam_access_denied'), 'iam_principal', 'kpis', and 'sample_invoices'.
    """
    per = billing_period.strip()
    st = payment_status.strip().lower()
    sub = subscriber_id.strip().upper()

    where_clauses = ["1=1"]
    if per not in ("ALL", "all", "*", ""):
        where_clauses.append(f"billing_period = '{per}'")
    if sub not in ("ALL", "*", ""):
        where_clauses.append(f"UPPER(subscriber_id) = '{sub}'")
    where_sql = " AND ".join(where_clauses)

    sql = f"""
    SELECT
        invoice_id,
        subscriber_id,
        billing_period,
        total_amount_eur,
        payment_status,
        days_past_due,
        due_date
    FROM `{PROJECT_ID}.telco_billing.invoices`
    WHERE {where_sql}
    ORDER BY total_amount_eur DESC, invoice_id
    """
    res = query_bigquery_as_user(sql, tool_context)
    if res["status"] != "success":
        return res

    invs = res["rows"]
    total_billed = round(sum(float(i["total_amount_eur"] or 0) for i in invs), 2)
    paid_eur = round(sum(float(i["total_amount_eur"] or 0) for i in invs if i["payment_status"] == "paid"), 2)
    overdue_eur = round(sum(float(i["total_amount_eur"] or 0) for i in invs if i["payment_status"] == "overdue"), 2)
    delinquent_30d_eur = round(
        sum(float(i["total_amount_eur"] or 0) for i in invs if i["payment_status"] == "overdue" and int(i["days_past_due"] or 0) >= 30),
        2,
    )
    disputed_eur = round(sum(float(i["total_amount_eur"] or 0) for i in invs if i["payment_status"] == "disputed"), 2)

    filtered = [i for i in invs if i["payment_status"] == st] if st not in ("all", "*", "") else invs

    return {
        "status": "success",
        "iam_principal": res["iam_principal"],
        "delegated_by_agent": res["delegated_by_agent"],
        "bigquery_job_id": res["job_id"],
        "filters": {"billing_period": per, "payment_status": st, "subscriber_id": sub},
        "kpis": {
            "invoice_count": len(filtered),
            "total_billed_eur": total_billed,
            "paid_eur": paid_eur,
            "overdue_total_eur": overdue_eur,
            "delinquent_30d_exposure_eur": delinquent_30d_eur,
            "disputed_exposure_eur": disputed_eur,
        },
        "sample_invoices": filtered[:12],
    }


def run_python(code: str, tool_context: ToolContext) -> dict:
    """Execute Python code (pandas, numpy, scipy) in an isolated Agent Runtime Code Execution sandbox.

    Use this tool whenever asked to compute statistical metrics, standard deviations, shares, correlations, or
    revenue/churn projections on numbers fetched from BigQuery. Always print() your final answers.

    Args:
        code: Complete Python 3 script using standard library, pandas, or numpy. Must print() results to stdout.

    Returns:
        A dictionary with 'status' ('success' or 'error'), 'stdout', 'stderr', and 'sandbox'.
    """
    project = os.environ.get("GOOGLE_CLOUD_PROJECT", PROJECT_ID)
    location = os.environ.get("GOOGLE_CLOUD_AGENT_ENGINE_LOCATION") or os.environ.get("PULSE_REGISTRY_LOCATION", "europe-west1")
    engine_id = os.environ.get("GOOGLE_CLOUD_AGENT_ENGINE_ID") or os.environ.get("PULSE_PROD_AGENT_ENGINE_ID", "")
    if not engine_id:
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                exec(code, {"__builtins__": __builtins__}, {})
            return {"status": "success", "stdout": buf.getvalue().strip(), "stderr": "", "sandbox": "local"}
        except Exception as e:
            return {"status": "error", "stdout": buf.getvalue().strip(), "stderr": str(e), "sandbox": "local"}

    engine_name = f"projects/{project}/locations/{location}/reasoningEngines/{engine_id}"
    vclient = vertexai.Client(project=project, location=location)
    sandbox_name = tool_context.state.get("sandbox_name")
    if not sandbox_name:
        op = vclient.agent_engines.sandboxes.create(
            spec={"code_execution_environment": {}},
            name=engine_name,
            config=vtypes.CreateAgentEngineSandboxConfig(display_name="pulse-prod-sandbox", ttl="600s"),
        )
        sandbox_name = op.response.name
        tool_context.state["sandbox_name"] = sandbox_name

    resp = vclient.agent_engines.sandboxes.execute_code(name=sandbox_name, input_data={"code": code})
    stdout, stderr = "", ""
    for chunk in resp.outputs:
        if chunk.mime_type == "application/json":
            data = json.loads(chunk.data.decode())
            stdout += data.get("msg_out", "")
            stderr += data.get("msg_err", "")
    return {"status": "success" if not stderr else "error", "stdout": stdout.strip(), "stderr": stderr.strip(), "sandbox": sandbox_name.split("/")[-1]}
