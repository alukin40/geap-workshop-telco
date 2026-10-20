#!/usr/bin/env bash
# Register in Agent Registry the IAM Context MCP server (with its tool spec, so the gateway can
# read readOnlyHint), the NOC A2A agent (agent card) and every Google API endpoint
# pulse-concierge-prod calls.
#
# The egress Agent Gateway is default-deny by hostname: a destination that is not in the
# registry cannot be matched by the access policy. Entries are matched by exact URL; a URL that is
# already registered (for example by the workshop labs) is left untouched, missing ones are created
# with a `pulse-prod-` prefix. Registry entries are a free catalogue, so `terraform destroy` does
# not delete them.
#
# Usage: ensure_registry.sh PROJECT_ID REGION MODEL_LOCATION MODEL_ARMOR_LOCATION IAM_MCP_URL NOC_AGENT_URL
set -euo pipefail

PROJECT_ID="$1"
REGION="$2"
MODEL_LOCATION="$3"
MA_LOCATION="$4"
IAM_MCP_URL="$5"
NOC_URL="$6"

existing="$(gcloud agent-registry services list --project="$PROJECT_ID" --location="$REGION" \
  --format='value(name.basename(),interfaces[0].url)')"

has_url() { awk -F'\t' -v u="$1" '$2 == u { f = 1 } END { exit !f }' <<<"$existing"; }
has_name() { awk -F'\t' -v n="$1" '$1 == n { f = 1 } END { exit !f }' <<<"$existing"; }

ensure_endpoint() {
  local name="$1" url="$2"
  if has_url "$url"; then
    return
  fi
  echo "registering ENDPOINT pulse-prod-$name -> $url"
  gcloud agent-registry services create "pulse-prod-$name" --project="$PROJECT_ID" --location="$REGION" \
    --display-name="pulse-prod-$name" --endpoint-spec-type=no-spec \
    --interfaces="url=$url,protocolBinding=http-json" --quiet >/dev/null
}

ensure_endpoint gapi-aiplatform-eu "https://aiplatform.${MODEL_LOCATION}.rep.googleapis.com"
ensure_endpoint gapi-aiplatform-region "https://${REGION}-aiplatform.googleapis.com"
ensure_endpoint gapi-aiplatform-region-mtls "https://${REGION}-aiplatform.mtls.googleapis.com"
ensure_endpoint gapi-aiplatform-region-rep "https://aiplatform.${REGION}.rep.googleapis.com"
ensure_endpoint gapi-aiplatform "https://aiplatform.googleapis.com"
ensure_endpoint gapi-aiplatform-mtls "https://aiplatform.mtls.googleapis.com"
ensure_endpoint gapi-logging "https://logging.googleapis.com"
ensure_endpoint gapi-logging-mtls "https://logging.mtls.googleapis.com"
ensure_endpoint gapi-telemetry "https://telemetry.googleapis.com"
ensure_endpoint gapi-telemetry-mtls "https://telemetry.mtls.googleapis.com"
ensure_endpoint gapi-cloudtrace "https://cloudtrace.googleapis.com"
ensure_endpoint gapi-cloudtrace-mtls "https://cloudtrace.mtls.googleapis.com"
ensure_endpoint gapi-monitoring "https://monitoring.googleapis.com"
ensure_endpoint gapi-monitoring-mtls "https://monitoring.mtls.googleapis.com"
ensure_endpoint gapi-resourcemanager "https://cloudresourcemanager.googleapis.com"
ensure_endpoint gapi-resourcemanager-mtls "https://cloudresourcemanager.mtls.googleapis.com"
ensure_endpoint gapi-resourcemanager-443 "https://cloudresourcemanager.googleapis.com:443"
ensure_endpoint gapi-resourcemanager-mtls-443 "https://cloudresourcemanager.mtls.googleapis.com:443"
ensure_endpoint gapi-iamcredentials "https://iamcredentials.googleapis.com"
ensure_endpoint gapi-iamcredentials-mtls "https://iamcredentials.mtls.googleapis.com"
ensure_endpoint gapi-secretmanager "https://secretmanager.googleapis.com"
ensure_endpoint gapi-agentregistry "https://agentregistry.googleapis.com"
ensure_endpoint gapi-oauth2 "https://oauth2.googleapis.com"
ensure_endpoint gapi-bigquery "https://bigquery.googleapis.com"
ensure_endpoint gapi-dataplex "https://dataplex.googleapis.com"
ensure_endpoint "gapi-modelarmor-${MA_LOCATION}" "https://modelarmor.${MA_LOCATION}.rep.googleapis.com"
ensure_endpoint "gapi-modelarmor-${MA_LOCATION}-443" "https://modelarmor.${MA_LOCATION}.rep.googleapis.com:443"

# IAM Context MCP server: tool spec straight from its tools/list (annotations incl. readOnlyHint).
if ! has_url "$IAM_MCP_URL"; then
  spec="$(mktemp --suffix=.json)"
  for i in $(seq 1 10); do
    curl -sf -X POST "$IAM_MCP_URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["result"]))' >"$spec" && break
    echo "waiting for $IAM_MCP_URL ($i/10)"; sleep 10
  done
  echo "registering MCP_SERVER pulse-iam-context-mcp -> $IAM_MCP_URL"
  gcloud agent-registry services create pulse-iam-context-mcp --project="$PROJECT_ID" --location="$REGION" \
    --display-name="Pulse Telco IAM Context (MCP)" --description="User token context and BigQuery dataset entitlement service" \
    --mcp-server-spec-type=tool-spec --mcp-server-spec-content="$spec" \
    --interfaces="url=$IAM_MCP_URL,protocolBinding=jsonrpc" --quiet >/dev/null
  rm -f "$spec"
fi

# NOC A2A agent (agent card; the registry derives the URL from the card).
if ! has_name pulse-network-ops-agent && ! has_name pulse-prod-network-ops-agent; then
  card="$(mktemp --suffix=.json)"
  curl -sf "${NOC_URL%/}/.well-known/agent-card.json" -o "$card"
  echo "registering AGENT pulse-network-ops-agent -> $NOC_URL"
  gcloud agent-registry services create pulse-network-ops-agent --project="$PROJECT_ID" --location="$REGION" \
    --display-name="Pulse Telco NOC Desk (A2A)" --agent-spec-type=a2a-agent-card \
    --agent-spec-content="$card" --quiet >/dev/null
  rm -f "$card"
fi

echo "Agent Registry ($REGION) contains every destination pulse-concierge-prod needs."
