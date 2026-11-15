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
| Warning | 1 or more failures in a row and 10 minutes or more since the last success (never succeeded: the failure alone), or 10 % or more of 5 or more runs failed or ended partial |
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
  once over the instances shown, with how many it ran on (**Instances**, a link to its rows per instance) and how many
  failed at their last run (**Failing Instances**), and the worst status of its instances but N/A.
- **Status**: Critical, Warning, N/A, OK - each can be turned off.
- **Failed** and **Errors** open the list of the errors logged for the row over the range; **Last Failure** opens it
  around the last failure (from the last success while the collection fails now, else from 10 minutes before the
  failure, to an hour after it). The list has a text filter on the message.
- The charts: **Runs** per bucket by outcome (Failed, Partial, Succeeded) and **Time spent collecting**.

What DBA Dash shows and pgvigil does not, as pgvigil has no source for it: Warnings, Retried, Import Failed, No
Status, CPU and Logical Reads per collection, the import columns and the Import Lag chart (pgvigil writes each
collection in its own run: there is no import step to lag), the insights card, and the Steps picker (pgvigil's
collections have no steps). Runs and Max Duration are not links (DBA Dash's Collection Performance report is a later
task), and the thresholds are DBA Dash's defaults, not yet settable. The Status column shows the word as well as the
colour.

## Retention

The hourly totals are kept 8 days by default, up to 30:

```sql
UPDATE pgvigil.hours_retention SET days = 30, changed_at = now() WHERE table_name = 'collection_health_hour';
```

or `pgvigil purge -hours collection_health_hour=30`. More than 30 is refused.
