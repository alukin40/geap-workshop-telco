---
name: pulse-telco-analytics
description: Official schemas, Knowledge Catalog KPI formulas, and SQL query patterns for Pulse Telco multi-domain analytics in BigQuery (telco_crm, telco_billing, telco_network). Use whenever answering CRM, billing, revenue, churn, or network impact questions.
metadata:
  category: BigDataAndAnalytics
  owner: pulse-data-governance
---
# Pulse Telco Multi-Domain Analytics Skill

## Datasets (EU Multi-Region)
1. `telco_crm` — `subscribers`, `subscriptions`
2. `telco_billing` — `invoices`, `payment_transactions`
3. `telco_network` — `cell_towers`, `network_incidents`

Load `references/schema.md` for full column definitions. Always use fully qualified table names: `` `PROJECT.dataset.table` ``.

## Official Knowledge Catalog Definitions (Mandatory)
- **High Churn Risk Subscriber**: An active subscriber (`account_status = 'active'`) with `churn_risk_score >= 0.70` in `telco_crm.subscribers`.
- **Active Subscription ARPU (EUR)**: `ROUND(AVG(monthly_recurring_eur), 2)` over `telco_crm.subscriptions` where `subscription_status = 'active'`.
- **Total Active MRR (EUR)**: `ROUND(SUM(monthly_recurring_eur), 2)` over `telco_crm.subscriptions` where `subscription_status = 'active'`.
- **Delinquent Account Exposure (EUR)**: `ROUND(SUM(total_amount_eur), 2)` over `telco_billing.invoices` where `payment_status = 'overdue' AND days_past_due >= 30`.
- **Disputed Revenue (EUR)**: `ROUND(SUM(total_amount_eur), 2)` over `telco_billing.invoices` where `payment_status = 'disputed'`. Always report Disputed separately from Delinquent/Overdue debt.
- **Degraded Cell Site**: A tower in `telco_network.cell_towers` with `operational_state = 'degraded'`, `avg_utilization_pct >= 85.0`, or `packet_loss_pct >= 1.0`.

## Ready-Made SQL Patterns
### 1. CRM High Churn Risk & Active ARPU by Region
```sql
SELECT
  s.region_code,
  COUNT(DISTINCT s.subscriber_id) AS active_subscribers,
  COUNTIF(s.churn_risk_score >= 0.70) AS high_churn_subscribers,
  ROUND(100.0 * COUNTIF(s.churn_risk_score >= 0.70) / COUNT(DISTINCT s.subscriber_id), 1) AS high_churn_rate_pct
FROM `PROJECT.telco_crm.subscribers` s
WHERE s.account_status = 'active'
GROUP BY s.region_code
ORDER BY high_churn_subscribers DESC
```

### 2. Billing Delinquent (>=30d) vs Disputed Exposure
```sql
SELECT
  billing_period,
  payment_status,
  COUNT(*) AS invoices,
  ROUND(SUM(total_amount_eur), 2) AS total_eur,
  ROUND(SUM(IF(payment_status = 'overdue' AND days_past_due >= 30, total_amount_eur, 0)), 2) AS delinquent_30d_eur
FROM `PROJECT.telco_billing.invoices`
GROUP BY billing_period, payment_status
ORDER BY billing_period, total_eur DESC
```
