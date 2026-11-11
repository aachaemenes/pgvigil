# Configuration: best practice (PostgreSQL)

The Configuration page of a PostgreSQL instance opens with a **Best practice** grid: one row for every setting a
rule covers (41 settings, 35 rules), the worst first. The colour sits on the value in use:

| colour | verdict | meaning |
|---|---|---|
| green | meets the rule | every rule of the setting that applies to this instance is met |
| yellow | deviates: warning / deviates: advice | a warning rule or an advice rule is broken |
| red | deviates: critical | a critical rule is broken (autovacuum off, track_counts off, zero_damaged_pages on) |
| grey | not for this platform | no rule of the setting is meant for this instance |

Columns: the setting; the value in use, marked `(default)` when nothing sets it; the value a broken rule suggests
(empty on a met rule); the verdict in words; what the rule guards against; where the rule applies.

- Values are `pg_settings.setting`: in the setting's base unit (ms, s, kB, MB, 8 kB pages), the unit the rules
  compare in.
- A rule applies by platform (`all`, `self-managed` = on-premises, `managed` = any cloud platform, `not aurora`,
  `replica`) and by version: `default_toast_compression` and `idle_session_timeout` arrived in PostgreSQL 14 and are
  grey on 13.
- A setting with two rules (`autovacuum_freeze_max_age`, the two `max_standby_*_delay`) shows the worst broken one.
- The rules are pg_gather's parameter recommendations and pgvigil's own; every broken rule is also a finding, with
  the same severity, on the Findings page and in the alerts.
- In the **Settings** grid below, a setting a rule covers carries the same colour on its value and the verdict in
  the `best practice` column; the Excel export carries both.

The grid needs repository migration 0099 (`pgvigil migrate`). A server whose repository is not migrated yet shows the
Settings grid alone.

Not there yet: a fleet pivot of the settings, database-level options and per-database or per-role overrides in the
same colours; the SQL Server Configuration page has no rule set yet.

Proof: `scripts/proof-pg-bestpractice.sh`.
