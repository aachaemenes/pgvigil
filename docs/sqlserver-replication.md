# SQL Server: replication

Transactional, snapshot and merge replication, read by the `mssql_replication` collection of the [SQL Server engine](sqlserver.md) every 5 minutes and shown in the Replication section of an instance's Availability tab ([availability, Agent jobs and backups](sqlserver-hadr.md)). Nothing is installed on the monitored server and nothing is written there: no tracer token, no call of a replication procedure, only SELECTs over the catalog, the counters, msdb and the distribution database.

| side | reads | needs |
| --- | --- | --- |
| publisher (every server) | each published database in `sys.databases`, its log's reuse wait, the distributor the server names (`sys.servers`), and the counters `Repl. Pending Xacts` and `Repl. Trans. Rate` of the Databases object | VIEW SERVER STATE for the counters (without it they are empty) |
| distributor | the distribution database's own tables: publications, subscriptions, the distribution, log reader, snapshot and merge agents with their history, `MSdistribution_status` for the commands not yet delivered, `MSrepl_errors` for the error text | a user in the distribution database with db_datareader |
| distributor, agents' jobs | each agent's SQL Server Agent job in msdb: running, stopped, disabled, not on this server, and whether its step runs the agent with `-Continuous` | a user in msdb with db_datareader (without it the jobs are not read: the collection says so, and the "stopped" check is blind) |

A publisher whose distributor is another server is judged from its own side (what waits in its log for the log reader); its agents are read on the distributor, so add the distributor as an instance too.

## What is shown

- **Published databases** (this server as publisher): what each publishes, the distributor it names (this server or another one), the transactions marked for replication that still wait in its log for the log reader, the log reuse wait.
- **Publications, subscriptions, agents** as the distributor knows them. Per subscription: the type and state, the distribution agent's last status and message, its job, the commands waiting, **the latency** (below), the time to deliver what waits at the agent's last rate, the agent's own last delivery latency, since when it has been failing or retrying, and the error. Per log reader, snapshot and merge agent: the last status and message, its job, since when it has been failing, the error.
- **Two charts** over the tab's window: the worst subscription's latency, and the commands waiting at the distributor with the transactions waiting in the published logs. Up to two days they are drawn from every read; past two days from hourly minimums, means and maximums, which are kept a year.

## The latency

A subscription's latency is the age, at the read, of the oldest transaction in the distribution database that is still waiting for it (0 when nothing waits). It grows while the distribution agent is stopped, blocked at the subscriber or retrying - when the agent's own latency (its last history row) stays as it was. The time between the commit at the publisher and the transaction's entry into the distribution database is the log reader's: it is judged on the publisher's side.

## An agent's state

- **Failing or retrying**: its newest retry or failure row is newer than its newest idle or succeeded row (it had caught up, or it was stopped cleanly), and - for the distribution agent and the log reader - it has delivered nothing since that failure. Between a job's retries a failing distribution agent writes "in progress" rows ("Error executing a batch of commands. Retrying individual commands.") that deliver nothing; they do not end the failure. "Since" is its first retry or failure row after it was last healthy.
- **The error**: `MSrepl_errors` for the failure's error id. That row is SQL Server's generic "agent failed" message (14151), whose text carries the cause; the code shown is the cause's own when its row follows within 5 seconds (20598: the row was not found at the subscriber).
- **Stopped**: its job is not running (or SQL Server Agent itself is stopped) while the job runs the agent continuously and its publication has an active subscription.
- **Writes nothing**: its job runs and its history has not moved. An idle agent rewrites its history row every minute (`-MessageInterval`'s default); a distribution agent blocked at the subscriber writes nothing until it gets through.

## Findings (`mssql_repl_findings`, part of `mssql_hadr_findings`)

| finding | severity | default threshold | source of the default |
| --- | --- | --- | --- |
| a replication agent failed (its newest row a failure, or failing for less than the threshold below) | warning | - | - |
| a replication agent keeps failing or retrying | warning (critical past a critical threshold) | 10 minutes (`repl_agent_retrying`) | pgvigil's HA design (2026-11-14) |
| a replication agent is stopped (at two reads in a row) | warning | - | pgvigil's HA design |
| a replication agent writes nothing | warning (critical past a critical threshold) | 15 minutes (`repl_agent_silent`) | pgvigil's own default (15 times the agents' 60-second message interval) |
| replication latency over the threshold | warning / critical | 5 / 30 minutes (`repl_latency`) | pgvigil's HA design |
| undistributed commands over the threshold | warning | 100,000 commands (`repl_undistributed_commands` in the configuration's `mssql_thresholds`) | pgvigil's own default, since task 98 |
| replicated transactions wait in the log of a published database (none read out for the threshold) | warning (critical past a critical threshold) | 15 minutes (`repl_agent_silent`) | pgvigil's own default |

The three keys `repl_latency`, `repl_agent_retrying` and `repl_agent_silent` are set on the Thresholds page at the root, a tag or an instance, like every pgvigil threshold; an instance takes its own row, then its tag's, then the root's, then the default. A state older than 15 minutes fires nothing.

## Proven, and not

`scripts/proof-mssql-replication.sh` builds a real lab on SQL Server 2022 (16.0.4315) containers - a publisher, a remote distributor and a subscriber, each container's hostname its server name - with a transactional and a snapshot publication pushed to the subscriber, reads it as a least-privilege login (never sysadmin), and grades what pgvigil stores and finds against what sa reads: a healthy read; the trend under a write; the subscriber's table locked (the latency warning then critical, the silent agent); the distribution agent's job stopped; the log reader's job stopped (the publisher's finding, the distributor's); a row missing at the subscriber (the failure with error 20598, then "keeps failing"); the snapshot folder unwritable (the snapshot agent's failure); each cleared and read clear again; the trend from the reads and from the hours; stubbed reads (a pull subscription's agent, an unread msdb, a failed publisher read, a re-run, a late read).

Not proven: merge replication (SQL Server on Linux has none; on Windows it waits on a lab), peer-to-peer, a pull subscription on a live subscriber, an Azure SQL Managed Instance distributor, SQL Server 2016 to 2019 and 2025, a distributor in an availability group.
