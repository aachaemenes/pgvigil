-- 0021_host: the host the instance runs on (phase 2a, task 32), read every minute through one of two doors:
--   on-prem: the system_stats extension where the client's DBA installed it and granted monitor_system_stats to
--            the monitoring login (OS name and version - the RedHat or Ubuntu answer -, CPU, memory, load, the
--            disks per mount, the IO counters per device);
--   RDS / Aurora: CloudWatch through the instance's aws: block (CPUUtilization, FreeableMemory,
--            FreeStorageSpace or FreeLocalStorage, SwapUsage, DatabaseConnections).
-- Neither door = the collection is skipped with its reason (collection_log), never an error.
--   host_state         the current row per instance: what the host is (OS, CPU, memory size, the door).
--   host_sample        the per-minute figures (partitioned by month).
--   host_disks         the current row per volume (one per device: bind mounts of one device fold into it).
--   host_disk_history  a volume's size at most every 15 minutes (partitioned): the days-until-full forecast's input.
--   host_io            system_stats' per-device IO counters as read (partitioned); host_io_rate() takes the rates.
-- host_checks feeds the overview (check groups 'host' and 'disk': the Summary columns Host and Disk) and
-- host_findings carries the same rules in the findings columns (the join adds it to pgvigil.findings).

CREATE TABLE IF NOT EXISTS pgvigil.host_state (
  instance_id    int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at    timestamptz NOT NULL,
  source         text NOT NULL,              -- system_stats | cloudwatch
  os_name        text,                       -- pg_sys_os_info.name, e.g. 'Red Hat Enterprise Linux 9.4 (Plow)'
  os_version     text,                       -- the kernel line
  architecture   text,
  host_name      text,
  cpu_model      text,
  cpu_cores      int,                        -- physical cores
  logical_cpus   int,
  mem_total      bigint,
  swap_total     bigint,
  uptime_secs    bigint,
  aws_resource   text,                       -- cloudwatch: the DB instance identifier read
  extension_version text                     -- system_stats: its installed version
);

CREATE TABLE IF NOT EXISTS pgvigil.host_sample (
  instance_id     int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  source          text NOT NULL,
  cpu_pct         real,                      -- 100 - idle (system_stats) or CPUUtilization (cloudwatch)
  cpu_user_pct    real,
  cpu_system_pct  real,
  cpu_iowait_pct  real,
  mem_total       bigint,
  mem_used        bigint,
  mem_free        bigint,                    -- system_stats: free; cloudwatch: FreeableMemory
  mem_cache       bigint,
  swap_total      bigint,
  swap_used       bigint,                    -- cloudwatch: SwapUsage
  load1           real,
  load5           real,
  load15          real,
  connections     int,                       -- cloudwatch: DatabaseConnections
  metrics_at      timestamptz                -- cloudwatch: the newest datapoint's time (the sample's age)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.host_disks (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  mount_point   text NOT NULL,               -- the mount that holds data_directory, else the shortest; 'rds:storage' / 'aurora:local' in the cloud
  snapshot_at   timestamptz NOT NULL,
  source        text NOT NULL,
  device        text,                        -- the file system's device, or the DB instance identifier
  fs_type       text,
  total_bytes   bigint,                      -- NULL when the door does not say (Aurora local storage)
  used_bytes    bigint,
  free_bytes    bigint,
  mounts        text[],                      -- every mount point of the device
  holds_data    boolean,                     -- the instance's data_directory lives on it
  first_seen    timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, mount_point)
);

