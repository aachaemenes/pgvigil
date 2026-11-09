# pgvigil

PostgreSQL monitoring for DBAs: daily checks, performance history, running-query snapshots with blocking chains, and alerting, across on-prem PostgreSQL, Amazon RDS and Aurora, Azure Database for PostgreSQL and Google Cloud SQL / AlloyDB.

A lightweight collector (Go, one static binary) polls each instance on a schedule, reads the platform's metric and log doors, and stores everything in a PostgreSQL repository. Dashboards read the repository.

Status: design stage. Nothing to install yet.

## Licence

MIT. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
