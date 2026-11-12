# Removing pgvigil

`pgvigil uninstall -all` removes everything of pgvigil on the host it runs on; with `-drop-repository` it also drops
the repository database and the pgvigil roles. `-dry-run` lists every item first and changes nothing. A monitored
server is never touched: the monitoring logins there stay until their DBA drops them.

## Everything, in one command

Linux, as root:

```sh
pgvigil uninstall -all -dry-run                       # every item: remove, absent, or kept and why; nothing changes
pgvigil uninstall -all                                # this host; the repository database is kept and named
pgvigil uninstall -all -drop-repository -owner-dsn-file /root/pgvigil-owner.dsn
                                                      # also the repository: type its name when asked
```

Windows, from an elevated PowerShell:

```powershell
& "$env:ProgramFiles\pgvigil\pgvigil.exe" uninstall -all -dry-run
& "$env:ProgramFiles\pgvigil\pgvigil.exe" uninstall -all -drop-repository -owner-dsn-file C:\secure\pgvigil-owner.dsn
```

A run without a terminal (a script, a configuration tool) names the database instead of typing it:
`-confirm-database pgvigil`. Any other name, or neither, refuses with nothing changed.

### The order

1. Every refusal before any change: not root (not elevated); a `-bin`, `-config` or `-user` that disagrees with the
   installed service; with `-drop-repository`, the owner's connection string missing, naming a database without the
   pgvigil schema, or naming another database than the one this host's configuration names (the same name, and the same
   database on the same server, read through both logins); a login that may not drop the database or the roles (from
   PostgreSQL 16, `DROP ROLE` needs ADMIN OPTION on each role as well as CREATEROLE: a role a superuser made gives the
   owner none, and the refusal prints the `GRANT ... WITH ADMIN OPTION` that fixes it); pg_dump older than the server;
   no room for the dump.
2. The database's name, typed (or `-confirm-database`).
3. The service is stopped.
4. With `-drop-repository`: the repository is watched for 75 seconds (`collection_dates`' newest snapshot read at the
   stop and again after): a collector on another host writes within a minute, and its write refuses the drop. Any other
   session on the database (a `pgvigil serve`, Grafana, a psql; every backend but an autovacuum worker, which
   `DROP DATABASE` ends by itself) refuses it too; the drop never forces a session off. A refusal here, or Ctrl-C during the watch, starts the service again: the host is as it was.
5. The dump (`pg_dump --format=custom`, 0600, to `/var/backups/pgvigil` or `%ProgramData%\pgvigil-backups` by default;
   `-dump <file>` names it, `-no-dump` takes none). A failed dump starts the service again.
6. `DROP DATABASE`, run from the server's maintenance database (`postgres`, else `template1`), then the roles, one
   `DROP ROLE` each (below).
7. Windows: the app machine-wide (`pgvigil-app.exe` and its old copies in `%ProgramFiles%\pgvigil`,
   `%ProgramData%\pgvigil\app`), then this user's (`%LOCALAPPDATA%\pgvigil`: this user's running app and the serve it
   started are ended first, and a file still locked goes at the next restart); start at login (the `Run` value
   `pgvigil` under HKLM and HKCU); the Programs and Features entries; the policy keys
   (`HKLM\Software\Policies\pgvigil`) and this user's settings (`HKCU\Software\pgvigil`); the machine PATH entry
   `install.ps1` added.
8. The service definition (Linux: the unit, disabled, `daemon-reload`; Windows: the service, with its virtual account
   `NT SERVICE\pgvigil`).
9. The binary, its `.previous` copy, the configuration, the environment file (`repo.dsn` on Windows), the logs and the
   configuration folder.
10. Linux: the service account, last.

A step that fails stops the run and names what is left; the same command runs again from there (the configuration
stays until the repository is dropped, so a second run finds the same database). Two exceptions, both said in the
message: a dump named with `-dump <file>` is kept when the drop is refused after it, so a re-run names another file or
leaves `-dump` out; and an install at other paths than the defaults, once its service definition is gone, is found
again only with the same `-bin`, `-config` and `-user`.

### The roles

Roles belong to the server (the cluster), not to the database, so a role goes only when nothing else holds it:

- The groups `pgvigil_collector`, `pgvigil_reader`, `pgvigil_auth` and `pgvigil_alerter` are dropped, except one that
  another database records (`pg_shdepend`: another pgvigil repository on the same server, a grant elsewhere), one that
  is a member of a role outside pgvigil, a superuser, or the role the uninstall connects as. Each one kept is named.
- A login is dropped only when it is the one this host's configuration names (`PGVIGIL_REPO_DSN` in
  `/etc/pgvigil/pgvigil.env`, `repo.dsn` on Windows), every pgvigil group it is in is dropped, nothing in another
  database records it and it has no session there. Every other member of the groups (the UI's login, a Grafana login,
  another host's collector) is listed with its `DROP ROLE` line for its owner to run.

### What stays

Named on every run, never removed:

- The dumps (`/var/backups/pgvigil`, `%ProgramData%\pgvigil-backups`): yours to keep or delete.
- Linux: a service account the install did not create. `pgvigil install` marks the account it creates (its comment is
  `created by pgvigil install`); an account that was there before, or one made by an earlier release, is kept with its
  `userdel` line. A marked account with a process still running as it is kept too.
- Linux: an operator's drop-in folder `/etc/systemd/system/pgvigil.service.d`, a configuration folder (or, on
  Windows, a binary folder) that holds files the installer did not write, and the account's group when another account
  is a member of it.
- Windows: another user's own app (`C:\Users\<name>\AppData\Local\pgvigil`): its keys live in that user's registry
  hive, so that user runs `pgvigil-app.exe uninstall -user`.
- Windows: a file in use (the running `pgvigil.exe` itself, an app another session runs) goes at the next restart; a
  service another program still holds a handle to (services.msc) is marked for deletion and goes when that closes.
- The monitored servers' logins (`pgvigil_monitor`, `pgvigil_actions`, `pgvigil_explain`, as `pgvigil roles` printed
  them): drop them on each server.

A second run finds every item absent and ends `nothing of pgvigil is left to remove`, exit 0.

## The service only

```sh
pgvigil uninstall            # the service: stopped, disabled, the unit removed; the binary and /etc/pgvigil kept
pgvigil uninstall -purge     # also the installer's files in /etc/pgvigil (the folder when nothing else is left) and the binary
```

```powershell
pgvigil.exe uninstall          # the service pgvigil: stopped and deleted; %ProgramFiles%\pgvigil and %ProgramData%\pgvigil kept
pgvigil.exe uninstall -purge   # also the installer's files in %ProgramData%\pgvigil and the binary
pgvigil-app.exe uninstall      # the machine-wide app: its files, start-at-login, the Programs and Features entry
pgvigil-app.exe uninstall -user   # a user's own app (as that user)
```

These leave the account, the repository and its roles, the dumps, `pgvigil.previous`, and on Windows the PATH entry
and the policy key; `-all` takes them.

Not seen on Windows by this project's proofs yet: the Windows steps are checked by unit tests and a Windows build of
the code only.
