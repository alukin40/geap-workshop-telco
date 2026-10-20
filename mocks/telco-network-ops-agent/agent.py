"""Pulse Telco Network Operations (NOC) Desk - an ADK domain agent exposed over A2A.

Deployed to Cloud Run in Lab06. The Pulse Concierge orchestrator delegates 5G/fiber
network diagnostics and field-engineering dispatch requests to it through Agent Gateway,
so participants can see agent-to-agent (A2A) traffic being governed and inspected.
"""
import asyncio
import os
import random

import uvicorn
from google.adk.a2a.utils.agent_card_builder import AgentCardBuilder
from google.adk.a2a.utils.agent_to_a2a import to_a2a
from google.adk.agents import Agent

_TICKETS: dict[str, dict] = {}

_TOWERS = {
    "TWR-PRG-01": {"site_name": "Prague Central 5G Macro", "region_code": "PRG", "radio_tech": "5G_SA", "avg_utilization_pct": 64.2, "packet_loss_pct": 0.04, "operational_state": "healthy", "active_incident": None},
    "TWR-PRG-02": {"site_name": "Prague TechHub East 5G", "region_code": "PRG", "radio_tech": "5G_SA", "avg_utilization_pct": 93.8, "packet_loss_pct": 2.85, "operational_state": "degraded", "active_incident": "INC-7001 (P1_CRITICAL, fiber_cut, 1450 est. affected subscribers)"},
    "TWR-PRG-03": {"site_name": "Prague West Residential", "region_code": "PRG", "radio_tech": "5G_NSA", "avg_utilization_pct": 58.0, "packet_loss_pct": 0.08, "operational_state": "healthy", "active_incident": None},
    "TWR-BRN-01": {"site_name": "Brno City Center 5G", "region_code": "BRN", "radio_tech": "5G_SA", "avg_utilization_pct": 61.4, "packet_loss_pct": 0.05, "operational_state": "healthy", "active_incident": None},
    "TWR-BRN-02": {"site_name": "Brno Science Park 5G", "region_code": "BRN", "radio_tech": "5G_SA", "avg_utilization_pct": 89.4, "packet_loss_pct": 1.92, "operational_state": "degraded", "active_incident": "INC-7002 (P2_MAJOR, ran_congestion, 680 est. affected subscribers)"},
    "TWR-OVA-02": {"site_name": "Ostrava Logistics Zone", "region_code": "OVA", "radio_tech": "LTE_A", "avg_utilization_pct": 79.2, "packet_loss_pct": 0.45, "operational_state": "maintenance", "active_incident": "INC-7003 (P3_MINOR, scheduled_upgrade)"},
    "TWR-BTS-01": {"site_name": "Bratislava Old Town 5G", "region_code": "BTS", "radio_tech": "5G_SA", "avg_utilization_pct": 67.8, "packet_loss_pct": 0.06, "operational_state": "healthy", "active_incident": None},
    "TWR-VIE-01": {"site_name": "Vienna Danube Tower 5G", "region_code": "VIE", "radio_tech": "5G_SA", "avg_utilization_pct": 69.1, "packet_loss_pct": 0.04, "operational_state": "healthy", "active_incident": None},
}


def diagnose_tower_status(tower_id_or_region: str) -> dict:
    """Inspect live 5G/LTE cell tower telemetry and active outages by tower ID (e.g. TWR-PRG-02) or region code (PRG, BRN, OVA, BTS, VIE).

    Args:
        tower_id_or_region: A tower ID such as TWR-PRG-02 or a region code such as PRG or BRN.

    Returns:
        A dictionary with 'status' and matching tower telemetry + active incident details.
    """
    q = tower_id_or_region.strip().upper()
    if q in _TOWERS:
        return {"status": "success", "tower_id": q, **_TOWERS[q]}
    matches = {tid: info for tid, info in _TOWERS.items() if info["region_code"] == q or q in info["site_name"].upper()}
    if matches:
        return {"status": "success", "query": q, "towers": matches}
    return {"status": "success", "query": q, "towers": _TOWERS}


def open_noc_dispatch_ticket(tower_id: str, reason: str) -> dict:
    """Open a field-engineering NOC dispatch ticket (NOC-xxxxxx) for a degraded cell tower or outage.

    Args:
        tower_id: The Pulse Telco cell tower ID, e.g. TWR-PRG-02.
        reason: Why field dispatch or traffic rerouting is requested (e.g. fiber cut, high packet loss, MIMO congestion).

    Returns:
        A dictionary with 'status' ('success'), the new 'ticket_id' (NOC-xxxxxx), 'tower_id', and 'next_steps'.
    """
    ticket_id = f"NOC-{random.randint(100000, 999999)}"
    _TICKETS[ticket_id] = {"tower_id": tower_id.upper(), "reason": reason, "status": "crew_dispatched"}
    return {
        "status": "success",
        "ticket_id": ticket_id,
        "tower_id": tower_id.upper(),
        "next_steps": f"Field crew dispatched for: {reason}. 2-hour SLA; traffic rerouted where possible. (Demo: tickets are kept in memory only.)",
    }


def get_noc_ticket_status(ticket_id: str) -> dict:
    """Check the status of an existing NOC field dispatch ticket by its ticket ID (e.g. NOC-123456).

    Args:
        ticket_id: The NOC ticket number, e.g. NOC-123456.

    Returns:
        A dictionary with 'status' ('success' or 'not_found') and ticket details.
    """
    t = _TICKETS.get(ticket_id.upper())
    return {"status": "success", "ticket": t} if t else {"status": "not_found", "ticket_id": ticket_id}


from google.adk.models.google_llm import Gemini
from google.genai import types

root_agent = Agent(
    name="pulse_network_ops_agent",
    model=Gemini(
        model=os.environ.get("MODEL", "gemini-3.8-flash"),
        retry_options=types.HttpRetryOptions(
            attempts=6, initial_delay=3.0, exp_base=2.0, http_status_codes=[429, 500, 502, 503, 504]
        ),
    ),
    description="Handles 5G/fiber network diagnostics and opens NOC field dispatch tickets for Pulse Telco cell towers.",
    instruction=(
        "You are the Pulse Telco Network Operations Center (NOC) specialist agent. "
        "Use diagnose_tower_status to inspect cell tower utilization, packet loss, and active outages. "
        "Use open_noc_dispatch_ticket when asked to escalate or dispatch a field crew for a tower, "
        "and get_noc_ticket_status for ticket follow-ups. Always include the ticket ID (NOC-xxxxxx) and next steps. Be concise."
    ),
    tools=[diagnose_tower_status, open_noc_dispatch_ticket, get_noc_ticket_status],
)

# Public URL advertised in the agent card (Cloud Run URLs are deterministic per project number).
# We build the card ourselves so the advertised URL has no explicit ":443" port - Agent Gateway
# matches registered destinations by exact hostname/URL.
_host = os.environ.get("A2A_HOST", "localhost")
if os.environ.get("K_SERVICE") and _host == "localhost":
    raise RuntimeError("A2A_HOST must be set on Cloud Run (the public host name advertised in the agent card)")
_port = int(os.environ.get("PORT", "8080"))
_rpc_url = f"https://{_host}/" if _host != "localhost" else f"http://localhost:{_port}/"
_card = asyncio.run(AgentCardBuilder(agent=root_agent, rpc_url=_rpc_url).build())
a2a_app = to_a2a(root_agent, agent_card=_card, host=_host, port=_port)

if __name__ == "__main__":
    uvicorn.run(a2a_app, host="0.0.0.0", port=_port)
