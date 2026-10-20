# Pulse Telco BigQuery Schemas (EU)

## 1. Dataset `telco_crm`
### `subscribers`
| Column | Type | Notes |
| --- | --- | --- |
| `subscriber_id` | STRING | PK (`SUB-1001` .. `SUB-1060`) |
| `customer_segment` | STRING | `consumer`, `sme`, `enterprise` |
| `region_code` | STRING | `PRG`, `BRN`, `OVA`, `BTS`, `VIE` |
| `tenure_months` | INT64 | Months with Pulse Telco |
| `churn_risk_score` | FLOAT64 | `>= 0.70` = High Churn Risk |
| `nps_band` | STRING | `promoter`, `passive`, `detractor` |
| `primary_tower_id` | STRING | FK -> `telco_network.cell_towers.tower_id` |
| `account_status` | STRING | `active`, `suspended` |

### `subscriptions`
| Column | Type | Notes |
| --- | --- | --- |
| `subscription_id` | STRING | PK (`PLN-2001` ..) |
| `subscriber_id` | STRING | FK -> `telco_crm.subscribers.subscriber_id` |
| `tariff_code` | STRING | `PULSE-5G-UNL`, `PULSE-5G-PRO`, `PULSE-START-10G`, `PULSE-FIBER-1G`, `PULSE-BIZ-FLEET` |
| `tariff_name` | STRING | Human-readable plan name |
| `service_type` | STRING | `mobile_5g`, `fixed_fiber`, `converged_biz` |
| `monthly_recurring_eur` | FLOAT64 | Monthly charge in EUR |
| `data_allowance_gb` | INT64 | `-1` = Unlimited |
| `subscription_status` | STRING | `active`, `paused` |

## 2. Dataset `telco_billing`
### `invoices`
| Column | Type | Notes |
| --- | --- | --- |
| `invoice_id` | STRING | PK (`INV-2026-5001` ..) |
| `subscriber_id` | STRING | FK -> `telco_crm.subscribers.subscriber_id` |
| `billing_period` | STRING | `2026-07`, `2026-08` |
| `base_charge_eur` | FLOAT64 | Tariff base charge |
| `roaming_surcharge_eur` | FLOAT64 | Roaming charges |
| `total_amount_eur` | FLOAT64 | Total invoice amount in EUR |
| `payment_status` | STRING | `paid`, `overdue`, `disputed` |
| `days_past_due` | INT64 | `>= 30` with `overdue` = Delinquent Account |

### `payment_transactions`
| Column | Type | Notes |
| --- | --- | --- |
| `tx_id` | STRING | PK (`TX-9001` ..) |
| `invoice_id` | STRING | FK -> `telco_billing.invoices.invoice_id` |
| `subscriber_id` | STRING | FK -> `telco_crm.subscribers.subscriber_id` |
| `payment_method` | STRING | `sepa_direct_debit`, `card_online`, `bank_transfer`, `apple_pay` |
| `amount_eur` | FLOAT64 | Transaction amount in EUR |
| `tx_status` | STRING | `settled`, `failed_insufficient_funds`, `chargeback_disputed` |
| `billing_note` | STRING | Free-text customer/billing note (untrusted external text) |
