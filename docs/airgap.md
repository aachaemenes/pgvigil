# Installing pgvigil on a network without Internet access

pgvigil runs where nothing may reach out. This page is the procedure for a site whose servers never see the Internet (an air-gapped or government network): what to fetch on a connected machine, how to verify it there, what to carry across, and how to install from the copy. Everything the collector and the UI do at run time is on this page too, so a review can confirm that nothing else is contacted.

## What pgvigil connects to at run time

- The PostgreSQL and SQL Server instances named in its configuration (the monitored instances), each through its own monitoring login (and its actions login where `actions_dsn` is set), and the PgBouncer admin console of an instance that names one (`pgbouncer:`).
- The repository database (one PostgreSQL database that pgvigil owns).
- On RDS and Aurora instances whose configuration has an `aws:` block: the AWS APIs for that region only (CloudWatch Logs, CloudWatch metrics, Performance Insights, RDS Describe calls, DMS Describe calls), through the AWS SDK's endpoint for the region, so `us-gov-west-1` and `us-gov-east-1` resolve to the GovCloud (US) endpoints with nothing to configure beyond the region; FIPS endpoints follow the SDK's `AWS_USE_FIPS_ENDPOINT=true` (the SDK's setting; not proven here). No `aws:` block, no AWS call.
- The browser that opens the web UI, on loopback by default (an HTTPS listen elsewhere needs a certificate and the login).
- The Windows app (`pgvigil-app.exe`), where it is installed: its own `pgvigil serve` on loopback, and, only where it is turned on, once a day the release feed (`https://api.github.com/repos/aachaemenes/pgvigil/releases/latest`, one GET with `User-Agent: pgvigil-app/<version>`, nothing else sent; it notifies, never downloads). The check is off by default: `HKLM\Software\Policies\pgvigil\App` `UpdateCheck` = 1 turns it on for every user (the machine install's `-update-check`, `install.ps1 -UpdateCheck`, writes it), a user may turn it on for themselves where no policy says 0, and `UpdateCheck` = 0 keeps it off for every user (`-no-update-check`); `UpdateFeed` points it at an internal mirror; [docs/app.md](app.md). The WebView2 runtime the window runs in is Microsoft's, with its own policies for its own traffic.
- The alert channels the configuration names, when alerts are on ([alerts.md](alerts.md): a webhook, SMTP, PagerDuty, Opsgenie).
- The DBA Dash repositories under `dbadash:` (SQL Server databases), through their read-only login ([dbadash.md](dbadash.md)).

Nothing else: no telemetry, no update check in the collector or the UI server, no download at run time, no DNS name of the project's. The installers (`install.sh`, `install.ps1`) download a release when they run online; on an air-gapped network they install from the offline bundle (below), which needs no network at all.

## The offline bundle: install and upgrade without a network

Every release carries one archive per platform with everything an install or an upgrade needs:
`pgvigil-offline-<tag>-linux-amd64.tar.gz` and `pgvigil-offline-<tag>-windows-amd64.zip`. Each extracts to one folder
of the same name holding the plain and the FIPS 140-3 binaries (Windows: and the app's zip), their SBOMs, the installer
(`install.sh`, `install.ps1`), this page, [upgrade.md](upgrade.md) and [uninstall.md](uninstall.md), `SHA256SUMS` with
its signature, certificate and Sigstore bundle, and three trust-root files written at the release. Every file in the
folder but `SHA256SUMS` and its three signature files has its line in that one signed `SHA256SUMS`. The two archives
are listed in `SHA256SUMS.offline`, which carries a keyless signature of its own (`.sig`, `.pem`, `.bundle`).

On the connected machine, verify the archive, then what is inside:

```sh
TAG=v0.4.0; OS=linux   # or windows (the .zip)
BASE=https://github.com/aachaemenes/pgvigil/releases/download/$TAG
ID="https://github.com/aachaemenes/pgvigil/.github/workflows/release.yml@refs/tags/$TAG"
for f in pgvigil-offline-$TAG-$OS-amd64.tar.gz SHA256SUMS.offline SHA256SUMS.offline.sig SHA256SUMS.offline.pem SHA256SUMS.offline.bundle; do curl -fsSLO "$BASE/$f"; done
sha256sum -c SHA256SUMS.offline --ignore-missing
cosign verify-blob --bundle SHA256SUMS.offline.bundle --certificate-identity "$ID" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS.offline
tar -xzf pgvigil-offline-$TAG-$OS-amd64.tar.gz && cd pgvigil-offline-$TAG-$OS-amd64
sha256sum -c SHA256SUMS --ignore-missing
cosign verify-blob --bundle SHA256SUMS.bundle --certificate-identity "$ID" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
```

The three trust-root files inside the folder (`fulcio.pem`, `rekor.pub`, `ctfe.pub`) are a convenience, never a proof:
whoever could swap the archive could swap them too. Write the site's own trust root with `cosign initialize` and the
lines of section 2 below, and compare: `sha256sum fulcio.pem rekor.pub ctfe.pub` in both folders must agree, or use the
site's own files from then on. Carry the folder across as the site's transfer procedure requires.

Inside the network, as root (Linux) or from an elevated PowerShell (Windows), with the folder on local disk, a mounted
USB drive or a share:

```sh
sudo sh /mnt/usb/pgvigil-offline-v0.4.0-linux-amd64/install.sh --from /mnt/usb/pgvigil-offline-v0.4.0-linux-amd64
```

```powershell
& E:\pgvigil-offline-v0.4.0-windows-amd64\install.ps1 -From E:\pgvigil-offline-v0.4.0-windows-amd64 -App
```

The installer copies the binary and `SHA256SUMS` into a new folder of root's (Administrators') alone, checks its own
bytes and the binary's against `SHA256SUMS`, and runs only the copy: a share or a drive can change between a check and
a use. That checksum proves the files are the ones `SHA256SUMS` names (integrity), not where they came from (origin):
the signature does that. Where cosign is on the host, `--trust-root <dir>` (`-TrustRoot`) names a folder with the
site's OWN three trust-root files and the installer verifies the signature of `SHA256SUMS` offline with them; the
files inside the bundle are never used for it. Without it the installer says that the signature was not verified there.

- **A fresh install** runs `pgvigil install` (Linux: the account, the hardened unit, enabled; Windows: the service under
  `NT SERVICE\pgvigil`, the folder on the machine PATH). The plain build unless `--fips` (`-Fips`).
- **An upgrade** is what the installer does on a host where the collector is installed (the unit
  `/etc/systemd/system/pgvigil.service`, the service `pgvigil`): `pgvigil install -upgrade`, in the order of
  [upgrade.md](upgrade.md), with the repository owner's connection string from `--owner-dsn-file <path>` (`sudo` drops
  environment variables). The installed build is kept, FIPS or plain, as its `pgvigil version` says; `--fips` or
  `--plain` changes it, and the installer says so.
- **The Windows app** (`-App`) is placed machine-wide beside the collector just installed, by `pgvigil-app install
  -app-only`: the app zip's own `pgvigil.exe`, the plain build, is never put over a FIPS collector. Its update check
  stays off unless `-UpdateCheck`. The app's window needs Microsoft's WebView2 runtime: on a host without Internet
  access install the WebView2 Runtime's offline (standalone) installer first, fetched on the connected side from
  Microsoft's WebView2 download page ("Evergreen Standalone Installer").

## 1. On a connected machine: fetch the release and verify it

Every release carries, beside the binaries, a `SHA256SUMS` file, its keyless Sigstore signature (`SHA256SUMS.sig` and `SHA256SUMS.pem`), the Sigstore bundle `SHA256SUMS.bundle` (the signature, the certificate and the transparency-log entry in one file, for a verification without the log online), and one CycloneDX SBOM per target (`pgvigil_<tag>_<os>_<arch>.cdx.json`).

```sh
TAG=v0.2.0   # the release
BASE=https://github.com/aachaemenes/pgvigil/releases/download/$TAG
mkdir pgvigil-$TAG && cd pgvigil-$TAG
for f in pgvigil_${TAG}_linux_amd64 pgvigil_${TAG}_linux_amd64_fips pgvigil_${TAG}_windows_amd64.exe pgvigil_${TAG}_windows_amd64_fips.exe \
         pgvigil_${TAG}_linux_amd64.cdx.json pgvigil_${TAG}_windows_amd64.cdx.json SHA256SUMS SHA256SUMS.sig SHA256SUMS.pem SHA256SUMS.bundle; do
  curl -fsSLO "$BASE/$f"
done
sha256sum -c SHA256SUMS --ignore-missing
cosign verify-blob --signature SHA256SUMS.sig --certificate SHA256SUMS.pem \
  --certificate-identity "https://github.com/aachaemenes/pgvigil/.github/workflows/release.yml@refs/tags/$TAG" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
```

The first check proves each file is the one the checksums name; the second proves the checksums file came out of this repository's release workflow for that tag (the signer is the GitHub Actions identity of `release.yml`, recorded in the public Rekor log). Take only the files the site needs: `*_fips` builds where FIPS 140-3 cryptography is required (their `pgvigil version` prints `fips140 on (module v1.0.0)`: the Go Cryptographic Module v1.0.0, CMVP certificate #5247, is the only cryptography in them), the plain builds otherwise; the SBOM of the target for the software review.

## 2. Carry the folder across

Before the copy, on the connected machine, write Sigstore's trust root out as three key files and put them in the folder (once per cosign trust root):

```sh
cosign initialize
TROOT=$(find ~/.sigstore -name trusted_root.json | head -n 1)
python3 - "$TROOT" <<'PY'
import json, sys, textwrap
d = json.load(open(sys.argv[1]))
pem = lambda raw, kind: "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (kind, "\n".join(textwrap.wrap(raw, 64)), kind)
certs = [c["rawBytes"] for ca in d["certificateAuthorities"] for c in ca["certChain"]["certificates"]]
rekor = [t for t in d["tlogs"] if t.get("baseUrl") == "https://rekor.sigstore.dev"]   # the log the release's bundle names
ct = [t for t in d["ctlogs"] if "end" not in t["publicKey"].get("validFor", {})]      # the certificate log in use
if not certs or len(rekor) != 1 or len(ct) != 1:
    sys.exit("trusted_root.json: %d certificates, %d rekor.sigstore.dev logs, %d open certificate logs (wanted 1+, 1, 1)" % (len(certs), len(rekor), len(ct)))
open("fulcio.pem", "w").write("".join(pem(c, "CERTIFICATE") for c in certs))
open("rekor.pub", "w").write(pem(rekor[0]["publicKey"]["rawBytes"], "PUBLIC KEY"))
open("ctfe.pub", "w").write(pem(ct[0]["publicKey"]["rawBytes"], "PUBLIC KEY"))
PY
```

Copy the folder as the site's transfer procedure requires. Inside the network, verify again before anything runs:

```sh
sha256sum -c SHA256SUMS --ignore-missing
SIGSTORE_ROOT_FILE=fulcio.pem SIGSTORE_REKOR_PUBLIC_KEY=rekor.pub SIGSTORE_CT_LOG_PUBLIC_KEY_FILE=ctfe.pub \
  cosign verify-blob --offline --bundle SHA256SUMS.bundle \
  --certificate-identity "https://github.com/aachaemenes/pgvigil/.github/workflows/release.yml@refs/tags/$TAG" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
```

The bundle carries the signature, the certificate and the transparency-log entry, so no connection to the log is needed. cosign still wants Sigstore's trust root: in this project's runs, cosign v2.6.1 (the version the release workflow pins) given only its cache (`~/.sigstore`, carried across) tried to refresh it from the TUF mirror even with `--offline`, and on a host with no route out that failed ("error updating to TUF remote mirror"). The three files are that trust root's own keys (Fulcio's certificates, Rekor's key, the certificate log's key, one key per file), which cosign reads through these variables instead; the python lines stop with a message when the trust root holds more than one Rekor log or more than one open certificate log, rather than pick one. `scripts/proof-upgrade.sh` part C runs this check on a network with no route out and an empty home folder: the release verifies with the three files and another tag's identity is refused; it also prints, without judging it, what the same command does without them.

