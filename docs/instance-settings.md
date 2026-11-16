# Settings (Admin > Instances)

An instance added in Admin > Instances has its own **Settings**, as an instance of `pgvigil.yaml` has its own
`schedules:`, `disabled:` and `query_text:` lines: each collection's interval, or off, and the statement text the
repository keeps for it. **Settings** on the instance's row opens them below the table.

- **An interval** is written `5m`, `1h`, `2d` or `90s` (a bare number is minutes), from a minute to 30 days; `off`
  stops the collection on this instance; an empty box keeps the default, shown beside it. The minute is the same floor
  as the tree's Configure Schedule; `pgvigil.yaml`'s own values are not held to it.
- **The default** is what the instance runs without a value of its own: `pgvigil.yaml`'s global `schedules:` where it
  names the collection (the page says so, with the collection's own interval beside it), else the collection's own.
- **The order**, as in the file: off, then the instance's own interval, then the file's global `schedules:`, then the
  running plans box, then the collection's default. So an interval set here runs the collection on this instance
  even where the file's global `schedules:` sets it to 0.
- **Opt-in collections** (amcheck: it reads every page of what it checks) run only where an interval is set; the page
  says so.
- **Not set here:** `mssql_running_plans`, which the running plans box on the row controls; and a collection that never
  runs on an instance added in the page, because it needs a block of `pgvigil.yaml` the page does not have (an `aws:`
  block, a `pgbouncer:` DSN): the page names why.
- **Statement text kept** (`query_text`): `full`, `normalized` or `none` for this instance, or the file's.
  It holds for what the collector stores and for what the pages show of it, whether or not the instance's read
  door is open on this server.

The collector takes a change within 15 seconds and restarts that instance's collections alone; the other instances
run on. The stale and failing checks (Collection Dates, the Summary, the daily checks) judge the instance by its own
intervals: a collection set off is shown off, not stale. `pgvigil mcp` reads the list of Admin > Instances every 15
seconds for the same judgement (its read doors stay `pgvigil.yaml`'s).

Every save is one row in *Changes* (`instance settings`), with what was set; a refusal is one too, with its reason: a
collection of another engine or of no engine, an interval under a minute or over 30 days, the running plans box's
collection, an instance of `pgvigil.yaml` (changed in the file).

- **Thresholds** (SQL Server): the HA/DR, jobs and backups thresholds that `mssql_thresholds:` sets for an instance of
  `pgvigil.yaml` - each of the eleven numbers (0 or more), and `backup_exclude`, database name patterns (LIKE: `_` and
  `%` match any character). The collector stores a change at the instance's next HA/DR, jobs or backups read; until
  then Alerts > Rules' *Thresholds in force* shows the instance's value marked `Admin > Instances` with the words
  'waits for the next HA/DR, jobs or backups read' and the value in force now.
- **The tree's Pause/Resume Collections and Configure Schedule** save the same settings for an instance added here:
  a pause keeps the instance's own interval and Resume writes it back; a collection off for every instance by
  `pgvigil.yaml`'s global `schedules:` is shown so, and ticking it gives this instance its own interval. The running
  plans box's collection and one that never runs here are read only in both.
- Every editor sends the settings as it read them: a save over a change made meanwhile elsewhere is refused ('changed
  since they were read: read them again'), never written over unseen.
