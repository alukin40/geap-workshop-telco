# Gemini Enterprise Agent Platform (GEAP): Pulse Telco Multi-Agent Workshop

## From Prototype Agents to Governed Enterprise Agentic Systems

Building an LLM demo that answers questions over a single CSV file takes an afternoon. Taking a multi-agent system into production at a regulated European telecommunications operator is an entirely different architectural problem. Executives and security officers care about strict **EU data residency**, **caller-scoped data access**, **prompt-injection resilience**, and **predictable unit economics**. Engineers care about **fast local iteration**, **cryptographic identity propagation**, **deterministic multi-step workflows**, and **repeatable evaluation**.

This hands-on workshop and Terraform reference architecture bridges both floors of the building on **Google Cloud's Gemini platform** (formerly Gemini Enterprise Agent Platform / GEAP). Using **Pulse Telco** (a fictional Central European telecommunications provider operating 5G mobile and 10G fiber networks across Prague, Brno, Ostrava, Bratislava, and Vienna), you will build, govern, evaluate, and deploy a **multimodal (Text Chat + Live Voice) multi-agent conversational analytics system** (*pulse-concierge*) alongside **deterministic graph workflows** (*pulse-workflow-agent*). Every lab runs as a self-contained **Jupyter Notebook** (Run All compatible) with **100% EU data residency** (*eu* / *EU* multi-regions and *europe-west4*).

**October 2026 Naming & Glossary Note ("Gemini is the Single Brand")**