## 3. Install from the copy

The offline bundle above is the way. Otherwise, either by hand: put the binary where the service account can run it, create the repository database and the roles (`pgvigil migrate`, `pgvigil roles`, the README's quick start), write the configuration, and install the service with `pgvigil install` (Linux: a hardened systemd unit, `deploy/pgvigil.service`, is written; Windows: a service under the virtual account `NT SERVICE\pgvigil`). Or through the installers from an HTTP mirror folder: `PGVIGIL_BASE_URL` points `install.sh` and `install.ps1` at any HTTP folder that holds the release's files, and `PGVIGIL_VERSION` pins the tag; the installers verify the checksum from that folder before they run anything. That checksum comes from the same folder as the binary, so it shows the copy is intact (integrity), not where it came from (origin): verify the signature when the folder is filled. The mirror path fetches the plain build only; the offline bundle carries both.

```sh
# an HTTP mirror inside the network: the release folder served as it was downloaded
PGVIGIL_VERSION=v0.2.0 PGVIGIL_BASE_URL=https://mirror.example.internal/pgvigil sh install.sh
```

## 4. What the service may do on the host

The systemd unit confines the collector: a non-root account, a read-only view of the file system (`ProtectSystem=strict`, nothing is written: logs go to the journal), no new privileges, no capabilities, no device access, the kernel's tunables, modules, logs and clock protected, `/proc` reduced to the service's own processes, no namespaces, no SUID files, no writable-and-executable memory, native system calls only through the `@system-service` allow list minus `@privileged`, and only Internet and local sockets (it must reach the servers and the repository). `systemd-analyze security` scores it 1.5 or under ("OK"; the unhardened unit scored 7.7); `scripts/proof-hardening.sh` checks the score and every directive, and `scripts/proof-install.sh` runs the unit on a systemd container. Controls deliberately left open, and why: the network (the collector's purpose), user namespaces (`PrivateUsers`, not available on every host), and `@resources` (Go raises its own file-descriptor limit at start). A site may add `IPAddressAllow=` lines for its servers' addresses in a drop-in.

## 5. The software review

- `docs/notices.md`: every Go module in the binary with its licence (MIT, Apache-2.0, BSD-3-Clause).
- The SBOM (`*.cdx.json`, CycloneDX 1.6) per target, with module versions, purls and licence evidence; `scripts/proof-sbom.sh` validates one against the CycloneDX schema and against `go list`.
- `go mod verify` and `govulncheck` run on every CI build; the release is built from the tag by `.github/workflows/release.yml` alone (a byte-for-byte rebuild is not proven).
- The web UI is checked against WCAG 2.1 A and AA with axe-core on every page in both themes (`scripts/proof-a11y.sh`); the findings that remain are listed in that proof's output.
- Nothing in the binary names an AWS endpoint, partition or region (`TestNoHardCodedAWSPartition`), so the AWS door resolves GovCloud (US) endpoints as any other region's (`TestAWSEndpointsFollowThePartition`; no run against GovCloud itself).
