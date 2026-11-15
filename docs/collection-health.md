# Collection Health

Checks > Collection Health shows, for each collection pgvigil runs, how often it succeeded, failed or ended partial
over the picked range, how long it took, and its status. It follows DBA Dash 4.25.0's page of the same name: the
same status rule with DBA Dash's default numbers, the same columns where pgvigil has the data, the same Show picker
and status filter. It opens at the root, on a tag folder (its instances) and on an instance. The Summary's
**Collection Health** column is judged by the same rule and opens an instance's tab.

## The status

The repository judges each collection of each instance (`pgvigil.collection_health`, migration 0166):

| Status | When |
|---|---|
| Critical | 3 or more failures in a row and 30 minutes or more from the last success to the latest failure (never succeeded: the 3 failures alone), or 50 % or more of 5 or more runs failed with the last run failed |
| Warning | 1 or more failures in a row and 10 minutes or more from the last success to the latest failure (never succeeded: the failure alone), or 10 % or more of 5 or more runs failed or ended partial |
| N/A | the collection is off for the instance, or it only skipped |
| OK | otherwise |

A partial run counts as a success for the failures in a row and for Last Success, and as a problem in the warning
rate. A skip is not a run, but a skip after failures ends the failures in a row. A run that could not connect, or
that connected and failed before pgvigil read the server's version, is a failed run. A collection failing now is
listed even when the range holds none of its runs, while its last run is within three of its intervals (a day at
least). An instance that is not active is not listed. The failures in a row are always now's; the rates are over
the picked range. **Failed % 24hrs** is the rate the Summary judges (24 hours from the next whole hour).

The rates come from the hourly totals `pgvigil run` sends with its heartbeat once a minute. An instance read only by
a scheduled `pgvigil collect` has no heartbeat: it is judged by its failures in a row alone.

## The page

- **Show**: *Row per collection per instance* (the default at every level) or *Row per collection* - each collection
  once over the instances shown, with how many instances list it (**Instances**, a link to its rows per instance; an N/A row counts) and how many
  failed at their last run (**Failing Instances**), and the worst status of its instances but N/A.
- **Status**: Critical, Warning, N/A, OK - each can be turned off.
- **Failed** and **Import Failed** open the errors of the hours they count (from the hour that holds the start to the
  end of the hour that holds the end, up to now), both kinds in one list, as DBA Dash's two links do; **Errors** opens
  the errors of the range; **Last Failure** opens the list
  around the last failure (from the last success while the collection fails now, else from 10 minutes before the
  failure, to an hour after it). The list has a text filter on the message.
- The charts: **Runs** per bucket by outcome (Failed, Partial, Succeeded; Failed holds the import failures, as DBA
  Dash's does) and **Time spent collecting and importing** - collecting (the whole runs), its CPU where it was read (SQL Server) and
  importing (the writes alone).

A collection whose runs take longer than its interval is also a finding, *collection runs long*, on the Collector page
and the Summary, and it can be sent: [alerts.md](alerts.md#pgvigils-own-health).

**Failed** counts the runs that failed but for those under **Import Failed**, the runs whose write of collected rows
into the repository failed. Failed % is over both, as the status rule counts them. **Avg Import** and **Max Import** are
the time of the writes into the repository alone, over the runs that wrote into it or tried to (a failed write too);
Avg Duration and Max Duration are the whole run and include them. **Avg CPU**, **Max CPU**, **Total CPU**, **Avg Logical
Reads** and **Total Logical Reads** (DBA Dash's order and words) are the run's own session's on SQL Server (`cpu_time` and `logical_reads` of `sys.dm_exec_sessions`,
read at the run's end, over the runs that read them); a PostgreSQL row says *not read by pgvigil*. A run cut by its own
timeout is not read: the SQL Server driver drops the connection of a statement that hit its deadline, so the five CPU and
logical reads columns leave such runs out. **Import Failed** is DBA Dash's: the runs whose write of collected rows failed. The collector's
error log calls a wider set of failures stage *Import* - any failure on the repository's side, a cursor read or a
thresholds store among them - which Collection Health counts as plain failures.

What DBA Dash shows and pgvigil does not, as pgvigil has no source for it: Warnings, Retried, No Status, the import's
own CPU and reads (and the Cost chart's Import CPU line), the highest logical reads of one run, the Import Lag chart (pgvigil writes into the repository
inside the run that collected: no queue stands between the two, so there is no import lag), the insights card, and the
Steps picker (pgvigil's collections have no steps). Runs and Max Duration are not links (DBA Dash's Collection
Performance report is a later task), and the thresholds are DBA Dash's defaults until a threshold row sets them (below). The Status column
shows the word as well as the colour.

A departure from DBA Dash: a collection written in parts (the schema collection's databases, the Extended Events and
audit readers' batches) whose part the repository refused while the run went on is counted **partial**, not import
failed. DBA Dash counts any failed import as Import Failed; pgvigil counts a run by how it ended, so its failure rate
and its failures in a row judge the same outcome. The refused part is on the collector's error log as a Warning at
stage Import.

## Retention

The hourly totals are kept 8 days by default, up to 30:

```sql
UPDATE pgvigil.hours_retention SET days = 30, changed_at = now() WHERE table_name = 'collection_health_hour';
```

or `pgvigil purge -hours collection_health_hour=30`. More than 30 is refused.

## Thresholds

DBA Dash's per-collection thresholds: failures in a row and minutes failing for a warning and a critical, the failed
per cent of the rate for each, the runs the rate needs, and Don't monitor. A row is set for one instance's collection,
every collection of one instance, one collection on every instance, or everything; each number left empty inherits the
next level up - this instance and collection, this instance, this collection on every instance, everything, then DBA
Dash's defaults (in a row 1 / 3, failing 10 / 30 minutes, failed 10 / 50 % of 5 runs or more). Don't monitor makes the
collection N/A ('not monitored'); a level's 'monitor' over a wider Don't monitor judges it again. The Thresholds cell
says where a row's numbers come from, and its title the numbers. Any signed-in user sets them (POST
/api/collectionhealth/thresholds), each change kept with who and when; the demo's door sets them on one demo instance
only.

