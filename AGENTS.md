# AGENTS.md: Pulse Telco GEAP Workshop Repository Guidelines

## Overview

This repository contains the **Pulse Telco Conversational Analytics & Multi-Agent Workshop** for **Google Cloud's Gemini platform** (formerly Gemini Enterprise Agent Platform / GEAP), along with a standalone end-state production reference (*reference-production-agent/*) and a two-stage **Terraform** foundation (*terraform/*).

**Naming Convention (October 2026):** External product positioning uses **Gemini platform** for the agent platform (documentation paths remain under */gemini-enterprise-agent-platform/* and APIs use *aiplatform.googleapis.com*), **Gemini Enterprise** for the employee web application and commercial seat editions (Business, Standard, Plus, Frontline, and Pay-as-you-go), and **Knowledge Catalog** for Dataplex Universal Catalog (*dataplex.googleapis.com*).

## Architectural & Code Conventions

1. **Fictional Brand Only (*Pulse Telco* / *pulse-concierge*)**:
   * All examples, synthetic datasets, schemas, and prompts use the fictional Central European telecommunications operator **Pulse Telco** (*pulse-telco.eu*) operating across regional markets (PRG, BRN, OVA, BTS, VIE).
   * Never introduce real customer names, sister AI unit names, real subscriber PII, internal bug IDs, or Google-internal identifiers anywhere in *labs/*, *README.md*, *AGENTS.md*, *instructor/*, *mocks/*, *data/*, or *reference-production-agent/*.
   * Always use *<YOUR_PROJECT_ID>*, *pulse-telco-ws-NNNN*, or *pulse-telco-gw-demo* for project ID placeholders in markdown, comments, and scripts.

2. **Strict EU Data Residency & Location Policy (*eu* / *EU* + *europe-west4*)**:
   * **EU Multi-Region (*eu* / *EU*)**:
     * Gemini text model (*MODEL_LOCATION="eu"*, *MODEL="gemini-3.8-flash"*) and Live voice model (*LIVE_LOCATION="eu"*, *LIVE_MODEL="gemini-3.8-live"*).
     * Skill Registry (*PULSE_SKILLS_LOCATION="eu"*), Model Armor templates (*MA_LOCATION="eu"*, regional endpoint *https://modelarmor.eu.rep.googleapis.com*), and Knowledge Catalog aspect types in *eu*.
     * BigQuery datasets (*telco_crm*, *telco_billing*, *telco_network*) in the **EU** multi-region (*BQ_LOCATION="EU"*).
   * **Workshop Regional Services (*REGION="europe-west4"*)**:
     * Agent Runtime (*reasoningEngines*), managed Sessions, Memory Bank, Code Execution Sandbox, Feedback service, Agent Registry (MCP servers and A2A services), Cloud Run (*pulse-iam-context-mcp* and *pulse-network-ops-agent*), Gen AI Evaluation / Online Monitors, and Agent Gateway (Lab 09 architecture reference and Terraform module).
   * Never hard-code region names in code cells: read the location variables (*REGION*, *MODEL_LOCATION*, *LIVE_LOCATION*, *PULSE_SKILLS_LOCATION*, *MA_LOCATION*) from *workshop.env*.
   * Never use deprecated Gemini 1.5 or 2.0 models; always use *gemini-3.8-flash* and *gemini-3.8-live*.

3. **SDK & CLI Version Pins (*google-adk==2.11.0*, *google-agents-cli==1.10.0*)**:
   * Pin **google-adk==2.11.0** in the root *pyproject.toml* and in every agent's dependency installation command. Do not upgrade to 2.12.0, whose *gcp* extra pulls *google-cloud-agentplatform* 2.x and breaks the *agents-cli* 1.10.0 *reasoning_engine_adapter.py* scaffold.
   * Keep *google-cloud-aiplatform>=1.156.0,<2.0.0* (1.165.x line). For evaluation (Lab 07), install *google-adk[eval]==2.11.0* and *google-cloud-aiplatform[evaluation]>=1.156.0,<2.0.0*.
   * Install **google-agents-cli==1.10.0** in Lab 00.
   * Use *GCPSkillRegistry(...)* directly without any custom *_create_httpx_client* subclass override (ADK 2.11.0 handles GCS redirect headers natively).
   * Because *ModelArmorPlugin* in ADK 2.11.0 screens user prompts (*before_model*) and model outputs (*after_model*) but not tool outputs, Lab 05 adds a concise custom *after_tool_callback* to screen untrusted tool results against *pulse-guard-input*.

4. **Deployment Cadence (Local-Against-Cloud Dev Loop)**:
   * **Lab 02 (Deploy #1, v1)**: Deploys *pulse-concierge* v1 once to Agent Runtime (*europe-west4*), writing the runtime resource name, engine ID, endpoint URL, and SPIFFE principal (*PULSE_AGENT_PRINCIPAL*) to *workshop.env*.
   * **Labs 03, 04, 05 & Lab 06 (No Intermediate Redeploys)**: Build and test v2 through v5 locally in-process using ADK *Runner* attached to the cloud-managed Session, Memory Bank, and Code Execution Sandbox services of the Lab 02 instance (*agent_engine_id=PULSE_AGENT_ENGINE_ID*, *app_name="app"*). Accumulate runtime environment variables in *pulse-concierge/.env* and grant IAM roles to *PULSE_AGENT_PRINCIPAL* in the lab that introduces them.
   * **Lab 06 (Single Final v5 Cloud Deploy)**: Deploys the final *pulse-concierge* v5 to Agent Runtime once (guarded by *FORCE_REDEPLOY*), followed by cloud verification (tool calls, Cloud Trace/Logging OTel inspection, cloud Model Armor red-team check, and cross-environment Memory Bank recall).
   * **Lab 08 (Optional)**: Deploys the separate *pulse-workflow-agent* graph workflow once (*DEPLOY_WORKFLOW_AGENT = True*).

5. **Lab Index (*labs/lab00_setup.ipynb* to *labs/lab11_cleanup.ipynb*)**:
   * **labs/lab00_setup.ipynb**: Existing-project verification (CLI and ADC account match), APIs, *agents-cli==1.10.0*, persona service accounts (*persona-alex-exec* on all 3 datasets; *persona-elena-care* on CRM only), BigQuery EU datasets and tables, Knowledge Catalog aspects (*telco-governance*, *telco-semantics*), and *workshop.env* generation.
   * **labs/lab01_local_agent.ipynb**: Agent project scaffold (*pulse-concierge*), multi-agent ADK (*crm_domain_agent*, *billing_domain_agent*), session-bound OAuth delegation (*tool_context.user_id*) with Cloud Audit Log proof, Entra ID / M365 production comparison table, and combined Text Chat + Live Voice in one *session_id*.
   * **labs/lab02_deploy_and_register.ipynb**: First cloud deploy (v1) to Agent Runtime (*europe-west4*), Agent Identity (*principal://...*), cloud Sessions, A2A v0.3 Agent Card + JSON-RPC, and automatic Agent Registry listing.
   * **labs/lab03_mcp_and_skills.ipynb**: Managed BigQuery MCP and Knowledge Catalog MCP, custom *pulse-iam-context-mcp* on Cloud Run (*europe-west4*), Agent Registry MCP registration, public and private ADK skills in Skill Registry (*eu*), and local-against-cloud v2 run.
   * **labs/lab04_agent_runtime.ipynb**: Per-user cloud Sessions and Memory Bank isolation, cloud Code Execution Sandbox (*run_python* with TTL and cleanup, no local *exec()* fallback), Feedback service, and OTel configuration (v3 local-against-cloud).
   * **labs/lab05_model_armor.ipynb**: Model Armor templates (*pulse-guard-input*, *pulse-guard-output*) in *eu*, *pulse_blocked_prompts* log-based metric, *ModelArmorPlugin* + *after_tool_callback* (v4 local-against-cloud), red-teaming, and Floor Settings overview.
   * **labs/lab06_remote_a2a.ipynb**: Deploys *pulse-network-ops-agent* (A2A) to Cloud Run (*europe-west4*), registers it in Agent Registry, wires *RemoteA2aAgent* into v5, performs the single final cloud deploy of *pulse-concierge*, and runs the 4 production cloud verification checks.
   * **labs/lab07_evaluation.ipynb**: Golden evaluation dataset (*pulse-dataset.json*), custom governance judge (*pulse_governance_compliance*), local CLI evaluation and comparison, managed cloud evaluation in *europe-west4*, and online evaluation monitors.
   * **labs/lab08_graph_workflows_n8n.ipynb**: ADK 2.x *Workflow* (parallel branches, *JoinNode*, risk-based routing, *RequestInput* HITL approve/reject), local Pub/Sub trigger route test (*trigger_sources=["pubsub"]*), candid n8n architectural comparison, and optional Agent Runtime deploy.
   * **labs/lab09_agent_gateway.ipynb** *(Self-Study, Architecture Reference)*: Outbound *AGENT_TO_ANYWHERE* Agent Gateway architecture, SPIFFE workload identity, per-tool IAM v3 UAP CEL rules (*read_only_hint == true*) across *DRY_RUN* and *ENFORCED*, wire-level Model Armor (*CONTENT_AUTHZ*), and Terraform deployment.
   * **labs/lab10_gemini_enterprise.ipynb** *(Self-Study, Architecture Reference)*: Publishing via *agents-cli publish gemini* (registration types *adk* vs. *a2a*), Agent Registry vs. Gemini Enterprise agent list, authorization resources (*serverSideOauth2*) for Entra ID / M365 and Google APIs, and architectural limits.
   * **labs/lab11_cleanup.ipynb**: Resource-only teardown in reverse dependency order (*CONFIRM_RESOURCE_CLEANUP = False* dry-run default; never deletes the project), read-only *audit()*, and full workshop cost and architecture recap.

6. **Shared *show_event()* Helper & Notebook Formatting Standards**:
   * Every lab that runs local *Runner* loops or remote *async_stream_query* loops must define and use *show_event(ev, stats=None, text_limit=2000)* and *show_stats(stats)* so tool calls, tool outputs, errors, final responses, and token usage are always visible across snake_case and camelCase event payloads.
   * Every notebook reads *../workshop.env* and sets *os.environ["GOOGLE_API_USE_CLIENT_CERTIFICATE"] = "false"* at startup so regional *.rep.googleapis.com* endpoints work across all environments.
   * Save notebooks in canonical *json.dumps(nb, indent=1, ensure_ascii=False) + "\n"* format with unique cell *id* values and cleared *outputs* and *execution_count* on edited code cells.
   * Every lab must open with a clear title, a **🎯 Objectives** section, verified official documentation links (HTTP 200 checked via *curl -sIL*), and a *mermaid* diagram; every code cell must be preceded by an explanatory markdown cell (and a fenced bash code block for CLI operations); every lab includes 1 to 3 **🧪 Try it yourself** exercises.

7. **Cost & Scaling Section Convention**:
   * Every lab must include one **💶 Cost & scaling** markdown section immediately before its closing summary/recap.
   * Escape all literal dollar signs as *\$* so JupyterLab does not render pairs of dollar signs as LaTeX math.
   * Cover every service the lab touches (including free/managed layers and what they bill underneath), state 2 to 3 concrete scaling/quota facts, give a per-lab estimate, and link official pricing pages.

8. **Terraform Two-Module Split (*terraform/*) & Production Reference (*reference-production-agent/*)**:
   * *terraform/00-project-bootstrap/*: Optional module for creating a new GCP project and linking billing.
   * *terraform/01-telco-geap-platform/*: Customer-facing module parameterized via *var.project_id* to deploy into an existing GCP project.
   * *reference-production-agent/*: Standalone end-state *pulse-concierge-prod* agent and Terraform deployment (including optional Agent Gateway) isolated from the workshop labs.

9. **Editorial & Formatting Standards (Gregor Hohpe Style, Zero Dashes, Zero Inline Backticks)**:
   * **Gregor Hohpe (*The Architect Elevator*) Explanatory Style**:
     * Ride the elevator between the control room (governance, blast radius, organizational autonomy, cost predictability) and the engine room (tokens on the wire, SPIFFE principals, IAM policy bindings, HTTP status codes).
     * Start every major section by stating the architectural tension or trade-off in plain, direct terms (for example, why system prompts are not an access-control boundary, why building a new container image for every prompt tweak destroys developer velocity, or why network-layer egress policy differs from in-process callbacks).
     * Connect that principle directly to the mechanism in the code cell below.
     * Avoid marketing adjectives ("seamless", "powerful", "cutting-edge", "first-class", "effortlessly", "unlock") and avoid robotic lists of parameter names when a two-sentence explanation of the mechanism suffices.
   * **Zero Em-Dashes, En-Dashes, or Spaced Hyphen Clause Separators ("No AI Slop")**:
     * Never use em-dashes, en-dashes, spaced double-hyphens, or spaced single-hyphens as clause separators in prose, headings, tables, or code comments.
     * Rewrite dashed clauses using colons, parentheses, or crisp separate sentences; write numeric ranges with "to" or a tight hyphen (for example, "5 to 8 minutes" or "Labs 00 to 11").
     * Preserve CLI flags inside commands (*--project*, *--region*), Markdown horizontal rules (*---*), Markdown table separators, and Mermaid arrow syntax inside fenced mermaid blocks.
   * **Zero Inline Backticks in Prose ("No Red Text Pop-Ups All Over Prose")**:
     * In prose paragraphs, headings, bullet points, and table cells (everywhere outside fenced code blocks), never wrap identifiers, filenames, flags, or product names in inline backticks.
     * Use *italics* (*root_agent*, *workshop.env*, *europe-west4*), double quotes ("PERMISSION_DENIED"), or plain text (Agent Runtime, BigQuery, Knowledge Catalog, Model Armor) instead.
     * Place standalone runnable terminal commands, CLI invocations, and multi-token code snippets inside fenced code blocks (*bash*, *python*, *hcl*, *text*) on their own lines.
