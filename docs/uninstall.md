# Removing pgvigil

What each command removes, and what it leaves for the operator to remove by hand. Nothing here touches a monitored
server: the monitoring logins on those servers stay until their DBA drops them.

## Linux

As root:

```sh
pgvigil uninstall            # the service: stopped, disabled, the unit removed; the binary and /etc/pgvigil kept
pgvigil uninstall -purge     # also the installer's files in /etc/pgvigil (the folder when nothing else is left) and the binary
```

Left in place, named in the output: the service account (`userdel pgvigil` removes it), the repository database and
its roles (the repository owner drops them: `DROP DATABASE` and `DROP ROLE` for the logins `pgvigil roles` printed),
and the dumps an upgrade took (`/var/backups/pgvigil`). An upgrade's `pgvigil.previous` beside the binary goes with
`rm`. The page's credential folders beside the config, `instances/` and `sources/`, hold the passwords of the
monitored servers added in the page (0600 files): `-purge` keeps them, and the folder with them; remove them with
`rm -r /etc/pgvigil/instances /etc/pgvigil/sources` (or beside your `-config`), then `rmdir /etc/pgvigil`.

## Windows

From an elevated PowerShell:

```powershell
pgvigil.exe uninstall          # the service pgvigil: stopped and deleted; %ProgramFiles%\pgvigil and %ProgramData%\pgvigil kept
pgvigil.exe uninstall -purge   # also the installer's files in %ProgramData%\pgvigil and the binary
pgvigil-app.exe uninstall      # the machine-wide app: its files, start-at-login, the Programs and Features entry
pgvigil-app.exe uninstall -user   # a user's own app (as that user)
```

Left in place: the folder on the machine PATH (`install.ps1` added it), the policy key
`HKLM\Software\Policies\pgvigil\App`, the repository database and its roles (as on Linux), the dumps an upgrade took
(`%ProgramData%\pgvigil-backups`) and `pgvigil.previous.exe`. The page's credential folders beside the config,
`instances\` and `sources\` (the monitored servers' passwords as DPAPI blobs), are kept by `-purge` with the folder:
`Remove-Item -Recurse "$env:ProgramData\pgvigil\instances", "$env:ProgramData\pgvigil\sources"`, then
`Remove-Item "$env:ProgramData\pgvigil"`.
