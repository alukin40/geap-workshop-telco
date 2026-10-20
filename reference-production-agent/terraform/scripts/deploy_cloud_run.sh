#!/usr/bin/env bash
# Build and deploy one of the mock services (mocks/<dir>) to Cloud Run from source (idempotent: a
# redeploy just creates a new revision). Used for pulse-iam-context-mcp and pulse-network-ops-agent.
#
# Usage: deploy_cloud_run.sh SERVICE SOURCE_DIR PROJECT_ID REGION MEMORY [ENV_VARS (K=V,K=V)]
set -euo pipefail

SERVICE="$1"
SOURCE_DIR="$2"
PROJECT_ID="$3"
REGION="$4"
MEMORY="$5"
ENV_VARS="${6:-}"

args=(run deploy "$SERVICE" --source "$SOURCE_DIR" --region "$REGION" --project "$PROJECT_ID"
  --no-invoker-iam-check --memory "$MEMORY" --cpu-boost --clear-base-image --quiet)
[[ -n "$ENV_VARS" ]] && args+=(--set-env-vars "$ENV_VARS")

# In a fresh project the Cloud Build role of the default compute SA needs ~1 min to propagate.
for attempt in 1 2 3; do
  if gcloud "${args[@]}"; then
    gcloud run services describe "$SERVICE" --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)'
    exit 0
  fi
  echo "deploy of $SERVICE failed (attempt $attempt/3), retrying in 60 s"
  sleep 60
done
exit 1
