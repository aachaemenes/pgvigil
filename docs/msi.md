# The Windows installer (MSI)

On Windows the MSI installs the collector per machine, from an elevated prompt: `pgvigil-<version>-x64.msi`. It is
built and proven by CI and is **not yet a release asset**: no release publishes it and the release's `SHA256SUMS` does
not list it; `install.ps1` stays the release's way on Windows until a release job builds the MSI from the release's
own binary and adds its checksum line.

```
msiexec /i pgvigil-0.4.0-x64.msi /norestart          install, or upgrade an older version in place
msiexec /i pgvigil-0.4.0-x64.msi /qn /norestart      the same, silent
msiexec /x pgvigil-0.4.0-x64.msi /norestart          remove
```

`/norestart` keeps a silent run from restarting the machine if a file is still in use.

**What it does.** The package places one file, `pgvigil.exe`, under `%ProgramFiles%\pgvigil`, adds that folder to the
machine PATH (its own entry, removed with the package), and then runs `pgvigil install -no-start` from it - the same
step `install.ps1` runs. That command, not the MSI, makes the service `pgvigil` under its virtual account, secures
`%ProgramData%\pgvigil` and writes the configuration file there. The package then tries to start the service; a
start that fails (no repository named yet, a repository behind this binary) does not fail the install. After a
fresh install: write the repository's connection string into `%ProgramData%\pgvigil\repo.dsn`, then
`Start-Service pgvigil` (or restart the machine), and `pgvigil check` (docs/check.md) says whether the install is
whole. In a shell opened before the install, the program is `"%ProgramFiles%\pgvigil\pgvigil.exe"`.

The output of `pgvigil install` under the MSI is not kept anywhere, `/l*v` included: a failed install shows only
that the action returned an error. Its reason is found by running `"%ProgramFiles%\pgvigil\pgvigil.exe" install
-no-start` from an elevated prompt, which says it.

**Upgrades.** The repository is not migrated by the MSI, and a new binary over a repository behind it stops at
once, so the order is: fetch the new binary alone (`install.ps1` with `$env:PGVIGIL_NO_SERVICE = '1'`), take the dump
and run its `pgvigil migrate` as the repository owner (docs/upgrade.md), then `msiexec /i` the new MSI and
`Start-Service pgvigil`. The MSI stops the service, replaces the file and runs `pgvigil install -no-start` again;
the configuration is kept. Run the other way round - the MSI first - the upgrade still completes and the service
stays stopped until the owner migrates and starts it. A failed upgrade rolls back to the version that was there. An
older MSI over a newer install is refused; the way back is docs/upgrade.md's MSI paragraph.

**Removal.** `msiexec /x` (or Apps > Installed apps) removes the service and the program through `pgvigil
uninstall`: this host is retired as a collector, and the repository's data stays. The configuration and everything
under `%ProgramData%\pgvigil` stay too. For the rest (docs/uninstall.md), copy `pgvigil.exe` out of
`%ProgramFiles%\pgvigil` first, run `msiexec /x`, then the copy's `uninstall -all` - never `uninstall -all` before
the removal, which would delete the MSI's own file behind Windows Installer's back.

**One owner per machine.** A machine installed from the MSI is upgraded and removed with `msiexec` only:
`install.ps1` refuses it and says so (two installers over one service would each undo the other's files), except to
download a binary with `$env:PGVIGIL_NO_SERVICE = '1'`. The MSI refuses a fresh install on a machine whose service
`install.ps1` or `pgvigil install` made: run `pgvigil uninstall` there first.

**Unsigned for now.** The package is unsigned until pgvigil has a code-signing certificate, so Windows SmartScreen
warns before it runs ("Windows protected your PC" > More info > Run anyway) and a policy that requires signed
installers refuses it. Once the MSI is a release asset, verify the download against the release's `SHA256SUMS`;
the release notes will say when the package is signed.

**No operator group** - a named difference from PerformanceMonitor's installer, which offers a Windows group for its
operators. pgvigil's access is one model: roles in its own store, granted to its own users. A Windows group that
opened the collector's files or its service would be a second door beside that model, so the MSI makes none.

**How it is built.** `packaging/msi/pgvigil.wxs`, built by WiX 5.0.2 (pinned; MS-RL, a build tool only - nothing of
WiX ships inside the package, and no custom-action DLL: its four actions run `pgvigil.exe` (install, uninstall) and
`net.exe` (start, stop)) on a Windows runner, with Windows Installer's ICE validation inside the build. The CI job
`msi` builds it from the tree on each push or pull request that touches the collector or the package, and proves a
silent install, an upgrade over a configured host whose service stops at once, a refused downgrade and an uninstall
that keeps the configuration.
