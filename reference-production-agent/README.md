# Pulse Telco: Standalone End-State Reference Production Agent (*pulse-concierge-prod*)

## Architectural Intent: From Lab Notebook to Repeatable Deployment

Interactive notebooks are ideal for learning a platform step by step, where you inspect one layer at a time and mutate configuration between cells. Production engineering has the opposite requirement: you want a single declarative definition that takes an empty Google Cloud project (with billing attached) to a verified, working multi-agent system in one pass.

This directory packages the complete end-state Pulse Telco architecture (*pulse-concierge-prod*) as a self-contained **Agent Development Kit (ADK)** codebase and **Terraform** stack. It has zero dependency on the workshop notebooks (*labs/*) having been run first, and running the labs in the same project will never overwrite this agent:

* **Isolated runtime & guardrails**: Deploys its own Agent Runtime instance (*pulse-concierge-prod*), its own Model Armor templates (*pulse-prod-guard-input* and *pulse-prod-guard-output*), and its own local deployment metadata (*pulse-concierge-prod/deployment_metadata.json*).
* **Idempotent shared foundation**: When deployed into a project where the workshop labs already ran, shared data and microservice names (BigQuery datasets, persona service accounts, Cloud Run endpoints, and Agent Registry entries) are adopted cleanly rather than duplicated.

---

## Architecture & Provisioned Stack

To satisfy strict European telecommunications data residency, inference and storage resources are pinned to **EU multi-region endpoints** first (*eu* for Gemini text, Live voice, and Knowledge Catalog; *EU* for BigQuery), while stateful compute and control-plane components run in a single regional footprint (*region*, defaulting to *europe-west4*).

| Architectural Layer | Provisioned Resources & Runtime Role |
| :--- | :--- |
| **Analytical Data & Semantics** | Three EU BigQuery datasets (*telco_crm*, *telco_billing*, *telco_network*) seeded from the synthetic JSON files in *data/*, annotated with table descriptions, labels, and **Knowledge Catalog** aspect types (*telco-governance* and *telco-semantics*). |
| **Identity & Access Boundaries** | Two user-persona service accounts: *persona-alex-exec* (granted read access to all 3 datasets) and *persona-elena-care* (granted read access to *telco_crm* only), plus *roles/bigquery.jobUser*. The deployed agent receives its own SPIFFE **Agent Identity** and permission to mint short-lived credentials for those two personas. |
| **Remote Microservices & Registry** | Cloud Run services *pulse-iam-context-mcp* (FastMCP server) and *pulse-network-ops-agent* (A2A v0.3 NOC specialist), plus **Agent Registry** entries (*MCP_SERVER* with *readOnlyHint* tool specs, *AGENT* card, and *ENDPOINT* entries for Google APIs). |
| **Inline Guardrails** | **Model Armor** templates *pulse-prod-guard-input* (screening Responsible AI, Sensitive Data Protection, malicious URIs, and prompt injection / jailbreaks) and *pulse-prod-guard-output* (screening RAI, SDP, and malicious URIs). The in-process plugin fails closed on any policy violation. |
| **Agent Runtime Engine** | *pulse-concierge-prod* deployed to **Agent Runtime** via *agents-cli deploy* with *--agent-identity*, followed immediately by an automated three-stage verification suite. |
| **Network Egress Control (Optional)** | **Agent Gateway** forward proxy stack (*enable_agent_gateway = true*, detailed below) enforcing outbound destination and per-tool CEL policies on the wire. |

### How Runtime Governance Works Under the Hood

System prompts can guide how an agent plans a query, but prompts are not an access-control boundary. *pulse-concierge-prod* enforces least privilege at the infrastructure layer while supporting both text and voice in a single conversation:

1. **Unified Multimodal Session**: The root orchestrator runs *gemini-3.8-flash* for text chat and *gemini-3.8-live* for bidirectional voice inside the exact same *session_id*, sharing conversation history and tool state.
2. **Caller-Scoped BigQuery Execution**: Instead of executing SQL under a single over-privileged agent credential, the agent resolves the caller's session *user_id* (*persona-alex-exec* or *persona-elena-care*) into short-lived OAuth 2.0 credentials for that specific persona. BigQuery IAM evaluates every query directly (returning HTTP 200 for allowed datasets and HTTP 403 for restricted datasets), and Cloud Audit Logs record the caller persona rather than a generic bot account. Unknown caller IDs receive zero BigQuery privileges.
3. **Full Platform Tooling**: Integrates Google-managed BigQuery and Knowledge Catalog MCP servers, the custom IAM Context MCP server, the remote NOC A2A specialist agent, ADK Skills, per-user Memory Bank, a managed Code Execution Sandbox, and mandatory Model Armor screening.

---

## Deploying & Verifying the Stack

### Prerequisites

* *gcloud* CLI and Application Default Credentials (ADC) authenticated as the same identity with Owner permissions on the target project (*<YOUR_PROJECT_ID>*, such as *pulse-telco-gw-demo*).
* Terraform >= 1.5, *uv*, and *agents-cli* installed locally:

```bash
uv tool install google-agents-cli==1.10.0
```

### Provisioning Commands

```bash
cd reference-production-agent/terraform
cp terraform.tfvars.example terraform.tfvars   # set project_id = "<YOUR_PROJECT_ID>"; set region if not europe-west4
terraform init
terraform apply                                # takes ~25-35 min on an empty project
```

### Automated Post-Deploy Verification (*scripts/deploy_and_verify.py*)

A deployment that only checks whether a container started gives false confidence. Whenever the agent code, environment configuration, or gateway binding changes, Terraform runs *scripts/deploy_and_verify.py* and fails the apply unless all three architectural invariants hold:

1. **Cloud Control-Plane & Tool Routing**: Sends a live query to the deployed *pulse-concierge-prod* engine as *persona-alex-exec*, verifying BigQuery execution, the IAM Context MCP tool call (*resolve_user_context*), and remote A2A delegation to the NOC desk (*pulse_network_ops_desk*).
2. **Multimodal Session Continuity**: Runs the identical agent package in-process across **Text Chat -> Live Voice -> Text Chat** inside a single *session_id*, asserting that the Live API returns synthesized audio frames and preserves context across modality switches.
3. **Cryptographic IAM Enforcement**: Executes billing queries under both personas and verifies that *persona-alex-exec* succeeds (HTTP 200 on *telco_billing*) while *persona-elena-care* is rejected by BigQuery IAM (*iam_access_denied* / HTTP 403).

The structured verification report is written to *pulse-concierge-prod/.prod_verification_report.json*.

**Teardown Behavior (*terraform destroy*):** Running *terraform destroy* removes the Terraform-managed data, IAM, and Cloud Run resources, but intentionally leaves the Agent Runtime engine (delete via the Cloud Console or *agents-cli*), shared Agent Registry entries, and project-level Organization Policy overrides if you enabled them.

---

## Directory Structure

```text
reference-production-agent/
├── README.md                    # Architectural overview and deployment guide
├── AGENT_GATEWAY_DEMO.md        # Validation runbook for the optional Agent Gateway
├── pulse-concierge-prod/        # Self-contained ADK agent package (app/, Dockerfile, pyproject.toml, uv.lock)
└── terraform/
    ├── main.tf                  # APIs, BigQuery + data, personas, Cloud Run MCP + NOC, registry, Model Armor, agent deploy
    ├── gateway.tf               # Optional egress Agent Gateway stack (enable_agent_gateway)
    ├── variables.tf / outputs.tf / versions.tf
    ├── terraform.tfvars.example
    └── scripts/
        ├── deploy_and_verify.py # agents-cli deploy (optionally gateway-bound), Agent Identity roles, verification
        ├── seed_data.py         # BigQuery load + Knowledge Catalog aspects
        ├── deploy_cloud_run.sh  # Cloud Run source deploy of the two mock services
        ├── ensure_registry.sh   # Agent Registry entries (MCP tool spec, NOC agent card, Google API endpoints)
        └── gateway_demo.py      # Helper CLI: ask / gateway logs / flip DRY_RUN <-> ENFORCED
```

---

## Optional: Network Egress Governance with Agent Gateway (*enable_agent_gateway*)

In-process guardrails (*ModelArmorPlugin*, Python callbacks) protect an agent from within its own container, but a compromised dependency or misconfigured tool inside the container could still open raw outbound connections. **Agent Gateway** moves egress control out of the application process and into a Google-managed network proxy attached directly to the Agent Runtime instance.

By default, *enable_agent_gateway* is set to *false* so the base deployment works in any standard project without requiring Organization Policy administrator privileges. When you set *enable_agent_gateway = true*, Terraform provisions the *pulse-prod-egress-gateway* stack (*terraform/gateway.tf*) and rebinds *pulse-concierge-prod* so every outbound call (to Gemini, MCP servers, the NOC A2A agent, and Google APIs) is inspected against **Agent Registry** metadata and an **IAM v3 access policy** scoped to the agent's SPIFFE identity:

| Terraform Variable | Default | Architectural Role & Trade-Off |
| :--- | :--- | :--- |
| *enable_agent_gateway* | *false* | Provisions the egress gateway stack and binds the Agent Runtime instance to it. Toggling this variable rebuilds and redeploys the agent container (~10 to 12 minutes) because the runtime injects the proxy root CA. |
| *agent_gateway_enforcement* | *"DRY_RUN"* | Controls IAP policy enforcement. *"DRY_RUN"* logs every MCP tool call and the allow/deny decision IAP would take without breaking traffic; *"ENFORCED"* blocks any unapproved destination or mutating MCP tool call at the proxy edge (~2 minutes to toggle, zero agent redeploy). |
| *agent_gateway_model_armor* | *true* | Attaches a *CONTENT_AUTHZ* service extension so Model Armor screens MCP and A2A payloads on the wire. Always enforces blocking (no dry-run mode). |
| *apply_org_policy_overrides* | *false* | Relaxes *iam.managed.disableAccessPolicyBinding* (and *iam.allowedPolicyMemberDomains* when gateway Model Armor is active) on the project. Required in organizations where IAM v3 access policy bindings are disabled by default; requires Organization Policy Admin rights. |

```bash
# Enable the egress gateway stack in DRY_RUN mode (requires Org Policy Admin if overrides are enabled)
terraform apply -var enable_agent_gateway=true -var apply_org_policy_overrides=true

# Disable the egress gateway stack and rebind the agent to direct egress
terraform apply -var enable_agent_gateway=false
```

For the three-stage validation runbook, Cloud Logging queries, and architectural trade-offs, see [AGENT_GATEWAY_DEMO.md](AGENT_GATEWAY_DEMO.md).

**Single Egress Gateway Constraint per Project:** Agent Runtime allows only one *AGENT_TO_ANYWHERE* Agent Gateway per Google Cloud project. Attempting to create a second gateway fails with *"Another Agent Gateway is already active or being created for this project and direction"*. If you previously created *pulse-egress-gateway* in an earlier lab run, unbind that lab agent and delete its gateway resources (authorization policies, service extensions, and *pulse-egress-gateway*) before enabling the production gateway stack.