CREATE TABLE IF NOT EXISTS pgvigil.host_disk_history (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  mount_point   text NOT NULL,
  total_bytes   bigint,
  used_bytes    bigint,
  free_bytes    bigint
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.host_io (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  device         text NOT NULL,
  reads          bigint,
  writes         bigint,
  read_bytes     bigint,
  write_bytes    bigint,
  read_time_ms   bigint,
  write_time_ms  bigint
) PARTITION BY RANGE (snapshot_at);

-- payload: {kind:'host', source, os_name, ..., cpu_pct, ...} once, {kind:'disk', mount_point, ...} per volume,
-- {kind:'io', device, ...} per device, {kind:'collector_error', source, message} for a part that failed.
-- A volume no longer listed is marked absent only when this payload carries a 'host' row and no
-- error for the disks (a failed disk read keeps the volumes as they were).
CREATE OR REPLACE FUNCTION pgvigil.import_host(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  h jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_host'), p_instance_id);
  SELECT r INTO h FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'host' LIMIT 1;

  IF h IS NOT NULL THEN
    PERFORM pgvigil.ensure_month_partition('host_sample', p_snapshot_at);
    INSERT INTO pgvigil.host_state AS s (instance_id, snapshot_at, source, os_name, os_version, architecture, host_name, cpu_model,
                                         cpu_cores, logical_cpus, mem_total, swap_total, uptime_secs, aws_resource, extension_version)
    VALUES (p_instance_id, p_snapshot_at, h->>'source', h->>'os_name', h->>'os_version', h->>'architecture', h->>'host_name',
            h->>'cpu_model', (h->>'cpu_cores')::int, (h->>'logical_cpus')::int, (h->>'mem_total')::bigint, (h->>'swap_total')::bigint,
            (h->>'uptime_secs')::bigint, h->>'aws_resource', h->>'extension_version')
    ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, source = EXCLUDED.source,
      -- a part that failed this run (NULL) keeps what an earlier run read
      os_name = coalesce(EXCLUDED.os_name, s.os_name), os_version = coalesce(EXCLUDED.os_version, s.os_version),
      architecture = coalesce(EXCLUDED.architecture, s.architecture), host_name = coalesce(EXCLUDED.host_name, s.host_name),
      cpu_model = coalesce(EXCLUDED.cpu_model, s.cpu_model), cpu_cores = coalesce(EXCLUDED.cpu_cores, s.cpu_cores),
      logical_cpus = coalesce(EXCLUDED.logical_cpus, s.logical_cpus), mem_total = coalesce(EXCLUDED.mem_total, s.mem_total),
      swap_total = coalesce(EXCLUDED.swap_total, s.swap_total), uptime_secs = EXCLUDED.uptime_secs,
      aws_resource = EXCLUDED.aws_resource, extension_version = EXCLUDED.extension_version;

    INSERT INTO pgvigil.host_sample (instance_id, snapshot_at, source, cpu_pct, cpu_user_pct, cpu_system_pct, cpu_iowait_pct, mem_total,
                                     mem_used, mem_free, mem_cache, swap_total, swap_used, load1, load5, load15, connections, metrics_at)
    VALUES (p_instance_id, p_snapshot_at, h->>'source', (h->>'cpu_pct')::real, (h->>'cpu_user_pct')::real, (h->>'cpu_system_pct')::real,
            (h->>'cpu_iowait_pct')::real, (h->>'mem_total')::bigint, (h->>'mem_used')::bigint, (h->>'mem_free')::bigint,
            (h->>'mem_cache')::bigint, (h->>'swap_total')::bigint, (h->>'swap_used')::bigint, (h->>'load1')::real, (h->>'load5')::real,
            (h->>'load15')::real, (h->>'connections')::int, (h->>'metrics_at')::timestamptz);
  END IF;

  INSERT INTO pgvigil.host_disks AS d (instance_id, mount_point, snapshot_at, source, device, fs_type, total_bytes, used_bytes,
                                       free_bytes, mounts, holds_data, first_seen, is_present)
  SELECT p_instance_id, r->>'mount_point', p_snapshot_at, r->>'source', r->>'device', r->>'fs_type', (r->>'total_bytes')::bigint,
         (r->>'used_bytes')::bigint, (r->>'free_bytes')::bigint,
         CASE WHEN jsonb_typeof(r->'mounts') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'mounts')) END,
         (r->>'holds_data')::boolean, p_snapshot_at, true
    FROM (SELECT DISTINCT ON (r->>'mount_point') r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'disk') x
  ON CONFLICT (instance_id, mount_point) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, source = EXCLUDED.source, device = EXCLUDED.device, fs_type = EXCLUDED.fs_type,
    total_bytes = EXCLUDED.total_bytes, used_bytes = EXCLUDED.used_bytes, free_bytes = EXCLUDED.free_bytes,
    mounts = EXCLUDED.mounts, holds_data = EXCLUDED.holds_data, is_present = true;

  IF h IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                                    WHERE r->>'kind' = 'collector_error' AND r->>'source' IN ('system_stats:disk', 'cloudwatch', 'rds')) THEN
    UPDATE pgvigil.host_disks d SET is_present = false
     WHERE d.instance_id = p_instance_id AND d.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                        WHERE r->>'kind' = 'disk' AND r->>'mount_point' = d.mount_point);
  END IF;

  -- the history keeps a volume's size at most every 15 minutes (96 rows a day): enough for a growth line
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'disk') THEN
    PERFORM pgvigil.ensure_month_partition('host_disk_history', p_snapshot_at);
    INSERT INTO pgvigil.host_disk_history (instance_id, snapshot_at, mount_point, total_bytes, used_bytes, free_bytes)
    SELECT p_instance_id, p_snapshot_at, r->>'mount_point', (r->>'total_bytes')::bigint, (r->>'used_bytes')::bigint, (r->>'free_bytes')::bigint
      FROM (SELECT DISTINCT ON (r->>'mount_point') r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'disk') x
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.host_disk_history y
                        WHERE y.instance_id = p_instance_id AND y.mount_point = x.r->>'mount_point'
                          AND y.snapshot_at > p_snapshot_at - interval '15 minutes' AND y.snapshot_at < p_snapshot_at + interval '15 minutes');
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'io') THEN
    PERFORM pgvigil.ensure_month_partition('host_io', p_snapshot_at);
    INSERT INTO pgvigil.host_io (instance_id, snapshot_at, device, reads, writes, read_bytes, write_bytes, read_time_ms, write_time_ms)
    SELECT p_instance_id, p_snapshot_at, r->>'device', (r->>'reads')::bigint, (r->>'writes')::bigint, (r->>'read_bytes')::bigint,
           (r->>'write_bytes')::bigint, (r->>'read_time_ms')::bigint, (r->>'write_time_ms')::bigint
      FROM (SELECT DISTINCT ON (r->>'device') r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'io') x;
  END IF;
