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
| N/A | the collection is off for the instance, it only skipped, or its thresholds set Don't monitor |
| OK | otherwise |

A partial run counts as a success for the failures in a row and for Last Success, and as a problem in the warning
rate. A skip is not a run, but a skip after failures ends the failures in a row. A run that could not connect, or
that connected and failed before pgvigil read the server's version, is a failed run. A collection failing now is
listed even when the range holds none of its runs, while its last run is within three of its intervals (a day at
least). An instance that is not active is not listed. The failures in a row are always now's; the rates are over
the picked range. **Failed % 24hrs** is the rate the Summary judges (24 hours from the next whole hour, or from the
acknowledgement below if that is later).

The collector backs off a down server: after 3 failed connects of an instance in a row, no collection of it connects
again for a minute from the last attempt, doubling each further failure up to 15 minutes, then one probe at a time -
the held runs are skips, not failures, a refused login never counts (the server answered), and the Collector page's
Failing now panel says *backing off: n connects failed in a row since t; next try about t*. Every run also has a
deadline of twice its interval (at least 2 and at most 30 minutes; the first run after a start gets 30): a run past
it is cancelled and counted failed as *timed out after d*, and the next tick starts fresh.

### Acknowledged errors

An instance's collector errors are acknowledged on the **Collector errors** page (Acknowledge, per instance or every
instance in view, offered with no filter set and a range of 24 hours or more ending now; Unacknowledge takes it back).
As DBA Dash's Acknowledge Errors, it changes the Summary and Failed % 24hrs only:

- The Summary's Collection Health cell counts a collection's failures in a row again once a failure newer than the
  acknowledgement comes, and then all of them (3 failures, an acknowledgement, one more failure: 4 in a row). Newer
  means a failed run logged after the acknowledgement's newest error, in the order the repository logged them: a run
  that started earlier but was logged later counts. When the newest failure's log row has been purged (after 30 days),
  its time is compared with the acknowledgement's instead.
- The Summary's rate, and **Failed % 24hrs** on this page, count the hours from the acknowledgement's next whole hour (its
  own hour when it is made on the hour; 24 hours at most), so the runs earlier in the hour it was made in are not counted.
- This page keeps its Status, Failures In A Row, Runs and Failed as they are. A row whose failures in a row the Summary
  leaves out says `acknowledged at <time> by <user>: n in a row before it` in its Status Reason.
- An acknowledged collection with no run since is OK on the Summary, never N/A; Don't monitor still makes it N/A.
- The 'collection failing' alert, the Instances list, the instance header and the Collector page do not change: the
  alert has its own acknowledgement on the Alerts page.

DBA Dash's acknowledgement covers every instance at once; pgvigil's is per instance (the page writes one per instance
when every instance in view is acknowledged).

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
Steps picker (pgvigil's collections have no steps). Collection, Runs, Avg and Max Duration, Avg and Total CPU and
Avg Import open the Collection Performance report (below), and the thresholds are DBA Dash's defaults until a threshold row sets them (below). The Status column
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

The error list (Failed, Import Failed, Errors and Last Failure open it) links to the same errors on the Collector
errors page - its failed runs (type Error) by stage, a row per error, with the list's instance, collection and window
(B6g-5; pgvigil keeps one error list, as DBA Dash's ErrorLog). Acknowledge Errors is on that page with no filter and a
range of 24 hours or more ending now; it lists an inactive instance's errors too, which this list leaves out.

## Thresholds

DBA Dash's per-collection thresholds: failures in a row and minutes failing for a warning and a critical, the failed
per cent of the rate for each, the runs the rate needs, and Don't monitor. A row is set for one instance's collection,
every collection of one instance, one collection on every instance, or everything; each number left empty inherits the
next level up - this instance and collection, this instance, this collection on every instance, everything, then DBA
Dash's defaults (in a row 1 / 3, failing 10 / 30 minutes, failed 10 / 50 % of 5 runs or more). Don't monitor makes the
collection N/A ('not monitored'); a level's 'monitor' over a wider Don't monitor judges it again. The Thresholds cell
says where a row's numbers come from, and its title the numbers; a row per collection whose instances differ says
'each instance its own'. Any signed-in user sets them (POST /api/collectionhealth/thresholds), each change kept with
who and when - an admin's write once the role gate (B24f) lands; the demo's door sets them on one demo instance only.
The ranges are DBA Dash's: 1 to 100,000 failures in a row and runs, 0 to 1,000,000 minutes, 0 to 100 % to two places;
a 0 % rate means any failure (a rate is judged only with a failure to count, as DBA Dash judges it).

Don't monitor reaches further than the page: the collection raises no 'collection failing' finding (an alert already open for
it is then the sender's as any finding that stopped standing) and the overview's daily check of the same name leaves it out. The Instances list's
failing collections, an instance's header and the Collector page's streaks still show its failures.

The Thresholds cell opens DBA Dash's Collection Health Thresholds dialog for its row: Apply to picks the level (a row
per collection over the instances offers the two without an instance), each setting is ticked to set it at that level
or left unticked to inherit it, with 'Inherited: n' and the level it comes from beside it. Save writes the ticked
values (nothing ticked ends the level's own row: the level above applies), Inherit All unticks every value, Close
reads the page again after a save. Where the write cannot be made (a server that writes nothing; on the demo an
instance that is not the demo's, or a level over every instance) the dialog still shows the values, Save off with the
reason in words. A refused value comes back in the repository's own words. One difference from DBA Dash: the rate's
range is the page's (the Summary's last 24 hours), as pgvigil has no Acknowledge Errors yet.


## Collection Performance

DBA Dash's Collection Performance report, opened from the Collection Health grid: Collection, Runs, Avg and Max
Duration, Avg and Total CPU and Avg Import open it for the row's collection - on its instance for a row per
collection per instance, over the page's scope for a row per collection - over the range the grid was read with (GET /api/collectionperf).

Its charts, two by two, are hourly: Duration (ms) - collecting and importing, average and highest; CPU (ms) - collecting
(SQL Server's runs that read their session); Logical Reads; Runs by outcome. Its grid lists the newest first, 5,000 rows
at most (said when the range holds more):

- an **Hour** row per instance, collection and hour - every run of the hour, summed over the collectors that ran it;
- a **Run** row per run that failed or was partial, with its duration. pgvigil keeps only those one by one (a run that
  went well is counted in its hour), so the Run rows are never all the runs; a Run row's CPU, logical reads and import
  say 'hourly only'.

Failed holds the failures at the write too (DBA Dash's Failed and Import Failed together; a Run row says Failed and its
Stage in the Collector errors page's words - Import Failed is counted by the hour, as the log calls every
repository-side failure Import); Partial is DBA Dash's
'Retried / Partial' (pgvigil retries nothing). Import CPU, Import Logical Reads and Import Lag are not read: pgvigil
writes into the repository inside the run that collected. The hourly rows are kept 8 days by default (30 at most,
Data retention): a range that starts before them says where the report's hours start.
