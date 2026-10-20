# Pulse Telco Network Operations (NOC) Desk (`telco-network-ops-agent`)

Remote ADK domain agent exposed over the **A2A protocol** (`to_a2a`), deployed to Cloud Run in **Lab06**, registered in **Agent Registry**, and governed via **Agent Gateway**.

Tools:
- `diagnose_tower_status(tower_id_or_region)` — returns live 5G/LTE cell tower telemetry (`avg_utilization_pct`, `packet_loss_pct`, `operational_state`) and active P1/P2 incidents from the `telco_network` domain.
- `open_noc_dispatch_ticket(tower_id, reason)` — opens a field-engineering NOC dispatch ticket (`NOC-xxxxxx`) for a degraded cell tower or fiber outage.
- `get_noc_ticket_status(ticket_id)` — checks the status of an existing NOC dispatch ticket.
