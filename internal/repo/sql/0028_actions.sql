-- 0028_actions: the audit of the actions door (cancel and terminate from the UI).
--   pgvigil.actions_log keeps every attempt: who (the UI login and the client address), what (the action,
--   the pid and the backend_start of the row shown, the target's role and application), why (the typed
--   reason) and how it ended (done, refused or failed, with the detail). A refused attempt is kept like a
--   done one: the audit is of attempts, not of signals sent.
--   The serve process writes it through pgvigil.import_actions_log, a SECURITY DEFINER import the collector
--   login may call (apply_roles grants every import_* to pgvigil_collector); nobody but the owner may UPDATE
--   or DELETE a row. The table is not partitioned and purge() leaves it alone: an audit is kept until the
--   owner removes it by hand.
--   instance_name is stored beside instance_id so a row outlives a removed instance (ON DELETE SET NULL).

CREATE TABLE pgvigil.actions_log (
  action_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id    int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  instance_name  text NOT NULL,
  at             timestamptz NOT NULL,
  ui_user        text NOT NULL,
  client         text,
  action         text NOT NULL CHECK (action IN ('cancel', 'terminate')),
  pid            int NOT NULL,
  backend_start  timestamptz,
  target_user    text,
  target_app     text,
  reason         text NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
  outcome        text NOT NULL CHECK (outcome IN ('done', 'refused', 'failed')),
  detail         text
);
CREATE INDEX actions_log_inst_at_idx ON pgvigil.actions_log (instance_id, at DESC);
COMMENT ON TABLE pgvigil.actions_log IS 'Every cancel / terminate attempt from the UI (done, refused or failed); written through import_actions_log only.';

CREATE OR REPLACE FUNCTION pgvigil.import_actions_log(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.actions_log (instance_id, instance_name, at, ui_user, client, action, pid, backend_start,
                                   target_user, target_app, reason, outcome, detail)
  SELECT p_instance_id, x.instance_name, coalesce(x.at, p_snapshot_at), x.ui_user, nullif(x.client, ''), x.action, x.pid,
         x.backend_start, nullif(x.target_user, ''), nullif(x.target_app, ''), x.reason, x.outcome, nullif(x.detail, '')
    FROM jsonb_to_recordset(p_payload) AS x(instance_name text, at timestamptz, ui_user text, client text, action text,
                                            pid int, backend_start timestamptz, target_user text, target_app text,
                                            reason text, outcome text, detail text)
$$;
