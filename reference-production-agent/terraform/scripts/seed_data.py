#!/usr/bin/env python3
"""Load the Pulse Telco sample data into BigQuery and describe it in Knowledge Catalog (idempotent).

Same approach as labs/lab00 (cells 12 + 14): JSON rows with schema autodetect (WRITE_TRUNCATE),
table descriptions + governance labels, Knowledge Catalog aspect types `telco-governance` /
`telco-semantics` and per-table aspects. The datasets themselves are created by Terraform.
Knowledge Catalog steps are best effort (BigQuery -> Knowledge Catalog entry sync can lag).

Usage: seed_data.py PROJECT_ID PROJECT_NUMBER [BQ_LOCATION] [KC_LOCATION]
"""
import os

os.environ.pop("GOOGLE_API_CERTIFICATE_CONFIG", None)
os.environ["GOOGLE_API_USE_CLIENT_CERTIFICATE"] = "false"

import json
import pathlib
import sys
import time

import google.auth
import requests
from google.auth.transport.requests import Request
from google.cloud import bigquery

DATA_DIR = pathlib.Path(__file__).resolve().parents[3] / "data"
TABLES = [
    ("telco_crm", "subscribers", "crm_subscribers.json"),
    ("telco_crm", "subscriptions", "crm_subscriptions.json"),
    ("telco_billing", "invoices", "billing_invoices.json"),
    ("telco_billing", "payment_transactions", "billing_transactions.json"),
    ("telco_network", "cell_towers", "network_cell_towers.json"),
    ("telco_network", "network_incidents", "network_incidents.json"),
]


def main() -> None:
    project_id, project_number = sys.argv[1], sys.argv[2]
    bq_location = sys.argv[3] if len(sys.argv) > 3 else "EU"
    kc_location = sys.argv[4] if len(sys.argv) > 4 else "eu"
    kc_specs = json.loads((DATA_DIR / "knowledge_catalog_specs.json").read_text())

    bq = bigquery.Client(project=project_id, location=bq_location)
    for ds_id, tbl_id, filename in TABLES:
        fqn = f"{project_id}.{ds_id}.{tbl_id}"
        rows = json.loads((DATA_DIR / filename).read_text())
        bq.load_table_from_json(rows, fqn, job_config=bigquery.LoadJobConfig(autodetect=True, write_disposition="WRITE_TRUNCATE")).result()
        meta = kc_specs["table_metadata"][f"{ds_id}.{tbl_id}"]
        tbl = bq.get_table(fqn)
        tbl.description = (
            f"{meta['description']} | PK: {meta['semantics']['primary_key']} | Joins: {meta['semantics']['join_keys']} | "
            f"KPI Formula: {meta['semantics']['canonical_kpi_formula']} | Rule: {meta['semantics']['business_rules']}"
        )
        tbl.labels = {
            "data_domain": meta["governance"]["data_domain"].lower(),
            "pii_tier": meta["governance"]["pii_classification"].lower(),
            "access_tier": meta["governance"]["required_access_tier"].lower(),
        }
        bq.update_table(tbl, ["description", "labels"])
        print(f"loaded {fqn:<48} {len(rows)} rows")

    # Knowledge Catalog (best effort)
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(Request())
    api = "https://dataplex.googleapis.com/v1"
    h = {"Authorization": f"Bearer {creds.token}", "Content-Type": "application/json", "X-Goog-User-Project": project_id}
    for aspect_id, spec in kc_specs["aspect_types"].items():
        url = f"{api}/projects/{project_id}/locations/{kc_location}/aspectTypes"
        if requests.get(f"{url}/{aspect_id}", headers=h).status_code == 200:
            continue
        fields = [{"name": f["name"], "type": "BOOL" if f["type"] == "bool" else "STRING", "index": i,
                   "annotations": {"description": f["description"]}, "constraints": {"required": False}}
                  for i, f in enumerate(spec["fields"], start=1)]
        body = {"displayName": spec["display_name"], "description": spec["description"],
                "metadataTemplate": {"name": aspect_id.replace("-", "_"), "type": "RECORD", "recordFields": fields}}
        r = requests.post(url, params={"aspectTypeId": aspect_id}, headers=h, json=body)
        if r.status_code in (200, 201) and "/operations/" in r.json().get("name", ""):
            for _ in range(30):
                if requests.get(f"{api}/{r.json()['name']}", headers=h).json().get("done"):
                    break
                time.sleep(2)
        print(f"Knowledge Catalog aspect type {aspect_id}: HTTP {r.status_code}")

    for ds_id, tbl_id, _ in TABLES:
        entry = (f"projects/{project_id}/locations/{kc_location}/entryGroups/@bigquery/entries/"
                 f"bigquery.googleapis.com/projects/{project_id}/datasets/{ds_id}/tables/{tbl_id}")
        meta = kc_specs["table_metadata"][f"{ds_id}.{tbl_id}"]
        payload = {"aspects": {
            f"{project_number}.{kc_location}.telco-governance": {
                "aspectType": f"projects/{project_number}/locations/{kc_location}/aspectTypes/telco-governance", "data": meta["governance"]},
            f"{project_number}.{kc_location}.telco-semantics": {
                "aspectType": f"projects/{project_number}/locations/{kc_location}/aspectTypes/telco-semantics", "data": meta["semantics"]},
        }}
        for _ in range(15):
            r = requests.patch(f"{api}/{entry}", params={"updateMask": "aspects"}, headers=h, json=payload)
            if r.status_code == 200:
                print(f"Knowledge Catalog aspects attached -> {ds_id}.{tbl_id}")
                break
            time.sleep(6)
        else:
            print(f"WARNING: Knowledge Catalog aspects not attached to {ds_id}.{tbl_id} yet (HTTP {r.status_code}); re-run apply later")


if __name__ == "__main__":
    main()