END $$;

-- The per-second IO rates per device over a window; a counter that fell (a reboot) gives no point.
CREATE OR REPLACE FUNCTION pgvigil.host_io_rate(p_instance_id int, p_from timestamptz, p_to timestamptz, p_lookback interval DEFAULT interval '15 minutes')
RETURNS TABLE (snapshot_at timestamptz, device text, interval_secs int, reads_s numeric, writes_s numeric,
               read_bytes_s numeric, write_bytes_s numeric, read_ms_per_op numeric, write_ms_per_op numeric)
LANGUAGE sql STABLE AS $$
  WITH w AS (
    SELECT i.*, extract(epoch FROM i.snapshot_at - lag(i.snapshot_at) OVER k) AS secs,
           i.reads - lag(i.reads) OVER k AS dr, i.writes - lag(i.writes) OVER k AS dw,
           i.read_bytes - lag(i.read_bytes) OVER k AS drb, i.write_bytes - lag(i.write_bytes) OVER k AS dwb,
           i.read_time_ms - lag(i.read_time_ms) OVER k AS drt, i.write_time_ms - lag(i.write_time_ms) OVER k AS dwt
      FROM pgvigil.host_io i
     WHERE i.instance_id = p_instance_id AND i.snapshot_at > p_from - p_lookback AND i.snapshot_at <= p_to
    WINDOW k AS (PARTITION BY i.device ORDER BY i.snapshot_at)
  )
  SELECT snapshot_at, device, secs::int, round(dr / secs::numeric, 2), round(dw / secs::numeric, 2),
         round(drb / secs::numeric, 0), round(dwb / secs::numeric, 0),
         round(drt::numeric / nullif(dr, 0), 2), round(dwt::numeric / nullif(dw, 0), 2)
    FROM w
   WHERE secs > 0 AND snapshot_at > p_from AND dr >= 0 AND dw >= 0 AND drb >= 0 AND dwb >= 0
$$;

-- The newest sample per instance beside what the host is (the Host tab's head and the fleet Disk report's
-- columns); a sample older than 10 minutes is still shown, its age says how old.
CREATE OR REPLACE VIEW pgvigil.host_latest AS
SELECT s.instance_id, s.source, s.os_name, s.os_version, s.architecture, s.host_name, s.cpu_model, s.cpu_cores, s.logical_cpus,
       s.uptime_secs, s.aws_resource, s.extension_version, s.snapshot_at AS state_at,
       x.snapshot_at, x.cpu_pct, x.cpu_user_pct, x.cpu_system_pct, x.cpu_iowait_pct, x.mem_total, x.mem_used, x.mem_free, x.mem_cache,
       x.swap_total, x.swap_used, x.load1, x.load5, x.load15, x.connections, x.metrics_at
  FROM pgvigil.host_state s
  LEFT JOIN LATERAL (SELECT * FROM pgvigil.host_sample h
                      WHERE h.instance_id = s.instance_id AND h.snapshot_at > s.snapshot_at - interval '1 day'
                      ORDER BY h.snapshot_at DESC LIMIT 1) x ON true;

-- Every present volume with its free share (NULL where the door gives no total).
CREATE OR REPLACE VIEW pgvigil.disk_report AS
SELECT d.instance_id, i.name AS instance, i.platform, d.mount_point, d.device, d.fs_type, d.source, d.total_bytes, d.used_bytes,
       d.free_bytes, round(100.0 * d.free_bytes / nullif(d.total_bytes, 0), 1) AS free_pct, d.mounts, d.holds_data, d.snapshot_at
  FROM pgvigil.host_disks d
  JOIN pgvigil.instances i USING (instance_id)
 WHERE d.is_present AND i.is_active;

