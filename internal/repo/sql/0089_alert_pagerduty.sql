-- 0089: the PagerDuty channel kind (internal/alerts/pagerduty.go). alert_channels.kind takes 'pagerduty' beside smtp,
-- webhook and file; nothing else changes (alert_log.kind has no check, alert_sync and alert_record pass kind through).
ALTER TABLE pgvigil.alert_channels DROP CONSTRAINT IF EXISTS alert_channels_kind_check;
ALTER TABLE pgvigil.alert_channels ADD CONSTRAINT alert_channels_kind_check
  CHECK (kind IN ('smtp', 'webhook', 'file', 'pagerduty'));