| Term in Docs / CLI / SDK | Architectural Role & Meaning |
| :--- | :--- |
| **Gemini platform** (formerly GEAP / Vertex AI) | The underlying Google Cloud agent platform powering managed runtimes, memory, tool registries, guardrails, and evaluation (documentation under */gemini-enterprise-agent-platform/*, API endpoint *aiplatform.googleapis.com*). |
| **Gemini Enterprise** | The employee-facing workplace web application (*discoveryengine.googleapis.com*) and per-seat commercial subscription (Business, Standard, Plus, Frontline, and Pay-as-you-go editions). Agents are published to it via *agents-cli publish gemini* (Lab 10). |
| **Agent Runtime** (*reasoningEngines* / *agent_engines*) | Managed serverless hosting for ADK and A2A agents with autoscaling, managed **Sessions**, **Memory Bank**, and **Code Execution Sandboxes**. |
| **Agent Identity** (*principal://agents.global.org-...*) | Per-agent SPIFFE cryptographic identity provisioned automatically on Agent Runtime, enabling direct least-privilege IAM bindings without exportable service-account keys. |
| **Agent Registry & Skill Registry** (*agentregistry.googleapis.com*) | Central governance catalog for discovering A2A agents (*europe-west4*), MCP servers (*europe-west4*), and reusable ADK skills (*eu*). |
| **Knowledge Catalog** (formerly Dataplex Universal Catalog) | Business metadata and governance taxonomy (*dataplex.googleapis.com* in *eu*) attaching *telco-governance* and *telco-semantics* aspects to BigQuery tables. |
| **Agent Gateway** | Managed network egress proxy governing outbound agent-to-MCP and agent-to-A2A traffic (covered in the Lab 09 architecture reference and *reference-production-agent/terraform*). |

---

## Target Architecture (*pulse-concierge*)

```text
                       ┌──────────────────────────────────────────┐
                       │   Gemini Enterprise / Custom Web & Voice │
                       │  (persona-alex-exec / persona-elena-care)│
                       └────────────────────┬─────────────────────┘
                                            │ A2A / OAuth 2.0 / Live WebSocket
                                            ▼
┌───────────────────────────────────────────────────────────────────────────────────────┐
│                  GEAP Agent Runtime (europe-west4): pulse-concierge                   │
│                                                                                       │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐  │
│  │ Model Armor Guardrails (eu: pulse-guard-input / pulse-guard-output + Tool Hook) │  │
│  └────────────────────────────────────────┬────────────────────────────────────────┘  │
│                                           ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐  │
│  │ Root Orchestrator: pulse_concierge (MultimodalGemini: Chat + Live Voice)        │  │
│  │  • Text Chat (run_async -> gemini-3.8-flash @ eu) & Live Voice (run_live ->     │  │
│  │    gemini-3.8-live @ eu) in the EXACT SAME session_id                           │  │
│  │  • Phase 1 (Agent Identity) vs Phase 2 (Delegated User OAuth 2.0 Token)         │  │
│  │  • Resolves user RBAC via pulse-iam-context-mcp & KPIs via Knowledge Catalog    │  │
│  └──────┬─────────────────────────────────┬─────────────────────────────────┬──────┘  │
│         │ In-Process ADK                  │ In-Process ADK                  │ A2A     │
│         ▼                                 ▼                                 ▼         │
│  ┌──────────────────────────┐     ┌──────────────────────────┐     ┌────────────────┐ │
│  │ crm_domain_agent         │     │ billing_domain_agent     │     │ RemoteA2aAgent │ │
│  │ • Scoped: telco_crm      │     │ • Scoped: telco_billing  │     │ Delegation     │ │
│  │ • KC MCP + BigQuery MCP  │     │ • KC MCP + BigQuery MCP  │     └────────┬───────┘ │
│  │ • Skills + Code Sandbox  │     │ • Skills + Code Sandbox  │              │         │
│  └────────────┬─────────────┘     └────────────┬─────────────┘              │         │
└───────────────┼────────────────────────────────┼────────────────────────────┼─────────┘
                │                                │                            │
                ▼                                ▼                            ▼
┌───────────────────────────────────────────────────────────────────────────────────────┐
│              Agent Registry & Agent Gateway (europe-west4, IAM-Governed)              │
└───────┬───────────────────────────────┬─────────────────────────────┬─────────────────┘
        │                               │                             │
        ▼                               ▼                             ▼
┌──────────────────────┐   ┌───────────────────────────┐   ┌────────────────────────────┐
│ pulse-iam-context-mcp│   │ Knowledge Catalog MCP (eu)│   │ pulse-network-ops-agent    │
│ (Cloud Run MCP, ew4) │   │ & BigQuery MCP (EU)       │   │ (Cloud Run A2A, ew4)       │
│ • Persona -> RBAC    │   │ • Aspect: telco-governance│   │ • Scoped: telco_network    │
│ • Dataset ACL check  │   │ • Aspect: telco-semantics │   │ • 5G/LTE RAN Tower Health  │
│ • GDPR PII Masking   │   │ • Datasets:               │   │ • NOC Incident Dispatch    │
└──────────────────────┘   │   * telco_crm             │   └────────────────────────────┘
                           │   * telco_billing         │
                           │   * telco_network         │
                           └───────────────────────────┘
```

### Core Architectural Decisions & Trade-Offs

1. **Unified Text Chat & Live Voice in a Single Session (*MultimodalGemini* on *eu*)**:
   Maintaining separate orchestration stacks for text chat and voice IVR duplicates prompt logic and fragments conversation state. In this architecture, a single root orchestrator (*pulse_concierge*) configures *MultimodalGemini* (*gemini-3.8-flash* for text and *gemini-3.8-live* for voice) against the **eu** multi-region endpoint. A user can start an investigation via **Text Chat**, switch mid-conversation to **Live Bidirectional Voice** (streaming 16kHz PCM audio in and 24kHz PCM audio out with live transcripts), and return to **Text Chat** inside the **exact same *session_id*** with shared history and tool state.
2. **Cryptographic User Delegation vs. Over-Privileged Agent Identity (*persona-alex-exec* vs. *persona-elena-care*)**:
   Telling an LLM in its system prompt not to query billing tables for a customer-care agent is wishful thinking, not security. Lab 00 provisions two real IAM personas with distinct BigQuery dataset ACLs:
   * **persona-alex-exec** (Executive / Admin): holds *roles/bigquery.dataViewer* on all three datasets (*telco_crm*, *telco_billing*, *telco_network*).
   * **persona-elena-care** (Customer Care Specialist): holds *roles/bigquery.dataViewer* on *telco_crm* **only** (zero IAM permissions on *telco_billing* or *telco_network*).
   Lab 01 extracts the caller identity from the authenticated session (*tool_context.user_id*), contrasts **Phase 1 (Agent Identity)** against **Phase 2 (Delegated User OAuth 2.0 token)**, maps the workshop impersonation pattern to production **Microsoft Entra ID / M365 On-Behalf-Of (OBO)** flows, and inspects **Cloud Audit Logs** (*cloudaudit.googleapis.com/data_access*) to prove that BigQuery itself enforces HTTP 403 Access Denied when Elena queries billing or network tables.
3. **High-Velocity Hybrid Development Loop (Only Two Cloud Deploys of *pulse-concierge*)**:
   Waiting 5 to 8 minutes for a container build on every lab destroys developer flow. Instead, the workshop separates stateful cloud backing services from rapid local iteration:
   * **Lab 02 (Deploy #1, v1)**: Deploys *pulse-concierge* v1 once to **Agent Runtime** (*europe-west4*), provisioning the managed runtime instance (*PULSE_AGENT_ENGINE_ID*) and its SPIFFE **Agent Identity** (*PULSE_AGENT_PRINCIPAL*).
   * **Labs 03 to 06 (v2 to v5, Zero Intermediate Cloud Redeploys)**: New capabilities (MCP servers, ADK Skills, Memory Bank, Code Execution Sandbox, Model Armor + *after_tool_callback*, and the remote A2A NOC agent) run locally in-process while attaching directly to the **cloud-managed Sessions, Memory Bank, and Code Execution Sandbox** of the Lab 02 runtime instance (*app_name="app"*).
   * **Lab 06 (Deploy #2, final v5)**: Ships the complete *pulse-concierge* v5 container to Agent Runtime once, then runs end-to-end cloud verification covering tool-call streaming, Cloud Trace and Cloud Logging OpenTelemetry inspection, cloud Model Armor red-teaming, and recalling a Memory Bank fact persisted during the local Lab 04 run.
   * **Lab 08 (Optional)**: Deploys the separate *pulse-workflow-agent* deterministic graph workflow once (*DEPLOY_WORKFLOW_AGENT = True*).
4. **Deterministic Graph Workflows: ADK 2.x *Workflow* vs. Low-Code n8n (Lab 08)**:
   Not every business process should be an open-ended LLM loop. When a P1 fiber cut hits a regional cell tower, the remediation sequence must follow a strict state machine. Lab 08 builds type-safe, code-first ADK 2.x *Workflow* graphs (*StartNode*, *JoinNode*, parallel fan-out, conditional routing dictionaries, and *RequestInput* human-in-the-loop approve/reject checkpoints) and compares them candidly against low-code workflow tools like n8n, including hybrid coexistence patterns over MCP and A2A.
5. **Standalone End-State Reference Production Agent (*reference-production-agent/*)**:
   Provides a self-contained directory with the complete production Chat + Voice *pulse-concierge-prod* package and Terraform configuration (*reference-production-agent/terraform/*) that provisions and verifies an independent Agent Runtime instance (including optional Agent Gateway network egress enforcement) without touching the workshop lab resources.

---

## Workshop Labs (*labs/*)

All BigQuery data seeding, IAM persona provisioning, and Knowledge Catalog taxonomy setup are consolidated into **Lab 00**. Every notebook uses **google-adk==2.11.0**, renders structured tool calls and token usage via the shared *show_event()* helper, includes hands-on **🧪 Try it yourself** exercises, and concludes with an empirically verified **💶 Cost & scaling** breakdown.

| Lab | Notebook | Architectural Focus & Key Capabilities | Est. Time |
| :--- | :--- | :--- | :--- |
| **Lab 00** | [labs/lab00_setup.ipynb](labs/lab00_setup.ipynb) | **Environment, IAM Personas, BigQuery & Knowledge Catalog Setup**: Verifies CLI and ADC identity alignment in your project, enables APIs, installs *google-agents-cli==1.10.0*, provisions *persona-alex-exec* (all 3 datasets) and *persona-elena-care* (CRM only), seeds 3 EU BigQuery datasets (*telco_crm*, *telco_billing*, *telco_network*), and attaches Knowledge Catalog aspects. | 10 min |
| **Lab 01** | [labs/lab01_local_agent.ipynb](labs/lab01_local_agent.ipynb) | **Scaffold, Multi-Agent ADK, Session-Bound OAuth Delegation & Combined Chat + Live Voice**: Scaffolds *pulse-concierge*, enforces session-bound identity (*tool_context.user_id*), compares **Phase 1 (Agent Identity)** vs. **Phase 2 (Delegated User OAuth 2.0)** with **Cloud Audit Log** proof and an **Entra ID / M365 production architecture mapping**, and runs **Text Chat -> Live Voice -> Text Chat** in one *session_id*. | 20 min |
| **Lab 02** | [labs/lab02_deploy_and_register.ipynb](labs/lab02_deploy_and_register.ipynb) | **First Managed Deployment (v1), A2A Endpoint & Agent Registry**: Deploys *pulse-concierge* v1 to **Agent Runtime** (*europe-west4*) with its own SPIFFE **Agent Identity** (*principal://...*), multi-turn cloud Sessions, A2A v0.3 Agent Card + JSON-RPC *message/send*, and automatic **Agent Registry** discovery. | 15 min |
| **Lab 03** | [labs/lab03_mcp_and_skills.ipynb](labs/lab03_mcp_and_skills.ipynb) | **Knowledge Catalog MCP, BigQuery MCP, IAM Context MCP & ADK Skills (v2, local-against-cloud)**: Connects to Google's managed BigQuery and Knowledge Catalog MCP servers, deploys *pulse-iam-context-mcp* to Cloud Run (*europe-west4*), registers MCP servers and Skills in Agent Registry, wires *GCPSkillRegistry* + *SkillToolset*, grants IAM to the Agent Identity, and tests v2 locally against the Lab 02 runtime services. | 20 min |
| **Lab 04** | [labs/lab04_agent_runtime.ipynb](labs/lab04_agent_runtime.ipynb) | **Sessions, Memory Bank, Code Execution Sandbox & Feedback (v3, local-against-cloud)**: Exercises per-user cloud **Sessions** and **Memory Bank** isolation (*persona-alex-exec* vs. *persona-elena-care*), cloud **Code Execution Sandbox** (*run_python* with explicit TTL and cleanup), Feedback API, and OpenTelemetry configuration for *pulse-concierge* v3. | 20 min |
| **Lab 05** | [labs/lab05_model_armor.ipynb](labs/lab05_model_armor.ipynb) | **Runtime Guardrails with Model Armor (v4, local-against-cloud)**: Creates Model Armor templates (*pulse-guard-input*, *pulse-guard-output*) in *eu*, creates the *pulse_blocked_prompts* log-based metric, wires *ModelArmorPlugin* and *after_tool_callback* (tool-output screening) into v4, and red-teams direct jailbreaks, payment card PII, and indirect prompt injection. | 20 min |
| **Lab 06** | [labs/lab06_remote_a2a.ipynb](labs/lab06_remote_a2a.ipynb) | **Cross-Runtime Remote A2A Delegation & Final v5 Cloud Deploy**: Deploys *pulse-network-ops-agent* to Cloud Run (*europe-west4*), registers it in Agent Registry, wires *RemoteA2aAgent* into *pulse-concierge* v5, performs the **single final cloud deploy**, and runs 4 production cloud verification checks (tool calls, OTel traces/logs, cloud Model Armor blocking, and cross-environment Memory Bank recall). | 25 min |
| **Lab 07** | [labs/lab07_evaluation.ipynb](labs/lab07_evaluation.ipynb) | **Systematic Evaluation (*agents-cli eval* & Managed Cloud Eval)**: Authors *pulse-dataset.json* (6 golden Telco cases) + custom LLM-judge rubric (*pulse_governance_compliance*), runs local evaluation and side-by-side comparison, runs managed cloud evaluation in *europe-west4* against the deployed v5 engine, and configures online evaluation monitors. | 20 min |
| **Lab 08** | [labs/lab08_graph_workflows_n8n.ipynb](labs/lab08_graph_workflows_n8n.ipynb) | **Enterprise Graph Workflows: ADK 2.x *Workflow* vs. n8n**: Builds *pulse-workflow-agent* using *google.adk.workflow.Workflow* (parallel fan-out, *JoinNode*, risk-based routing, and *RequestInput* HITL approve/reject checkpoint), exercises local Pub/Sub trigger routes, compares ADK vs. n8n trade-offs, and optionally deploys to Agent Runtime. | 20 min |
| **Lab 09** | [labs/lab09_agent_gateway.ipynb](labs/lab09_agent_gateway.ipynb) | **(Self-Study, Architecture Reference) Network-Enforced Tool Governance with Agent Gateway**: Covers outbound *AGENT_TO_ANYWHERE* egress proxy architecture, SPIFFE workload identity, per-tool IAM v3 Unified Access Policy (UAP) CEL rules (*read_only_hint == true*) across *DRY_RUN* and *ENFORCED* stages, wire-level Model Armor (*CONTENT_AUTHZ*), and Terraform deployment. | 10 min |
| **Lab 10** | [labs/lab10_gemini_enterprise.ipynb](labs/lab10_gemini_enterprise.ipynb) | **(Self-Study, Architecture Reference) Publishing to Gemini Enterprise**: Explains *agents-cli publish gemini* (registration modes *adk* vs. *a2a*), Agent Registry vs. Gemini Enterprise agent catalogs, **authorization resources** (*serverSideOauth2*) for per-user Microsoft Entra ID / M365 and Google API access, and architectural boundaries (voice support, Teams/email relays, per-seat licensing). | 10 min |
| **Lab 11** | [labs/lab11_cleanup.ipynb](labs/lab11_cleanup.ipynb) | **Resource-Only Cleanup & Architecture Recap**: Safe dry-run-by-default (*CONFIRM_RESOURCE_CLEANUP = False*) teardown that removes all workshop resources in reverse dependency order without deleting the GCP project, plus a read-only project audit and full workshop cost and architecture recap. | 5 min |

---

## EU Data Residency & Location Policy

Every data storage, governance, inference, and runtime component is pinned to European Union locations (*eu* and *EU* multi-regions first, and *europe-west4* for regional services):

| Architectural Layer / Service | Location (*workshop.env* variable) | Residency & Routing Mechanics |
| :--- | :--- | :--- |
| **Gemini 3.8 Flash (Text Chat)** | **eu** (*MODEL_LOCATION=eu*) | EU multi-region endpoint (*aiplatform.eu.rep.googleapis.com*) |
| **Gemini 3.8 Live (Bidirectional Voice)** | **eu** (*LIVE_LOCATION=eu*) | EU multi-region *BidiGenerateContent* endpoint (zero US routing) |
| **BigQuery Datasets** (CRM, Billing, Network) | **EU** (*BQ_LOCATION=EU*) | EU multi-region analytical warehouse with dataset-level IAM ACLs |
| **Knowledge Catalog** (*dataplex.googleapis.com*) | **eu** | Aspect types (*telco-governance*, *telco-semantics*) and BigQuery entries stored in EU |
| **Skill Registry** (*agentregistry.googleapis.com*) | **eu** (*PULSE_SKILLS_LOCATION=eu*) | Public and private ADK skills (*private-pulse-telco-analytics*) stored in EU |
| **Model Armor Templates** (input and output guards) | **eu** (*MA_LOCATION=eu*) | Regional endpoint *modelarmor.eu.rep.googleapis.com* (*europe-west4* when bound to Agent Gateway) |
| **Agent Runtime, Sessions, Memory Bank & Code Sandbox** | **europe-west4** (*REGION=europe-west4*) | Regional Reasoning Engine, per-user Sessions, Memory Bank, and Code Execution Sandbox |
| **Cloud Run** (*pulse-iam-context-mcp*, *pulse-network-ops-agent*) | **europe-west4** (*REGION=europe-west4*) | Regional serverless containers for the custom IAM MCP server and remote NOC A2A agent |
| **Agent Registry, Evaluation & Agent Gateway** | **europe-west4** (*REGION=europe-west4*) | Regional MCP/A2A discovery, Gen AI Evaluation service, and Agent Gateway |

---

## Workshop Cost Summary (Per Participant)

Verified 2026-10-20 against the Google Cloud SKU catalog and official pricing pages (each lab includes a detailed **💶 Cost & scaling** table before its closing summary):

* **Expected cost per participant (one full run of Labs 00 to 11):** **~\$2.65** with the 50% Gemini 3.8 Flash introductory credit through December 31, 2026 (**~\$4.50 at list price**). Roughly **90%** of workshop spend comes from Gemini model tokens (*gemini-3.8-flash* on *eu* at \$1.65 / \$8.25 list per 1M input/output tokens; *gemini-3.8-live* audio at \$3.00 / \$12.00 per 1M tokens).
* **Budgeting rule of thumb:** Plan **~\$10 per participant** (roughly **\$300** for a 30-participant room) to cover extra playground exploration and retries.
* **Key cost guardrails:** Always set a short *ttl* on Code Execution sandboxes and delete them in Lab 04 and Lab 11 (an uncleaned default-size sandbox left running for its 14-day maximum TTL costs roughly **\$61**), and delete online evaluation monitors in Lab 11.

---

## Getting Started

### Prerequisites

* **A Google Cloud project with billing enabled**, where your account holds Owner (or Editor plus IAM admin roles). At an instructor-led event, you receive a dedicated account *devstarNNNN@gcplab.me* paired with a pre-provisioned project *pulse-telco-ws-NNNN* (printed on your credentials sheet alongside the password and two one-time 2FA codes). **No personal billing account or project-creation rights are required.**
* **A browser** with an Incognito or Guest window (so the workshop account does not collide with your corporate Google or Microsoft session). At the workshop we run everything inside **Cloud Shell** (Track 1A), requiring zero local installations on your laptop.
* *(Only for running on your own laptop, Track 1B)* *git*, [uv](https://docs.astral.sh/uv/getting-started/installation/), and the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) including the *alpha* component.
* *(Optional)* **Terraform >= 1.5**, used only for *terraform/* or *reference-production-agent/terraform/*.

### Track 1A (Recommended at the Workshop): Run Directly in Cloud Shell Editor (VS Code)

Cloud Shell provides a free browser-based Linux VM (4 vCPU / 16 GB RAM, 5 GB persistent home directory) with a built-in VS Code editor (**Cloud Shell Editor**), the Google Cloud CLI (including the alpha component), Git, Python 3.12, and uv preinstalled. You run the notebooks directly inside the Cloud Shell Editor using the repository's *.venv* Jupyter kernel without launching a separate JupyterLab server.

**1. Open Cloud Shell as the workshop account.** In an Incognito or Guest browser window, open <https://shell.cloud.google.com/?authuser=devstarNNNN@gcplab.me> and sign in using your credentials sheet (password + 2FA code). Click **Open Editor** in the Cloud Shell toolbar (if it is not already open) and open a terminal inside the editor (**Terminal -> New Terminal**).

**2. Find your GCP project, set it active, and authenticate Application Default Credentials (ADC):**

```bash
gcloud projects list                                       # find your assigned project ID (e.g. pulse-telco-ws-NNNN)
gcloud config set project YOUR_GCP_PROJECT_ID              # replace with your project ID
gcloud auth list                                           # verify devstarNNNN@gcplab.me is marked ACTIVE
gcloud auth application-default login && gcloud auth application-default set-quota-project YOUR_GCP_PROJECT_ID --quiet
```

**3. Clone the repository, synchronize the Python virtual environment, and register the Jupyter kernel** (~20 seconds):

```bash
git clone https://github.com/alukin40/geap-workshop-telco
cd geap-workshop-telco
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv sync
uv run python -m ipykernel install --user --name geap-telco-workshop --display-name "Python (geap-telco-workshop)"
```

**4. Select the workshop kernel and run Lab 00.** Open [labs/lab00_setup.ipynb](labs/lab00_setup.ipynb) in the Cloud Shell Editor, click **Select Kernel** in the top-right corner, and choose **Jupyter Kernel -> *Python (geap-telco-workshop)*** (or **Python Environments -> *.venv (Python 3.12)***). Leave *PROJECT_ID = ""* in Step 0.2 (or paste your project ID explicitly): *Lab 00* automatically verifies that all *pyproject.toml* packages are installed in the active kernel, syncs the ADC file and active project from your Cloud Shell terminal session into the kernel, and saves them to *workshop.env* for Labs 01 to 11. Click **Run All** (~2 minutes). Step 0.3 prints the project number and **the IAM roles your account holds**; if any later cell fails with *PERMISSION_DENIED*, share that role list with the instructor. Then proceed through Labs 01 to 11 in order.

**5. Lab 01 Web Playground (Step 1.8).** Once the notebook cell launches the server, click **Web Preview -> Preview on port 8080**; the playground UI is served at */dev-ui/*. Allow microphone permissions in your browser to test Live Voice.

**Reconnecting after a break:** Cloud Shell recycles its underlying VM after roughly 40 minutes of inactivity (such as over lunch). Every file in your home directory persists (repository, *.venv*, *~/.config/gcloud*, *workshop.env*, *pulse-concierge/*). After a break, reopen Cloud Shell Editor and re-run your current notebook from its top cell. To check available disk space in your 5 GB home directory (all labs together use roughly 2.5 GB), run:

```bash
df -h ~
uv cache clean   # optional: reclaims package cache space if needed
```

### Track 1B: Run on Your Own Laptop (macOS, Linux, or Windows WSL)

**1. Clone the repository:**

```bash
git clone https://github.com/alukin40/geap-workshop-telco
cd geap-workshop-telco
```

**2. (Recommended) Isolate workshop credentials from your corporate gcloud profile:**

Because *gcloud* stores a single Application Default Credentials (ADC) file per configuration directory, pointing *CLOUDSDK_CONFIG* to a dedicated folder keeps your existing corporate credentials untouched. Export this variable in **every** terminal window you use for the workshop, including the terminal that launches JupyterLab:

```bash
export CLOUDSDK_CONFIG="$HOME/.config/gcloud-geap-workshop"
```

**3. Authenticate both the CLI and Application Default Credentials, and set the quota project:**

```bash
gcloud config configurations create geap-telco-workshop   # isolated gcloud profile for the workshop
gcloud auth login                                          # sign in as devstarNNNN@gcplab.me
gcloud projects list                                       # find your assigned project ID (e.g. pulse-telco-ws-NNNN)
gcloud config set project pulse-telco-ws-NNNN              # replace with your project ID
gcloud auth application-default login && gcloud auth application-default set-quota-project pulse-telco-ws-NNNN --quiet
```

* *gcloud auth login* authenticates CLI commands, whereas *gcloud auth application-default login* authenticates Python SDKs and *agents-cli*. Both must use the exact same principal.
* On a remote SSH workstation without a local browser, append the *--no-launch-browser* flag to both login commands and open the printed URL inside your Incognito window.

**4. Verify identity alignment:**

```bash
gcloud auth list                     # devstarNNNN@gcplab.me is marked ACTIVE
gcloud config get-value project      # pulse-telco-ws-NNNN
gcloud projects describe "$(gcloud config get-value project)" --format="value(projectNumber)"
```

**5. Install dependencies and launch JupyterLab** (from the same shell so *CLOUDSDK_CONFIG* is inherited):

```bash
uv sync
uv run jupyter lab                   # or open the directory in VS Code and select the .venv kernel
```

**6. Run Lab 00:**

Open **[labs/lab00_setup.ipynb](labs/lab00_setup.ipynb)**. Leave *PROJECT_ID = ""* to inherit the project from Step 3 (or set it explicitly), then click **Run All**. Step 0.3 prints the project number and **the IAM roles your account holds**. If any cell fails with *PERMISSION_DENIED*, send that output to the instructor. Then continue through *lab01* to *lab11* in sequence.

You can also execute any notebook headlessly from the terminal:

```bash
uv run jupyter nbconvert --to notebook --execute --inplace --ExecutePreprocessor.timeout=900 labs/lab00_setup.ipynb
```

---

### Track 1C (Fallback Only if Cloud Shell Is Disabled): Vertex AI Workbench

1. Provision a Workbench instance (~2 minutes) in the workshop region using 4th-generation N4 compute and Hyperdisk Balanced storage:

```bash
gcloud services enable notebooks.googleapis.com
gcloud workbench instances create geap-wb --location=europe-west4-a \
  --machine-type=n4-standard-4 --boot-disk-type=HYPERDISK_BALANCED --data-disk-type=HYPERDISK_BALANCED \
  --instance-owners=devstarNNNN@gcplab.me --enable-managed-euc
```

   If creation fails with *constraints/compute.requireOsLogin*, omit the managed EUC flag and pass *enable-oslogin=TRUE* in metadata; if it fails with *requireShieldedVm*, pass the shielded secure boot flag.
2. Click **Open JupyterLab**, open **File -> New -> Terminal**, and check your active account:

```bash
gcloud auth list
```

   It must show *devstarNNNN@gcplab.me*. If it shows the default compute service account (*...-compute@developer.gserviceaccount.com*), authenticate both the CLI and ADC with your workshop user:

```bash
gcloud auth login --no-launch-browser
gcloud config set project pulse-telco-ws-NNNN
gcloud auth application-default login --no-launch-browser && gcloud auth application-default set-quota-project pulse-telco-ws-NNNN --quiet
```

3. Install [uv](https://docs.astral.sh/uv/getting-started/installation/), clone the repository, and register its virtual environment as a Jupyter kernel with *~/.local/bin* on its *PATH*:

```bash
git clone https://github.com/alukin40/geap-workshop-telco ~/geap-workshop-telco && cd ~/geap-workshop-telco && uv sync
uv run python -m ipykernel install --user --name geap --display-name "GEAP workshop (.venv)" \
  --env PATH "$HOME/.local/bin:$HOME/geap-workshop-telco/.venv/bin:/usr/local/bin:/usr/bin:/bin"
```

   Open each notebook using the **GEAP workshop (.venv)** kernel.
4. Note that the Lab 01 local web playground (Step 1.8) cannot bind port 8080 on Workbench because JupyterLab itself occupies port 8080; skip Step 1.8 and run Step 1.9, which exercises the exact same agent in-process.
5. Stop or delete the Workbench instance at the end of the workshop (idle shutdown stops it automatically after 180 minutes).

### Instructor Runbook: Preparing Pre-Provisioned Workshop Projects

Google Frictionless workshop accounts (*devstarNNNN@gcplab.me*) ship with an Editor-based role set by default. Because these labs provision service accounts, bind IAM policies to SPIFFE Agent Identities, mint impersonated OAuth tokens, and inspect Data Access audit logs, participants additionally need **Project IAM Admin**, **Service Account Admin**, **Service Account Token Creator**, and **Private Logs Viewer**.

As the event administrator (holding Project IAM Admin across all event projects), run the bootstrap script from Cloud Shell before the session starts to grant those four roles and pre-enable all required APIs:

```bash
git clone https://github.com/alukin40/geap-workshop-telco && cd geap-workshop-telco
./instructor/grant_participant_access.sh 4370          # test on a single project first
./instructor/grant_participant_access.sh 4351 4370     # apply across the full participant range
```

Override *PROJECT_PREFIX* (defaults to *pulse-telco-ws-*), *USER_PREFIX*, or *USER_DOMAIN* via environment variables when your event uses a custom naming convention. Because **Agent Gateway** requires Organization Policy overrides, it is covered as a self-study architecture lab in Lab 09; if you also want to walk through a live gateway environment, follow [reference-production-agent/AGENT_GATEWAY_DEMO.md](reference-production-agent/AGENT_GATEWAY_DEMO.md) from a dedicated project.

**Day-Before Pre-Flight Verification (~10 minutes with one real participant account):**

1. In an Incognito window, sign in as one *devstarNNNN@gcplab.me* account and open <https://shell.cloud.google.com/?authuser=devstarNNNN@gcplab.me>. Confirm that the Cloud Shell terminal opens cleanly and verify the preinstalled toolchain:

```bash
gcloud auth list
uv --version
gcloud alpha --help >/dev/null && echo ok
```

2. Follow Track 1A through starting JupyterLab, open Web Preview on port 8081, and execute the first cells of Lab 00 to confirm that Web Preview proxying and kernel WebSockets work end to end.
3. Whenever possible, test from a laptop on the venue Wi-Fi network, or verify with venue IT that outbound traffic and WebSockets to *\*.cloud.google.com*, *ssh.cloud.google.com*, and *\*.cloudshell.dev* are not stripped by a corporate TLS inspection proxy. If corporate Wi-Fi blocks Google WebSockets, switch the room to guest Wi-Fi.

---

### Track 2: Standalone End-State Reference Production Agent (*reference-production-agent/*)

For engineering teams who want a **self-contained, declarative end-state deployment** of the Combined Chat + Live Voice *pulse-concierge-prod* agent (completely isolated from the step-by-step *labs/* notebooks so running the labs never modifies or overwrites it):

* **[reference-production-agent/pulse-concierge-prod/](reference-production-agent/pulse-concierge-prod/)**: Full end-state ADK application (*MultimodalGemini* Chat + Live Voice on *eu*, Delegated User OAuth 2.0 + BigQuery / Knowledge Catalog / IAM Context MCPs, Skills, Sessions, Memory Bank, Code Execution Sandbox, Model Armor plugin + tool callback, and Remote A2A NOC Desk).
* **[reference-production-agent/terraform/](reference-production-agent/terraform/)**: Self-contained Terraform configuration and automated verification script that provisions the production stack and deploys *pulse-concierge-prod* to Agent Runtime (*europe-west4*, plus optional Agent Gateway egress enforcement).

See **[reference-production-agent/README.md](reference-production-agent/README.md)** and **[reference-production-agent/AGENT_GATEWAY_DEMO.md](reference-production-agent/AGENT_GATEWAY_DEMO.md)** for architecture details, deployment commands, and the gateway validation runbook.

---

### Track 3: Workshop Foundation Terraform (*terraform/*)

For platform teams who prefer to pre-provision the underlying Pulse Telco data foundation, Knowledge Catalog taxonomy, least-privilege IAM, and Cloud Run microservices via Infrastructure-as-Code:

* **[terraform/00-project-bootstrap/](terraform/00-project-bootstrap/)** *(Optional, Instructor or Sandbox Use)*: Creates a fresh GCP project and attaches a billing account.
* **[terraform/01-telco-geap-platform/](terraform/01-telco-geap-platform/)** *(Customer-Facing)*: Parameterized via *var.project_id*. Provisions APIs, Service Accounts, BigQuery datasets and tables, Knowledge Catalog Aspect Types, staging bucket, and Cloud Run microservices.

---

## Repository Structure

```text
.
├── README.md                          # Workshop architecture, lab guide, cost summary, and quickstart
├── AGENTS.md                          # AI coding assistant instructions & repo conventions
├── pyproject.toml                     # Python dependencies managed by uv (google-adk==2.11.0)
├── workshop.env.example               # Template for workshop.env generated by Lab 00
├── data/                              # Pre-generated deterministic Pulse Telco datasets
│   ├── crm_subscribers.{csv,json}     # 60 subscribers across PRG, BRN, OVA, BTS, VIE
│   ├── crm_subscriptions.{csv,json}   # 75 active 5G mobile & 10G fiber subscriptions
│   ├── billing_invoices.{csv,json}    # 120 monthly invoices (Jul to Aug 2026)
│   ├── billing_transactions.{csv,json}# 120 payment gateway transactions (+ poisoned note on SUB-1013)
│   ├── network_cell_towers.{csv,json} # 12 5G/LTE cell sites (including degraded TWR-PRG-02 & TWR-BRN-02)
│   ├── network_incidents.{csv,json}   # 8 NOC outage incidents (including INC-7001 P1 fiber cut)
│   └── knowledge_catalog_specs.json   # Knowledge Catalog Aspect Types & business glossary specs
├── labs/                              # Sequential Jupyter notebooks (Lab 00 to Lab 11)
│   ├── lab00_setup.ipynb              # Automated Setup, IAM Personas, BigQuery (EU) & Knowledge Catalog (eu)
│   ├── lab01_local_agent.ipynb        # ADK Scaffold, Session-Bound OAuth Delegation & Chat + Live Voice (eu)
│   ├── lab02_deploy_and_register.ipynb# First Agent Runtime Deploy (v1, europe-west4), A2A & Agent Registry
│   ├── lab03_mcp_and_skills.ipynb     # Managed MCPs, Cloud Run IAM MCP & ADK Skills (v2, local-against-cloud)
│   ├── lab04_agent_runtime.ipynb      # Per-User Sessions, Memory Bank, Sandbox & Feedback (v3, local-against-cloud)
│   ├── lab05_model_armor.ipynb        # Model Armor Guardrails in eu (Plugin + after_tool_callback, v4)
│   ├── lab06_remote_a2a.ipynb         # Remote A2A NOC Agent & Single Final v5 Cloud Deployment + 4 Cloud Checks
│   ├── lab07_evaluation.ipynb         # Local & Managed Cloud Evaluation + Rubric Grading
│   ├── lab08_graph_workflows_n8n.ipynb# ADK 2.x Graph Workflows vs. n8n
│   ├── lab09_agent_gateway.ipynb      # (Self-Study) Network-Enforced Tool Governance with Agent Gateway
│   ├── lab10_gemini_enterprise.ipynb  # (Self-Study) Publishing to Gemini Enterprise & Entra ID OAuth
│   └── lab11_cleanup.ipynb            # Resource-Only Cleanup & Workshop Cost/Architecture Recap
├── instructor/                        # Instructor-only helpers (e.g. grant_participant_access.sh)
├── mocks/                             # Deployable Cloud Run microservices
│   ├── telco-iam-context-mcp/         # FastMCP server for user token/persona RBAC & GDPR masking
│   └── telco-network-ops-agent/       # Remote A2A v0.3 Network Operations specialist agent
├── reference-production-agent/        # Standalone End-State Production Agent + Terraform (untouched by labs)
│   ├── README.md                      # Production reference guide & verification commands
│   ├── AGENT_GATEWAY_DEMO.md          # Validation walkthrough for Agent Gateway
│   ├── pulse-concierge-prod/          # Self-contained Chat + Voice production ADK application
│   └── terraform/                     # Terraform IaC to deploy & wire pulse-concierge-prod end-to-end
└── terraform/                         # Two-stage Workshop Foundation Terraform IaC
    ├── 00-project-bootstrap/          # Optional GCP project creation & billing link
    └── 01-telco-geap-platform/        # Customer-facing parameterized GEAP & BigQuery/KC deployment
```
