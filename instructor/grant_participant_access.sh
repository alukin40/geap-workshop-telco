#!/usr/bin/env bash
# =============================================================================
# Instructor-only: prepare pre-provisioned workshop projects (Google Frictionless
# accounts: devstarNNNN@gcplab.me  <->  pulse-telco-ws-NNNN) for the labs.
#
# Run in Cloud Shell (or any shell) as the event admin, i.e. the Googler who was
# granted Project IAM Admin on all event projects.
#
#   ./instructor/grant_participant_access.sh 4370          # one project (test first)
#   ./instructor/grant_participant_access.sh 4351 4370     # all projects
#   SKIP_APIS=1 ./instructor/grant_participant_access.sh 4351 4370   # IAM only
#
# Override PROJECT_PREFIX ( plus USER_PREFIX / USER_DOMAIN ) when your event uses
# a custom Frictionless project naming prefix instead of "pulse-telco-ws-":
#   PROJECT_PREFIX="custom-event-ws-" ./instructor/grant_participant_access.sh 4351 4370
#
# What it does per project:
#   1. Enables the APIs Lab 00 would enable (saves participants ~3 to 5 minutes).
#   2. Grants the participant the 4 roles that Frictionless' default
#      Editor-based role set lacks but the labs need:
#        roles/resourcemanager.projectIamAdmin:  labs grant roles to persona SAs,
#                                                the agent's Agent Identity, and the
#                                                Cloud Build service account
#        roles/iam.serviceAccountAdmin:          Lab 00 sets IAM on the persona SAs
#        roles/iam.serviceAccountTokenCreator:   Lab 01 mints short-lived tokens
#                                                for the persona SAs (impersonation)
#        roles/logging.privateLogViewer:         Lab 01 reads BigQuery Data Access
#                                                audit logs
# Idempotent: re-running only re-applies the same bindings.
# =============================================================================
set -uo pipefail

FIRST="${1:?usage: $0 FIRST_INDEX [LAST_INDEX]}"
LAST="${2:-$FIRST}"
# Default prefix is "pulse-telco-ws-"; override via environment variable PROJECT_PREFIX for your specific event.
PROJECT_PREFIX="${PROJECT_PREFIX:-pulse-telco-ws-}"
USER_PREFIX="${USER_PREFIX:-devstar}"
USER_DOMAIN="${USER_DOMAIN:-gcplab.me}"

ROLES=(
  roles/resourcemanager.projectIamAdmin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountTokenCreator
  roles/logging.privateLogViewer
)

# Same list as labs/lab00_setup.ipynb Step 0.5, plus notebooks (Workbench fallback). gcloud accepts max 20 per call.
APIS=(
  serviceusage.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com
  iamcredentials.googleapis.com orgpolicy.googleapis.com
  bigquery.googleapis.com dataplex.googleapis.com
  aiplatform.googleapis.com storage.googleapis.com cloudbuild.googleapis.com
  artifactregistry.googleapis.com agentregistry.googleapis.com discoveryengine.googleapis.com
  run.googleapis.com compute.googleapis.com
  logging.googleapis.com monitoring.googleapis.com cloudtrace.googleapis.com
  telemetry.googleapis.com observability.googleapis.com apphub.googleapis.com
  apptopology.googleapis.com cloudapiregistry.googleapis.com
  modelarmor.googleapis.com dlp.googleapis.com
  networkservices.googleapis.com networksecurity.googleapis.com dns.googleapis.com
  iap.googleapis.com secretmanager.googleapis.com
  notebooks.googleapis.com
)

echo "Admin account: $(gcloud config get-value account 2>/dev/null)"
FAILED=()

for i in $(seq "$FIRST" "$LAST"); do
  P="${PROJECT_PREFIX}${i}"
  U="user:${USER_PREFIX}${i}@${USER_DOMAIN}"
  echo
  echo "=== ${P}  ->  ${U}"

  if [[ -z "${SKIP_APIS:-}" ]]; then
    gcloud services enable "${APIS[@]:0:20}" --project="$P" --quiet || FAILED+=("$P: apis batch 1")
    gcloud services enable "${APIS[@]:20}"   --project="$P" --quiet || FAILED+=("$P: apis batch 2")
    echo "  APIs enabled"
  fi

  for R in "${ROLES[@]}"; do
    if gcloud projects add-iam-policy-binding "$P" --member="$U" --role="$R" \
         --condition=None --quiet >/dev/null 2>/tmp/grant_err.txt; then
      echo "  + $R"
    else
      echo "  ! $R FAILED: $(tail -1 /tmp/grant_err.txt)"
      FAILED+=("$P: $R")
    fi
  done

  echo "  participant roles now:"
  gcloud projects get-iam-policy "$P" --flatten="bindings[].members" \
    --filter="bindings.members:${U}" --format="value(bindings.role)" | sort | sed 's/^/    /'
done

echo
if ((${#FAILED[@]})); then
  echo "FAILURES:"; printf '  %s\n' "${FAILED[@]}"; exit 1
fi
echo "All done."
