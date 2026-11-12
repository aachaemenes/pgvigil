-- 0120: System events in the shape of PerformanceMonitor's System Events page and sp_HealthParser (task 177 D15).
--
-- The system_health reader (internal/mssql/syshealth.go, readers_sysevents.go) stores, beside sp_server_diagnostics'
-- component results, the four events sp_HealthParser reads from the same file, each a row of mssql_health_components
-- under a component of its own with state EVENT (the table, its importer and purge() hold them as they are):
--   MEMORY_BROKER      memory_broker_ring_buffer_recorded: a broker's notification (grow, shrink, stable) and figures
--   MEMORY_NODE_OOM    memory_node_oom_ring_buffer_recorded: a memory node's out-of-memory record
--   SCHEDULER_MONITOR  scheduler_monitor_system_health_ring_buffer_recorded: SQL Server's CPU, idle, memory utilization
--   WAIT_INFO          wait_info: a long wait, with the session and its statement
--
--   mssql_wait_ignorable(wait_type)    sp_HealthParser's list of waits left out of 'queries with significant waits'
--   mssql_sysevents_findings           instance_id, severity, check_name, object, at, detail:
--     'system_health: other processes used half the CPU'   a scheduler monitor sample in the last hour with other
--                                                           processes at 50 % or more (100 - SQL Server - idle)
--     'system_health: the working set was trimmed'         a sample in the last hour with memory_utilization at 50
--                                                           or less (external memory pressure)
--     'the ring buffer output was cut off'                 an Extended Events read in the last hour whose ring
--                                                           buffer XML came back cut: the newest events are missing
--
-- The thresholds, the wait filter and the ignorable list are sp_HealthParser's (Darling Data, LLC; MIT); the
-- statements are pgvigil's own:
--   Copyright (c) 2021 Darling Data, LLC. Permission is hereby granted, free of charge, to any person obtaining a copy
--   of this software and associated documentation files (the "Software"), to deal in the Software without
--   restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute,
--   sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
--   subject to the following conditions: The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
--   KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
--   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
--   OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
--   WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--
-- For the join (0190): the arm in pgvigil.findings
--     SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_sysevents', at
--       FROM pgvigil.mssql_sysevents_findings
--   nothing for purge() (the rows live in mssql_health_components, already a monthly parent).

COMMENT ON COLUMN pgvigil.mssql_health_components.component IS
  'SYSTEM | RESOURCE | QUERY_PROCESSING | IO_SUBSYSTEM (sp_server_diagnostics, state CLEAN / WARNING / ERROR), or one of '
  'the events read beside them (state EVENT): MEMORY_BROKER, MEMORY_NODE_OOM, SCHEDULER_MONITOR, WAIT_INFO (0120)';

