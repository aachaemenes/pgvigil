-- 0198: the collector's error log (DBA Dash's ErrorLog: dbo.CollectionErrorLog, dbo.CollectionErrorClassify) on
-- pgvigil.collection_log, which already keeps every run that did not end well. Nothing is created, changed or switched
-- on on a monitored server.
--
--   stage          where a run failed, a column of its own: 'connect' (the server did not answer; DBA Dash folds this
--                  into Collect), 'collect' (the read on the server), 'import' (the write into the repository - a
--                  batch collection's refused part included, whose run goes on as 'partial'), 'other' (the service's
--                  own work: a rollup's heal). NULL on a row written before this file or by a caller that names none:
--                  collection_error_class reads it from the note then ('connect: ' -> connect, 'rollup ' -> other,
--                  else collect). DBA Dash has a WMI stage; pgvigil reads nothing through WMI
--   log_collection a 7-argument form with p_stage and NO default: a default would make every 6-argument call ambiguous
--                  ('function is not unique'), and every caller drops its error. The 6-argument form (0001) is not
--                  touched: it names no stage, so its rows carry NULL. apply_roles grants every form of the name to the
--                  collector (0110). This file creates its own objects only: no arm of a joined view or function (0190)
--                  reads them
--   the classifier collection_error_class(status, note, stage): the type ('error' -> Error, 'partial' -> Warning: the
--                  run finished carrying a collector_error row, 'skipped' -> Skipped) and the stage as the pages show
--                  them ('import' is the repository's side: a write, or the read of the collector's own cursor).
--                  pgvigil never retries a run, so DBA Dash's Retry type has no rows here. 'ok' rows (0139's
--                  'rollup healed') are not errors: their type is NULL
--   the index      (instance_id, snapshot_at): the page's per-instance views and the Summary's failing run, found by
--                  instance, snapshot and collection (log_collection writes collection_dates and collection_log from one
--                  p_snapshot_at)

ALTER TABLE pgvigil.collection_log ADD COLUMN IF NOT EXISTS stage text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'collection_log_stage_check'
                    AND conrelid = 'pgvigil.collection_log'::regclass) THEN
    -- NOT VALID: every row is NULL when it is added, so the scan under the ALTER's lock would find nothing; new rows
    -- are checked all the same
    ALTER TABLE pgvigil.collection_log ADD CONSTRAINT collection_log_stage_check
      CHECK (stage IN ('connect', 'collect', 'import', 'other')) NOT VALID;
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS collection_log_instance_idx ON pgvigil.collection_log (instance_id, snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.log_collection(
  p_instance_id int, p_collection text, p_snapshot_at timestamptz, p_duration_ms int, p_status text, p_note text,
  p_stage text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, duration_ms, status, note)
  VALUES (p_instance_id, p_collection, p_snapshot_at, p_duration_ms, p_status, p_note)
  ON CONFLICT (instance_id, collection) DO UPDATE
     SET snapshot_at = EXCLUDED.snapshot_at, duration_ms = EXCLUDED.duration_ms,
         status = EXCLUDED.status, note = EXCLUDED.note;
  IF p_status <> 'ok' THEN
    INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, duration_ms, status, note, stage)
    VALUES (p_instance_id, p_collection, p_snapshot_at, p_duration_ms, p_status, p_note, p_stage);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.collection_error_class(p_status text, p_note text, p_stage text,
                                                          OUT error_type text, OUT error_stage text)
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_status WHEN 'error' THEN 'Error' WHEN 'partial' THEN 'Warning' WHEN 'skipped' THEN 'Skipped' END,
         CASE coalesce(p_stage, CASE WHEN p_note LIKE 'connect: %' THEN 'connect'
                                     WHEN p_note LIKE 'rollup %' THEN 'other'
                                     ELSE 'collect' END)
           WHEN 'connect' THEN 'Connect' WHEN 'collect' THEN 'Collect' WHEN 'import' THEN 'Import' ELSE 'Other' END
$$;
