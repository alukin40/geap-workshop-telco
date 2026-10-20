# pulse-concierge-prod

ADK application package of the standalone reference production agent (Text Chat + Live Voice, delegated BigQuery access, MCP, A2A, Memory Bank, Model Armor).

It is built and deployed by Terraform from [`../terraform`](../terraform), which also writes the `.env` this package reads. Overview, deployment and verification: [`../README.md`](../README.md). Optional Agent Gateway demo: [`../AGENT_GATEWAY_DEMO.md`](../AGENT_GATEWAY_DEMO.md).

```text
app/agent.py         root orchestrator, CRM / billing sub-agents, MCP toolsets, NOC A2A agent, Model Armor plugin
app/tools.py         BigQuery tools that run as the session user, Knowledge Catalog lookup, code-execution sandbox
app/fast_api_app.py  FastAPI / A2A entrypoint used by Agent Runtime
app/skills/          bigquery-basics and pulse-telco-analytics skills
Dockerfile           container image; trusts the Agent Gateway root CA when it is passed as a build arg
```

Manual deploy without Terraform: `agents-cli deploy --project <PROJECT_ID> --region <REGION> --agent-identity` (needs a `.env` like the one `../terraform/scripts/deploy_and_verify.py` writes).
