# The Windows app: pgvigil in its own window

`pgvigil-app.exe` is a small Windows program that shows the pgvigil UI in its own window (Microsoft Edge WebView2), with a tray icon. It starts the UI server (`pgvigil serve`) on loopback as the signed-in user, or attaches to one that already runs, and stops the serve it started when it quits. Nothing in pgvigil needs it: `pgvigil serve -open` (no install; proven on Linux by `scripts/proof-open.sh`, not proven on Windows or macOS) opens the UI in an app-mode browser window, and a browser on the UI's address works as before.

There are two ways to install it:

| | Machine-wide (administrator) | Per user (standard user) |
|---|---|---|
| Who | an administrator, once per machine | any user, for themselves |
| Where | `%ProgramFiles%\pgvigil` (pgvigil.exe and pgvigil-app.exe) | `%LOCALAPPDATA%\pgvigil` (the same two files) |
| The collector | the Windows service `pgvigil` under its virtual account `NT SERVICE\pgvigil` (`pgvigil install`) | none |
| The UI configuration | `%ProgramData%\pgvigil\app\pgvigil.yaml`, readable by the machine's users | `%LOCALAPPDATA%\pgvigil\pgvigil.yaml`, the user's own |
| Start at login | for every user (HKLM `Run`) | for the user (HKCU `Run`) |
| Update check | on, or off for every user (`-no-update-check`, the policy below) | on, or off for the user |
| Needs | an elevated prompt | the WebView2 Evergreen runtime already on the machine (Windows 11 and current Windows 10 have it) |
| Writes | under Program Files, ProgramData (the collector's folder and the app's UI configuration) and HKLM | under `%LOCALAPPDATA%` and HKCU only |

The release carries `pgvigil-app_<tag>_windows_amd64.zip` (pgvigil-app.exe and pgvigil.exe), listed in the release's `SHA256SUMS` and covered by its keyless Sigstore signature like every other asset. Verify it as [docs/airgap.md](airgap.md) shows, then unpack it.

## Installing

pgvigil-app.exe is a windowed program, so Windows PowerShell does not wait for it. Run its commands through `Start-Process -Wait`, or from `cmd.exe`, to see the output and the exit code.

Machine-wide, in an elevated PowerShell in the unpacked folder:

```powershell
Start-Process .\pgvigil-app.exe -ArgumentList install -Wait -NoNewWindow                      # update check on
Start-Process .\pgvigil-app.exe -ArgumentList install,-no-update-check -Wait -NoNewWindow      # update check off for every user
```

This runs `pgvigil install` (the collector service, as on any Windows host: see the README), copies the app beside it, writes `%ProgramData%\pgvigil\app\pgvigil.yaml` when there is none (SYSTEM and Administrators may change that folder; Users may read it), sets the start-at-login entry for every user (leave it out with `-no-autostart`), writes the policy value `UpdateCheck`, and adds pgvigil to Programs and Features. Then put the UI's repository login in `%ProgramData%\pgvigil\app\pgvigil.yaml` and the collector's in `%ProgramData%\pgvigil\repo.dsn`.

Per user, in an ordinary PowerShell:

```powershell
Start-Process .\pgvigil-app.exe -ArgumentList install,-user -Wait -NoNewWindow
```

This copies both files to `%LOCALAPPDATA%\pgvigil`, writes a template `pgvigil.yaml` there, sets the user's start-at-login entry (or not, with `-no-autostart`) and adds the user's Programs and Features entry. Nothing is written outside `%LOCALAPPDATA%` and HKCU. A machine without the WebView2 runtime is refused: installing the runtime needs an administrator, so on such a machine use `pgvigil serve -open`. The zip can also be unpacked into `%LOCALAPPDATA%\pgvigil` by hand and the app started from there; `install -user` only adds the entries.

Neither tier adds a Start menu shortcut: the app starts at login and lives in the tray, and pgvigil-app.exe can be pinned like any program.

## The UI configuration and its login

