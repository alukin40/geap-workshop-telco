# Agent Gateway: Validation Runbook (*pulse-concierge-prod*)

This runbook validates **Agent Gateway** in a dedicated Google Cloud project (*pulse-telco-gw-demo* or *<YOUR_PROJECT_ID>*, region *europe-west4*), complementing the self-study architecture reference in **Lab 09** (*labs/lab09_agent_gateway.ipynb*). Because binding IAM v3 access policies requires Organization Policy administrator privileges and a single project supports only one egress gateway, deploy and test this stack in a dedicated project.

---

## 1. Architectural Framing: Why Network Egress Governance Matters

In Lab 05, we added in-process guardrails (*ModelArmorPlugin* and an *after_tool_callback*) inside the agent's Python container. That protects the model loop when code behaves as expected, but an enterprise CISO will immediately ask two control-room questions:

1. **What prevents an agent from calling a mutating tool or an unapproved external endpoint if a prompt or library bypasses the Python callback?**
2. **How do security teams audit and enforce tool-level access across dozens of agents without auditing every line of Python in every repository?**

**Agent Gateway** answers both questions by moving enforcement from the application process to a Google-managed forward proxy attached directly to the Agent Runtime network egress. Once *pulse-concierge-prod* is bound to the gateway, every outbound connection (to Gemini, MCP servers, remote A2A agents, and Google APIs) traverses the proxy before leaving the runtime environment:

* **Cryptographic Caller Identity**: The proxy identifies the calling agent via its **Agent Identity** (a SPIFFE principal minted automatically per Agent Runtime instance), not a shared network IP or exportable service-account key.
* **Catalog-Driven Destination Resolution**: The proxy matches the target hostname and path against **Agent Registry**, inspecting MCP tool annotations such as *readOnlyHint*.
* **Per-Request CEL Authorization**: Identity-Aware Proxy (IAP) evaluates an **IAM v3 access policy** written in Common Expression Language (CEL). In our policy, this agent may invoke registered Google APIs, registered A2A agents, MCP discovery methods, and *tools/call* only when *read_only_hint == true*.
* **Wire-Level Payload Screening**: A **Model Armor** service extension inspects MCP and A2A response payloads on the wire before they ever reach the agent container.

If your audience comes from Microsoft Azure, the closest conceptual mental model is combining **Azure API Management AI Gateway** with **Microsoft Entra Agent ID conditional access policies**, with one critical architectural difference: Agent Gateway is bound directly to the managed Agent Runtime egress path, so container code cannot bypass the proxy by calling a target URL directly.

