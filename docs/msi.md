# The Windows installer (MSI)

On Windows the MSI is the first way to install the collector: `pgvigil-<version>-x64.msi` from the release, per
machine, from an elevated prompt.

```
msiexec /i pgvigil-0.4.0-x64.msi            install, or upgrade an older version in place
msiexec /i pgvigil-0.4.0-x64.msi /qn        the same, silent
msiexec /x pgvigil-0.4.0-x64.msi            remove
```

**What it does.** The package places one file, `pgvigil.exe`, under `%ProgramFiles%\pgvigil`, and then runs
`pgvigil install` from it - the same step `install.ps1` runs. That command, not the MSI, makes the service `pgvigil`
under its virtual account, secures `%ProgramData%\pgvigil` and writes the configuration file there; the service starts
once the configuration names the repository. `pgvigil check` (docs/check.md) says whether the install is whole.

**Upgrades and the way back.** A newer MSI replaces an older one in place: the service is stopped, the file replaced,
`pgvigil install` run again; the configuration is kept. The repository is not migrated by the MSI - `pgvigil check`
warns when it is behind, and `pgvigil migrate` (or `pgvigil install -upgrade`, which also takes the dump first:
docs/upgrade.md) brings it level. An older MSI over a newer install is refused; docs/upgrade.md holds the way back.

**Removal.** `msiexec /x` (or Apps > Installed apps) removes the service and the program through
`pgvigil uninstall`. The configuration and everything under `%ProgramData%\pgvigil` stay, and the repository is never
touched; `pgvigil uninstall -all` (docs/uninstall.md) is the command for the rest, run before the removal.

**One owner per machine.** A machine installed from the MSI is upgraded and removed with `msiexec` only:
`install.ps1` refuses it and says so (two installers over one service would each undo the other's files).

**Unsigned for now.** The package is unsigned until pgvigil has a code-signing certificate, so Windows SmartScreen
warns before it runs ("Windows protected your PC" > More info > Run anyway) and a policy that requires signed
installers refuses it. Verify the download against the release's `SHA256SUMS` instead. The release notes will say
when the package is signed.

**No operator group** - a named difference from PerformanceMonitor's installer, which offers a Windows group for its
operators. pgvigil's access is one model: roles in its own store, granted to its own users. A Windows group that
opened the collector's files or its service would be a second door beside that model, so the MSI makes none.

**How it is built.** `packaging/msi/pgvigil.wxs`, built by WiX 5.0.2 (pinned; MS-RL, a build tool only - nothing of
WiX ships inside the package, and no custom-action DLL: the two actions run `pgvigil.exe` and `net.exe`) on a Windows
runner from the release's own `pgvigil.exe`, with Windows Installer's ICE validation inside the build. The CI job
`msi` proves a silent install, an upgrade, a refused downgrade and an uninstall on each change.