The serve the app starts reads a configuration with the repository login the UI reads with, IN ROLE `pgvigil_reader, pgvigil_auth` (the UI's login from `pgvigil roles`) and no instances:

```yaml
repository:
  dsn: "host=repo.example.internal port=5432 dbname=pgvigil user=pgvigil_ui sslmode=verify-full"
instances: []
```

The app looks for it in this order: `-config <file>`, the user's `%LOCALAPPDATA%\pgvigil\pgvigil.yaml`, then the machine's `%ProgramData%\pgvigil\app\pgvigil.yaml`. On a machine-wide install every user can read the machine's file, so keep the password out of it. Each user can put it in their own `%APPDATA%\postgresql\pgpass.conf`, or a user can have their own configuration in `%LOCALAPPDATA%`. pgvigil's UI login (the `pgvigil user` accounts) is on by default, and the window shows its sign-in page. A user may turn it off for their own serve (HKCU `NoLogin` = 1, below), which `serve` allows on loopback only. An administrator can forbid that with the policy `RequireLogin` = 1.

## What the app does

- **Start.** One app runs per user session; a second launch shows the running one's window (a start-at-login launch does not). Unless a serve already answers at the attach address (default `http://127.0.0.1:8080/`, loopback only) and runs as the same Windows user, the app runs `pgvigil serve -config <the configuration> -listen 127.0.0.1:0`. That serve picks a free port, runs with no console window, and sits in a Windows job object, so it ends with the app even if the app crashes. With `-tray` (the start-at-login entry) the window stays closed until the tray icon is clicked.
- **The window.** It shows the UI. Its size, or the fact that it was maximized, is kept per user (HKCU `Width`, `Height`, `Maximized`) for the next start. Closing the window hides it; the app and its serve keep running in the tray.
- **The tray menu.** Open pgvigil; Open in the browser; Start at login (the user's own entry: shown checked and greyed when the administrator set it for every user); the update notice, when there is one; Quit.
- **Quit** (the tray menu, or `pgvigil-app -quit`). The app stops the serve it started; a serve it attached to keeps running.
- **No WebView2.** If the runtime is missing or cannot start, the app says so and opens the UI in the default browser.
- **Shared hosts.** The app attaches only to a serve whose process runs as the same Windows user, so on a Remote Desktop host or a jump box it never shows another user's serve, or a process that only answers like one. A serve started with `-no-login` (HKCU `NoLogin`) is still reachable by every user of the machine on its loopback port; keep the UI login on where several people sign in.
- **Its log.** `%LOCALAPPDATA%\pgvigil\app.log` holds the app's lines and the serve's. WebView2 keeps its data in `%LOCALAPPDATA%\pgvigil\WebView2`.

## The update check

The update check is the only outbound call pgvigil's own code makes in the app. Once a day, 30 seconds after the start, the app reads the release feed: `https://api.github.com/repos/aachaemenes/pgvigil/releases/latest`, or a mirror. It sends one GET with the header `User-Agent: pgvigil-app/<version>` and nothing else: no machine name, user or install id. When the feed's release is newer than the app, the tray shows a notice and the menu offers to open the release page. Nothing is downloaded or installed by the app. Development builds never show a notice.

The administrator decides with the policy key `HKLM\Software\Policies\pgvigil\App` (the installer writes it, and Group Policy Preferences or any registry tool can too):

| Value | Type | Meaning |
|---|---|---|
| `UpdateCheck` | DWORD | 0 = no update check for any user on this machine; 1 = on (a user may still turn it off for themselves) |
| `UpdateFeed` | string | another feed of the same JSON shape (`tag_name`, `html_url`), such as an internal mirror; https, or http to loopback |
| `AttachURL` | string | the loopback address of a serve to attach to |
| `RequireLogin` | DWORD | 1 = the app always starts its serve with the UI login (a user's `NoLogin` is ignored) |

A user's own choices sit in `HKCU\Software\pgvigil\App`: `UpdateCheck` (0 = off), `AttachURL`, `NoLogin`, the window's `Width`, `Height` and `Maximized`, and `LastUpdateCheck`. A per-user install with `-no-update-check` writes `UpdateCheck` = 0 there.

An air-gapped or government site sets `UpdateCheck` = 0, or points `UpdateFeed` at a mirror on the inside. With the check off, pgvigil's code in the app connects to nothing but loopback (its own serve), and the serve to nothing but the repository (the app's side proven by `scripts/proof-app.ps1` B2; the serve's side not proven: no proof captures its connections). The WebView2 runtime that draws the window is Microsoft's and has network behaviour of its own: SmartScreen checks of the pages it shows, and its own updates through Edge Update. A site governs those with Microsoft's Edge, WebView2 and Edge Update group policies, as for any WebView2 program. The pages the window shows are pgvigil's own, served on loopback.

The GitHub API answers 60 unauthenticated requests an hour per address. A large site behind one address can get "status 403" in `app.log` instead of a notice. A mirror (`UpdateFeed`) avoids that.

## Checking an install

`pgvigil-app -check` does everything but the window. It names the configuration it found and the WebView2 runtime's version, attaches to or starts the serve, reads `/` and `/api/health`, runs the update check (or says why it is off), and stops the serve it started:

```powershell
Start-Process "$env:ProgramFiles\pgvigil\pgvigil-app.exe" -ArgumentList -check -Wait -NoNewWindow
```

## Uninstalling

```powershell
Start-Process "$env:ProgramFiles\pgvigil\pgvigil-app.exe" -ArgumentList uninstall -Wait -NoNewWindow          # elevated: machine-wide
Start-Process "$env:LOCALAPPDATA\pgvigil\pgvigil-app.exe" -ArgumentList uninstall,-user -Wait -NoNewWindow    # per user
```

The uninstall first asks the app in its own session to quit, and waits for it and the serve it started. The machine-wide uninstall then removes the collector service (`pgvigil uninstall`), the start-at-login entry, the two programs and, last, the Programs and Features entry. If the collector's uninstall fails, nothing else is removed and the entry stays to run it again. A program file that another user's session still holds (their app, or a serve it started) is removed at the next restart, with the folder, and the uninstall says so. `-purge` also removes the UI configuration, the policy key and the collector's configuration folder. The per-user uninstall removes the user's files and entries, and with `-purge` their settings, log and WebView2 data. If a file is still in use, it says which, exits with 1 and keeps the entries, so it can be run again. The app's own file goes two seconds after it exits, because a running program cannot delete itself. The app in the uninstalling user's session quits first; an app running in another user's session keeps its window until it quits.

## Building

The app is its own Go module (`app/`), so the collector keeps no Windows UI dependency. It uses the pure-Go WebView2 binding `github.com/jchv/go-webview2` (MIT) and `golang.org/x/sys`, with no cgo and no WebView2Loader.dll beside the app (the SDK's loader is embedded in the exe and loaded from memory; the process loads DLLs by name from System32 only). It builds on any system:

```sh
cd app && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -H=windowsgui -X main.version=$TAG" -o pgvigil-app.exe .
```

The release builds it on a Windows runner, runs its tests there, and adds the zip to the assets before `SHA256SUMS` is made and signed. `scripts/proof-app.ps1` proves both tiers on a Windows machine over SSH: a standard user's refused machine install, `install -user`, `-check` and `uninstall -user`, and an administrator's install, the update policy both ways, the attach path, the window (its saved size, the screenshot, one instance, close to the tray, `-quit` stopping the serve) and `uninstall -purge`.