CREATE OR REPLACE FUNCTION pgvigil.mssql_wait_ignorable(p_wait_type text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_wait_type = ANY (ARRAY[
    'ASYNC_IO_COMPLETION', 'AZURE_IMDS_VERSIONS', 'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR',
    'BROKER_TASK_STOP', 'BROKER_TO_FLUSH', 'BROKER_TRANSMITTER', 'CHECKPOINT_QUEUE',
    'CHKPT', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'CLR_SEMAPHORE',
    'DBMIRROR_DBM_EVENT', 'DBMIRROR_DBM_MUTEX', 'DBMIRROR_EVENTS_QUEUE', 'DBMIRROR_SEND',
    'DBMIRROR_WORKER_QUEUE', 'DBMIRRORING_CMD', 'DIRTY_PAGE_POLL', 'DISPATCHER_QUEUE_SEMAPHORE',
    'FSAGENT', 'FT_IFTS_SCHEDULER_IDLE_WAIT', 'FT_IFTSHC_MUTEX', 'HADR_CLUSAPI_CALL',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'HADR_LOGCAPTURE_WAIT', 'HADR_NOTIFICATION_DEQUEUE', 'HADR_TIMER_TASK',
    'HADR_WORK_QUEUE', 'KSOURCE_WAKEUP', 'LAZYWRITER_SLEEP', 'LOGMGR_QUEUE',
    'MEMORY_ALLOCATION_EXT', 'ONDEMAND_TASK_QUEUE', 'PARALLEL_REDO_DRAIN_WORKER', 'PARALLEL_REDO_LOG_CACHE',
    'PARALLEL_REDO_TRAN_LIST', 'PARALLEL_REDO_WORKER_SYNC', 'PARALLEL_REDO_WORKER_WAIT_WORK', 'PREEMPTIVE_OS_FLUSHFILEBUFFERS',
    'PREEMPTIVE_XE_GETTARGETSTATE', 'PVS_PREALLOCATE', 'PWAIT_ALL_COMPONENTS_INITIALIZED', 'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
    'PWAIT_EXTENSIBILITY_CLEANUP_TASK', 'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_SHUTDOWN_QUEUE', 'REDO_THREAD_PENDING_WORK', 'REQUEST_FOR_DEADLOCK_SEARCH', 'RESOURCE_QUEUE',
    'SERVER_IDLE_CHECK', 'SLEEP_DBSTARTUP', 'SLEEP_DCOMSTARTUP', 'SLEEP_MASTERDBREADY',
    'SLEEP_MASTERMDREADY', 'SLEEP_MASTERUPGRADED', 'SLEEP_MSDBSTARTUP', 'SLEEP_SYSTEMTASK',
    'SLEEP_TEMPDBSTARTUP', 'SNI_HTTP_ACCEPT', 'SOS_WORK_DISPATCHER', 'SP_SERVER_DIAGNOSTICS_SLEEP',
    'SQLTRACE_BUFFER_FLUSH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', 'SQLTRACE_WAIT_ENTRIES', 'UCS_SESSION_REGISTRATION',
    'VDI_CLIENT_OTHER', 'WAIT_FOR_RESULTS', 'WAIT_XTP_CKPT_CLOSE', 'WAIT_XTP_HOST_WAIT',
    'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', 'WAIT_XTP_RECOVERY', 'WAITFOR', 'WAITFOR_TASKSHUTDOWN',
    'XE_DISPATCHER_JOIN', 'XE_DISPATCHER_WAIT', 'XE_FILE_TARGET_TVF', 'XE_LIVE_TARGET_TVF', 'XE_TIMER_EVENT'])
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_sysevents_findings AS
WITH sm AS (
  SELECT h.instance_id, h.event_at,
         pgvigil.mssql_health_num(h.detail, 'process_utilization') AS sql_cpu,
         100 - pgvigil.mssql_health_num(h.detail, 'process_utilization') - pgvigil.mssql_health_num(h.detail, 'system_idle') AS other_cpu,
         pgvigil.mssql_health_num(h.detail, 'memory_utilization') AS memory_utilization
    FROM pgvigil.mssql_health_components h
   WHERE h.component = 'SCHEDULER_MONITOR' AND h.event_at > now() - interval '1 hour'
)
SELECT sm.instance_id, 'warning'::text AS severity, 'system_health: other processes used half the CPU'::text AS check_name,
       'the scheduler monitor'::text AS object, max(sm.event_at) AS at,
       count(*) || ' sample(s) in the last hour with other processes at 50 % or more of the CPU (the most ' || max(sm.other_cpu)
         || ' %, SQL Server ' || (array_agg(sm.sql_cpu ORDER BY sm.other_cpu DESC))[1] || ' % at that sample): something '
         || 'else on the machine is taking the CPU SQL Server would use' AS detail
  FROM sm WHERE sm.other_cpu >= 50
 GROUP BY sm.instance_id
UNION ALL
SELECT sm.instance_id, 'warning', 'system_health: the working set was trimmed', 'the scheduler monitor', max(sm.event_at),
       count(*) || ' sample(s) in the last hour with memory utilization at 50 or less (the least ' || min(sm.memory_utilization)
         || '): the share of SQL Server''s committed memory in its working set; a low one means Windows trimmed the '
         || 'working set, the sign of memory pressure from outside SQL Server'
  FROM sm WHERE sm.memory_utilization <= 50
 GROUP BY sm.instance_id
UNION ALL
SELECT s.instance_id, 'warning', 'the ring buffer output was cut off', s.capture, s.snapshot_at,
       'the XML of ' || coalesce(s.session_name, s.capture) || '''s ring buffer came back cut at the read of '
         || to_char(s.snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
         || coalesce(' (the buffer held ' || s.event_count || ' event(s))', '')
         || ': the newest events are the ones missing; an event_file target keeps the whole history'
  FROM pgvigil.mssql_xe_state s
 WHERE s.truncated AND s.snapshot_at > now() - interval '1 hour';
