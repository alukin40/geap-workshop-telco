# Pulse Telco IAM & User Context MCP Server (`telco-iam-context-mcp`)

Remote MCP server (Streamable HTTP at `/mcp`) deployed to Cloud Run in **Lab03** and governed via Agent Gateway in **Lab09**.

Exposes four tools:
- `resolve_user_context(user_token)` (`readOnlyHint=True`) — resolves an employee token into department, region focus, preferred currency, and allowed BigQuery datasets (`telco_crm`, `telco_billing`, `telco_network`).
- `check_bq_dataset_access(user_token, dataset_id)` (`readOnlyHint=True`) — checks whether `user_token` is permitted to query `dataset_id`.
- `grant_dataset_access(user_token, dataset_id, justification)` (`readOnlyHint=False`, `destructiveHint=True`) — privileged mutating tool that should be **denied** by Agent Gateway policy for conversational analytics agents.
- `whoami()` (`readOnlyHint=True`) — echoes HTTP headers (`x-pulse-end-user`, `x-pulse-session`, `user-agent`) to demonstrate identity propagation.