-- The overview's host and disk checks (instance_id, severity, check_name, object, at, detail, check_group):
--   disk free under 10 % (critical under 5 %), read in the last hour;
--   swap in use on the newest sample of the last 15 minutes: on-prem over 5 % of the swap and over 256 MB; RDS / Aurora
--   SwapUsage over 1 GB (an idle Serverless v2 instance carries a few hundred MB: the lab's showed 325-384 MB);
--   CPU over 90 % on every CPU reading of the last 10 minutes: at least 5 distinct readings (a CloudWatch datapoint
--   counts once however many samples repeat it) spanning 8 minutes or more; samples without a CPU value do not count.
CREATE OR REPLACE VIEW pgvigil.host_checks AS
SELECT d.instance_id, CASE WHEN d.free_pct < 5 THEN 'critical' ELSE 'warning' END AS severity, 'disk free under 10 %' AS check_name,
       d.mount_point AS object, d.snapshot_at AS at,
       d.free_pct::text || ' % free: ' || pg_size_pretty(d.free_bytes) || ' of ' || pg_size_pretty(d.total_bytes)
       || CASE WHEN d.holds_data THEN ' (holds the data directory)' ELSE '' END AS detail,
       'disk' AS check_group
  FROM pgvigil.disk_report d
 WHERE d.free_pct < 10 AND d.snapshot_at > now() - interval '1 hour'
UNION ALL
SELECT l.instance_id, 'warning', 'swap used', coalesce(l.host_name, l.aws_resource, l.source), l.snapshot_at,
       pg_size_pretty(l.swap_used) || ' of swap in use' || coalesce(' (of ' || pg_size_pretty(nullif(l.swap_total, 0)) || ')', ''),
       'host'
  FROM pgvigil.host_latest l
 WHERE l.snapshot_at > now() - interval '15 minutes'
   AND CASE WHEN l.source = 'cloudwatch' THEN l.swap_used > 1024 * 1024 * 1024
            ELSE l.swap_used > 0.05 * nullif(l.swap_total, 0) AND l.swap_used > 256 * 1024 * 1024 END
UNION ALL
SELECT s.instance_id, CASE WHEN c.min_cpu >= 98 THEN 'critical' ELSE 'warning' END, 'CPU over 90 % for 10 minutes',
       coalesce(s.host_name, s.aws_resource, s.source), c.last_at,
       'lowest ' || round(c.min_cpu::numeric, 1)::text || ' %, average ' || round(c.avg_cpu::numeric, 1)::text || ' % over '
       || c.n::text || ' samples',
       'host'
  FROM pgvigil.host_state s
  CROSS JOIN LATERAL (
        -- per instance, so the partitions' (instance_id, snapshot_at) index drives it
        SELECT s.instance_id, min(h.cpu_pct) AS min_cpu, avg(h.cpu_pct) AS avg_cpu,
               count(DISTINCT coalesce(h.metrics_at, h.snapshot_at)) AS n,
               max(coalesce(h.metrics_at, h.snapshot_at)) AS last_at, min(coalesce(h.metrics_at, h.snapshot_at)) AS first_at
          FROM pgvigil.host_sample h
         WHERE h.instance_id = s.instance_id AND h.snapshot_at > now() - interval '10 minutes' AND h.cpu_pct IS NOT NULL) c
 WHERE c.min_cpu > 90 AND c.n >= 5 AND c.last_at - c.first_at >= interval '8 minutes';

-- The same rules in the findings columns; the join UNION ALLs this into pgvigil.findings.
CREATE OR REPLACE VIEW pgvigil.host_findings AS
SELECT c.instance_id, c.severity, c.check_name AS setting, c.object || ': ' || c.detail AS value, true AS is_set,
       CASE c.check_name WHEN 'disk free under 10 %' THEN 'grow the volume or free space before it fills'
                         WHEN 'swap used' THEN 'no swap: memory is short (shared_buffers, work_mem, connections)'
                         ELSE 'find the statements behind the CPU (Statements by time)' END AS suggested,
       CASE c.check_name WHEN 'disk free under 10 %' THEN 'all' ELSE 'all' END AS platforms,
       CASE c.check_name WHEN 'disk free under 10 %' THEN 'a full volume stops the server: WAL cannot be written and the instance shuts down'
                         WHEN 'swap used' THEN 'a host that swaps pages database memory out to disk: every access to it becomes an IO'
                         ELSE 'CPU saturated for 10 minutes: queries queue for CPU and every response slows' END AS detail,
       'pgvigil host' AS source, c.at
  FROM pgvigil.host_checks c;