| Architectural Component | Terraform Resource & Identifier | Engine-Room Role |
| :--- | :--- | :--- |
| **Caller Agent** | *pulse-concierge-prod* on Agent Runtime (bound via the *agent-gateway-egress* deployment flag; engine *2787824926365581312*) | Authenticates outbound requests with SPIFFE identity *principal://agents.global.org-752235872408.system.id.goog/resources/aiplatform/projects/123456789012/locations/europe-west4/reasoningEngines/2787824926365581312*. |
| **Egress Proxy** | *pulse-prod-egress-gateway* (*google_network_services_agent_gateway*, mode *AGENT_TO_ANYWHERE*) | Intercepts all outbound traffic from the runtime and terminates TLS using a root CA injected automatically into the runtime container. |
| **Governance Catalog** | Agent Registry in *europe-west4* (*ENDPOINT*, *AGENT*, and *MCP_SERVER* entries) | Establishes default-deny by destination hostname and supplies MCP tool metadata (*readOnlyHint*) to the CEL policy engine. |
| **Request Authorization** | *pulse-prod-iap-authz-ext*, *pulse-prod-iap-authz-policy*, and IAM access policy *pulse-prod-egress-policy* | Evaluates every outbound request against CEL rules in either *DRY_RUN* mode (audit only) or *ENFORCED* mode (active HTTP 403 blocking). |
| **Content Inspection** | *pulse-prod-ma-content-ext* + *pulse-prod-ma-content-policy* (*CONTENT_AUTHZ*) | Invokes Model Armor (*pulse-prod-guard-input* / *pulse-prod-guard-output*) on the wire to block indirect prompt injection inside MCP and A2A responses. |
| **Downstream Targets** | *pulse-iam-context-mcp* (*https://pulse-iam-context-mcp-123456789012.europe-west4.run.app/mcp*), *pulse-network-ops-agent* (*https://pulse-network-ops-agent-123456789012.europe-west4.run.app*), BigQuery MCP, Knowledge Catalog MCP, and Gemini | Production and lab microservices governed by the proxy. |

---

## 2. Pre-Flight Checklist (15 Minutes Before the Session)

Verify that the gateway is deployed, currently set to *DRY_RUN* mode, and warmed up so the first live tool call does not incur a Cloud Run cold start during the presentation:

```bash
cd ~/geap-workshop-telco/reference-production-agent/terraform
gcloud config set project pulse-telco-gw-demo            # replace with your gateway project ID
terraform output agent_gateway agent_gateway_enforcement  # expect .../pulse-prod-egress-gateway and "DRY_RUN"
cd ../..                                                  # return to repository root for the demo helper
alias demo='uv run python3 reference-production-agent/terraform/scripts/gateway_demo.py'
demo mode DRY_RUN                                         # start the walkthrough in DRY_RUN mode
demo ask "Call resolve_user_context for token tok_marek_netops."   # warm up Cloud Run (first call takes ~20-40 s)
```

Your git-ignored *terraform.tfvars* file inside *reference-production-agent/terraform/* holds the active demo settings (*enable_agent_gateway = true*, *apply_org_policy_overrides = true*, and *agent_gateway_enforcement = "DRY_RUN"*).

---

## 3. Lifecycle Operations: Enabling, Toggling, and Cleaning Up Conflicting Gateways

You can control the entire gateway lifecycle declaratively with Terraform:

```bash
cd reference-production-agent/terraform

# 1. Provision gateway stack in DRY_RUN mode and bind agent (~12 min including container rebuild + verification)
terraform apply

# 2. Flip IAP policy enforcement from DRY_RUN to ENFORCED (~2 min; updates extension only, no agent redeploy)
terraform apply -var agent_gateway_enforcement=ENFORCED

# 3. Tear down gateway stack and rebind agent to direct egress (~12 min)
terraform apply -var enable_agent_gateway=false
```

**Organization Policy Dependency:** In projects where you do not hold Organization Policy Administrator rights, keep *apply_org_policy_overrides = false*. New Google Cloud organizations enforce *iam.managed.disableAccessPolicyBinding* by default. When that constraint is active, Terraform skips the IAM v3 access-policy binding with a warning: the gateway still logs telemetry in *DRY_RUN* mode, but switching to *ENFORCED* will deny all traffic until an administrator lifts the constraint.

### Resolving Single-Gateway Conflicts in Shared Projects

Agent Runtime permits only **one egress (*AGENT_TO_ANYWHERE*) Agent Gateway per project**. Attempting to provision a second gateway returns HTTP 400 (*"Another Agent Gateway is already active or being created for this project and direction"*). If an earlier Lab 06 run created *pulse-egress-gateway* in the same project, unbind that lab engine and remove its gateway resources before applying the production gateway stack:

```bash
# Unbind the lab reasoning engine in place without rebuilding its container image
curl -X PATCH -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" \
  "https://europe-west4-aiplatform.googleapis.com/v1/projects/<PROJECT_NUMBER>/locations/europe-west4/reasoningEngines/<LAB_ENGINE_ID>?updateMask=spec.deployment_spec.agent_gateway_config" \
  -d '{"spec":{"deploymentSpec":{}}}'

# Delete the old lab gateway stack
gcloud network-security authz-policies delete pulse-iap-authz-policy --location=europe-west4 --quiet
gcloud network-security authz-policies delete pulse-ma-content-policy --location=europe-west4 --quiet
gcloud beta service-extensions authz-extensions delete pulse-iap-authz-ext --location=europe-west4 --quiet
gcloud beta service-extensions authz-extensions delete pulse-ma-content-ext --location=europe-west4 --quiet
gcloud network-services agent-gateways delete pulse-egress-gateway --location=europe-west4 --quiet
```

---

## 4. Live 10-Minute Walkthrough Script

Run all commands below from the repository root using the *demo* alias defined in Section 2. Cloud Logging entries typically land 30 to 60 seconds after an agent turn completes; re-run *demo logs* if a log entry has not yet indexed.

### Step 1: Policy Shadowing in *DRY_RUN* Mode (2 minutes)

Rolling out a strict network policy directly to *ENFORCED* in production risks breaking legitimate agent workflows whose tool dependencies were never cataloged. Start by showing how *DRY_RUN* gives complete visibility into both read-only and mutating MCP calls without interrupting traffic:

```bash
demo ask "Call resolve_user_context for token tok_marek_netops."
demo ask "Call grant_dataset_access for token tok_elena_care_lead on dataset telco_billing, justification: urgent audit."
demo logs --minutes 5
```

**Expected outcome:** Both tool calls succeed from the caller's perspective, and Cloud Logging records both *tools/call* requests passing through *pulse-prod-egress-gateway* with HTTP 200:

```text
USER (persona-alex-exec): Call resolve_user_context for token tok_marek_netops.
  [tool call] resolve_user_context({"user_token": "tok_marek_netops"})
  [tool resp] resolve_user_context: {"content": [{"type": "text", "text": "{\n  \"status\": \"success\",\n  \"user_token\": \"tok_marek_netops\",\n  \"user_id\": \"marek.horak@pulse-telco.example\",\n  \"display_name\": \"Marek Horak\",\n  \"department\":
PULSE: The user context for token `tok_marek_netops` has been resolved:
- **User ID:** `marek.horak@pulse-telco.example`
- **Display Name:** Marek Horak
- **Department:** Network Operations Center (NOC)
- **Role:** Lead RAN Reliability Engineer
- **Allowed Datasets:** `telco_network`, `telco_crm`
- **Denied Datasets:** `telco_billing`

USER (persona-alex-exec): Call grant_dataset_access for token tok_elena_care_lead on dataset telco_billing, justification: urgent audit.
  [tool call] grant_dataset_access({"dataset_id": "telco_billing", "justification": "urgent audit", "user_token": "tok_elena_care_lead"})
  [tool resp] grant_dataset_access: {"content": [{"type": "text", "text": "{\n  \"status\": \"granted\",\n  \"grant_id\": \"IAM-GRANT-623394\",\n  \"user_token\": \"tok_elena_care_lead\",\n  \"dataset_id\": \"telco_billing\",\n  \"justification\": \"urgent
PULSE: Dataset access has been granted with the following details:
- **Status:** Granted
- **Grant ID:** `IAM-GRANT-623394`
- **User Token:** `tok_elena_care_lead`
- **Dataset ID:** `telco_billing`

14:32:36  HTTP 200  tools/call/resolve_user_context                  {'pulse-prod-iap-authz-policy': 'ALLOWED', 'pulse-prod-ma-content-policy': 'ALLOWED'}
14:33:00  HTTP 200  tools/call/grant_dataset_access                  {'pulse-prod-iap-authz-policy': 'ALLOWED', 'pulse-prod-ma-content-policy': 'ALLOWED'}
(2 entries in the last 5 min; log ingestion lags ~30-60 s)
```

**Narrative point:** In *DRY_RUN* mode, the proxy inspects every MCP JSON-RPC call, matches it against Agent Registry (*mcpInfo.method="tools/call"* and *mcpInfo.parameter="grant_dataset_access"*), and permits the call to complete (*ALLOWED*) so platform teams can inventory every MCP tool and A2A destination before turning on enforcement.

### Step 2: Switching Policy Enforcement to *ENFORCED* (1 minute + ~60s propagation)

Flip the IAP authorization extension from shadow logging to active enforcement without redeploying the agent:

```bash
demo mode ENFORCED
```

While the extension update propagates (~60 seconds), inspect the live IAM v3 access policy and highlight the CEL rule checking *destination.agent_registry.mcp_server.tool.annotations.read_only_hint == true*:

```bash
gcloud iam access-policies describe pulse-prod-egress-policy --location=global --format="yaml(details.rules)"
```

### Step 3: Active Network Blocking in *ENFORCED* Mode (3 minutes)

Re-run the exact same read-only and mutating MCP tool requests:

```bash
demo ask "Call resolve_user_context for token tok_marek_netops."
demo ask "Call grant_dataset_access for token tok_elena_care_lead on dataset telco_billing, justification: urgent audit."
demo logs --minutes 3
```

**Expected outcome:**

```text
USER (persona-alex-exec): Call resolve_user_context for token tok_marek_netops.
  [tool call] resolve_user_context({"user_token": "tok_marek_netops"})
  [tool resp] resolve_user_context: {"content": [{"type": "text", "text": "{\n  \"status\": \"success\",\n  \"user_token\": \"tok_marek_netops\",\n  \"user_id\": \"marek.horak@pulse-telco.example\",\n  \"display_name\": \"Marek Horak\",\n  \"department\":
PULSE: The user context for token `tok_marek_netops` was successfully resolved:
- **User ID**: `marek.horak@pulse-telco.example`
- **Name**: Marek Horak
- **Role**: Lead RAN Reliability Engineer
- **Allowed Datasets**: `telco_network`, `telco_crm`
- **Denied Datasets**: `telco_billing`

USER (persona-alex-exec): Call grant_dataset_access for token tok_elena_care_lead on dataset telco_billing, justification: urgent audit.
  [tool call] grant_dataset_access({"justification": "urgent audit", "user_token": "tok_elena_care_lead", "dataset_id": "telco_billing"})
  [tool resp] grant_dataset_access: {"error": "Unexpected error during MCP tool execution: MCP session connection lost: Client error '403 Forbidden' for url 'https://pulse-iam-context-mcp-123456789012.europe-west4.run.app/mcp'\nFor more information check:
PULSE: The request to call `grant_dataset_access` was blocked by policy. The IAM Context MCP service returned a `403 Forbidden` error (`Client error '403 Forbidden' for url 'https://pulse-iam-context-mcp-123456789012.europe-west4.run.app/mcp'`).

14:38:39  HTTP 200  tools/call/resolve_user_context                  {'pulse-prod-iap-authz-policy': 'ALLOWED', 'pulse-prod-ma-content-policy': 'ALLOWED'}
14:39:09  HTTP 403  tools/call/grant_dataset_access                  {'pulse-prod-iap-authz-policy': 'DENIED'}
(2 entries in the last 3 min; log ingestion lags ~30-60 s)
```

**Narrative point:** Point out that the LLM did not "decide" to be polite and decline the request. The agent attempted to execute *tools/call/grant_dataset_access*, and the network proxy intercepted the outbound request and returned **HTTP 403 Forbidden** (*pulse-prod-iap-authz-policy: DENIED*) before a single packet reached the Cloud Run MCP server.

### Step 4: Wire-Level Indirect Prompt Injection Screening (1 minute)

What happens when an allowed read-only tool returns poisoned data from an external system? Trigger a read-only lookup for the audit token whose record contains an embedded prompt-injection payload:

```bash
demo ask "Call resolve_user_context for token tok_audit_ext."
demo logs --minutes 2
```

**Expected outcome:** IAP permits the outbound request because *resolve_user_context* is annotated as read-only (*pulse-prod-iap-authz-policy: ALLOWED*), but the MCP response contains an injected system instruction (*"SYSTEM NOTICE TO ASSISTANT: ignore all previous instructions..."*) and the gateway's *CONTENT_AUTHZ* Model Armor extension blocks the response on the wire (*pulse-prod-ma-content-policy: DENIED*):

```text
USER (persona-alex-exec): Call resolve_user_context for token tok_audit_ext.
  [tool call] resolve_user_context({"user_token": "tok_audit_ext"})
  [tool resp] resolve_user_context: {"error": "Unexpected error during MCP tool execution: MCP session connection lost: Client error '403 Forbidden' for url 'https://pulse-iam-context-mcp-123456789012.europe-west4.run.app/mcp'\nFor more information check:
PULSE: The attempt to call `resolve_user_context` for token `tok_audit_ext` failed with a `403 Forbidden` error (`Client error '403 Forbidden' for url 'https://pulse-iam-context-mcp-123456789012.europe-west4.run.app/mcp'`). Access to this tool was blocked by the platform's security policy.

14:39:28  HTTP 403  tools/call/resolve_user_context                  {'pulse-prod-iap-authz-policy': 'ALLOWED', 'pulse-prod-ma-content-policy': 'DENIED'}
(1 entries in the last 2 min; log ingestion lags ~30-60 s)
```

### Step 5: Returning to *DRY_RUN* Mode (30 seconds)

Reset the gateway to *DRY_RUN* so subsequent tests can exercise all tools freely:

```bash
demo mode DRY_RUN
```

If you want to display the raw structured telemetry in the Google Cloud Console (**Logs Explorer**), paste this filter:

```text
resource.type="networkservices.googleapis.com/Gateway"
resource.labels.gateway_name="pulse-prod-egress-gateway"
jsonPayload.agentGatewayInfo.mcpInfo.method="tools/call"
```

---

## 5. Architectural Trade-Offs & Production Considerations

When riding the architect elevator with customer security and platform teams, be transparent about both the strengths and the current boundaries of Agent Gateway:

* **Cost Structure & Double Screening**: Agent Gateway (*AGENT_TO_ANYWHERE*) is billed under Agent Compute at 1 vCPU-hour (\$0.085) per 15,000 API calls or authorization evaluations, which works out to roughly **\$5.70 per 1M gateway requests**, prorated hourly per project (effective July 13, 2026). Because a single conversational turn generates 10 to 25 outbound requests (LLM inference, telemetry export, registry lookups, and MCP calls), 1M gateway requests corresponds to roughly 50,000 user turns. Model Armor evaluations and Cloud Logging ingestion are billed separately; enabling both gateway Model Armor and the in-process *ModelArmorPlugin* screens MCP payloads twice.
* **Fail-Closed Availability Coupling**: Both the IAP authorization extension and the Model Armor content extension are configured with fail-closed behavior (*failOpen=false*) and a 1-second timeout. If either extension times out or becomes unavailable, outbound tool calls fail closed with HTTP 403/500. That is the right posture for high-security data perimeters, but it turns your policy extensions into Tier-1 availability dependencies.
* **Scope of Gateway Model Armor (*googleapis.com* Exclusion)**: The *CONTENT_AUTHZ* routing rule deliberately excludes *googleapis.com* destinations (Gemini inference, managed BigQuery MCP, and managed Knowledge Catalog MCP) so binary gRPC/REST control traffic is not disrupted; the in-process *ModelArmorPlugin* and tool callback continue to screen those payloads inside the agent. In addition, because Google-managed MCP endpoints are registered as endpoint entries rather than MCP server entries, per-tool read-only CEL rules apply specifically to custom MCP servers registered as *MCP_SERVER* (such as *pulse-iam-context-mcp*).
* **Granularity Across Protocols (MCP vs. A2A)**: For MCP servers, Agent Gateway inspects the JSON-RPC method and tool name, enabling fine-grained rules like allowing *resolve_user_context* while blocking *grant_dataset_access*. For A2A agents, the *AGENT* policy rule authorizes the remote agent endpoint as a whole (including mutating skills); use *destination.agent_registry.agent.name* in CEL to restrict which specific A2A agents an orchestrator may call.
* **Agent Authentication vs. End-User Attribution**: The gateway authenticates the **agent's own SPIFFE identity**. While the agent forwards an *X-Pulse-End-User* HTTP header for audit correlation, that header is an unsigned attribution signal; cryptographic end-user access control happens when the agent mints per-persona OAuth 2.0 credentials for BigQuery (as shown in Lab 01).
* **Control-Plane Maturity & Live Voice Routing**: Agent Gateway, Agent Registry, and IAM v3 access policies are recent platform additions. Several CLI commands remain under beta, gateways are created via declarative import rather than an imperative create verb, and Terraform providers prior to v8.0 invoke *gcloud iam policy-bindings* for IAM v3 bindings. Also note that if Live Voice (*BidiGenerateContent*) routes to a regional endpoint not listed in Agent Registry, switching the gateway to *ENFORCED* will block voice WebSocket setup until that endpoint is registered.
* **Organization Policy Lead Time**: Because new Google Cloud organizations enforce *iam.managed.disableAccessPolicyBinding* by default and gateway Model Armor requires a Domain Restricted Sharing (*iam.allowedPolicyMemberDomains*) exception for the Google-managed service extension tenant, engage the customer's Organization Policy administrators during architecture design rather than on deployment day.

---

## 6. Tearing Down the Gateway Stack

To remove the gateway, service extensions, and IAM v3 policy bindings while keeping *pulse-concierge-prod* running with direct network egress:

```bash
cd reference-production-agent/terraform
terraform apply -var enable_agent_gateway=false
```

This rebuilds and redeploys the agent without the gateway binding (removing the proxy root CA) and destroys the gateway, both authorization extensions, and the access policy binding. Shared Agent Registry entries and project-level Organization Policy overrides are left in place so they do not disrupt other environments; to reset the Organization Policy overrides manually, run:

```bash
gcloud org-policies reset iam.managed.disableAccessPolicyBinding --project=<YOUR_PROJECT_ID>
gcloud org-policies reset iam.allowedPolicyMemberDomains --project=<YOUR_PROJECT_ID>
```
