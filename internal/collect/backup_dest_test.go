package collect

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The lexer of backup_dest.go's header (302's design pass finding 4): each rule a row, and a hostile twin where a
// shell would do more than cut the line.
func TestBackupDestLexer(t *testing.T) {
	show := func(segs [][]lexWord) string {
		var out []string
		for _, s := range segs {
			var ws []string
			for _, w := range s {
				t := w.text
				if w.tainted {
					t += "!"
				}
				ws = append(ws, t)
			}
			out = append(out, strings.Join(ws, " "))
		}
		return strings.Join(out, " ; ")
	}
	for _, c := range []struct{ in, want, why string }{
		{"pgbackrest --stanza=demo archive-push %p", "pgbackrest --stanza=demo archive-push %p", ""},
		{"test ! -f /mnt/server/archivedir/%f && cp %p /mnt/server/archivedir/%f", "test ! -f /mnt/server/archivedir/%f ; cp %p /mnt/server/archivedir/%f", ""},
		{`copy "%p" "C:\server\archivedir\%f"`, `copy %p C:\server\archivedir\%f`, ""},
		{"gzip < %p > /mnt/server/archivedir/%f.gz", "gzip < %p > /mnt/server/archivedir/%f.gz", ""},
		{"cp %p /a/%f 2>&1 >> /var/log/x", "cp %p /a/%f 2 >& 1 >> /var/log/x", ""},
		{"a || b | c ; d & e", "a ; b ; c ; d ; e", ""},
		{`azcopy copy %p 'https://acct.blob.core.windows.net/wal/%f?sv=1&sig=X'`, "azcopy copy %p https://acct.blob.core.windows.net/wal/%f?sv=1&sig=X", ""},
		{"cp %p $DEST/%f", "cp %p $DEST/%f!", ""},
		{`cp %p "$(cat /etc/dest)"/%f`, "cp %p $(cat /etc/dest)/%f!", ""},
		{"cp %p `cat /etc/dest`/%f", "cp %p `cat! /etc/dest`/%f!", ""},
		{"cp %p /a/%f\nrm -rf /", "", "not known: a newline in the command"},
		{`cp %p "/a/%f`, "", "not known: an unclosed quote"},
		{strings.Repeat("a", 8193), "", "not known: too long"},
		{"", "", ""},
	} {
		segs, why := lexCommand(c.in)
		if why != c.why || (why == "" && show(segs) != c.want) {
			t.Errorf("%q: %q | %q, want %q | %q", c.in, show(segs), why, c.want, c.why)
		}
	}
}

// P11: every shape of backup_dest.go, each with a hostile twin (a variable, a substitution, an option where a name
// should be) that gives 'not known', never a guess; a credential's name sets secret and its value is in no field.
func TestBackupDestShapes(t *testing.T) {
	show := func(ds []backupDest) string {
		var out []string
		for _, d := range ds {
			s := strings.Join([]string{d.tool, d.kind, d.host, d.container, d.path, d.repoKey, d.detail}, "|")
			if d.secretSeen {
				s += "|SECRET"
			}
			out = append(out, s)
		}
		return strings.Join(out, " ;; ")
	}
	for _, c := range []struct{ name, cmd, role, want string }{
		// 1 pgBackRest
		{"pgbackrest", "pgbackrest --stanza=demo archive-push %p", "wal", "pgbackrest||||||stanza demo: the repository is in pgBackRest's configuration (read with read_tools on)"},
		{"pgbackrest inline s3", "pgbackrest --stanza=demo --repo1-type=s3 --repo1-s3-bucket=wal-b --repo1-s3-endpoint=minio.lab --repo1-path=/pg archive-push %p", "wal",
			"pgbackrest|s3|minio.lab|wal-b|/pg|repo1|stanza demo"},
		{"pgbackrest repo host", "pgbackrest --stanza demo --repo1-host=backup1 archive-get %f %p", "restore",
			"pgbackrest|host|backup1|||repo1|stanza demo; repository host backup1: its storage is in that host's configuration, not read"},
		{"pgbackrest a key inline", "pgbackrest --stanza=demo --repo1-s3-key=AKIAX --repo1-s3-key-secret=XYZ --repo1-type=s3 --repo1-s3-bucket=b archive-push %p", "wal",
			"pgbackrest|s3||b||repo1|stanza demo|SECRET"},
		{"pgbackrest hostile", "pgbackrest --stanza=$STANZA archive-push %p", "wal", "pgbackrest||||||not known: pgbackrest without a stanza pgvigil can read"},
		// 2 barman-wal-archive
		{"barman-wal-archive", "barman-wal-archive -U barman --port 22 -z backup1 pg %p", "wal", "barman|host|backup1||||barman server pg"},
		{"barman-wal-restore", "barman-wal-restore -P backup1 pg %f %p", "restore", "barman|host|backup1||||barman server pg"},
		{"barman unknown option", "barman-wal-archive --frobnicate backup1 pg %p", "wal", "barman||||||not known: an option barman-wal-archive does not take"},
		{"barman hostile", "barman-wal-archive $HOST pg %p", "wal", "barman||||||not known: barman's host and server"},
		// 3 barman-cloud
		{"barman-cloud", "barman-cloud-wal-archive --cloud-provider aws-s3 --endpoint-url https://minio.lab:9000 s3://wal-b/pg main %p", "wal",
			"barman-cloud|s3||wal-b|/pg||barman server main; endpoint minio.lab:9000"},
		{"barman-cloud sse file", "barman-cloud-wal-archive --sse-customer-key file:///etc/barman/sse-c.b64 s3://wal-b/pg main %p", "wal", "barman-cloud|s3||wal-b|/pg||barman server main"},
		{"barman-cloud sse inline", "barman-cloud-wal-archive --sse-customer-key c2VjcmV0 s3://wal-b/pg main %p", "wal", "barman-cloud|s3||wal-b|/pg||barman server main|SECRET"},
		{"barman-cloud hostile", "barman-cloud-wal-archive s3://$BUCKET/pg main %p", "wal", "barman-cloud||||||not known: barman-cloud's destination"},
		// 4 wal-g / wal-e
		{"wal-g inline prefix", "WALG_S3_PREFIX=s3://wal-b/pg wal-g wal-push %p", "wal", "wal-g|s3||wal-b|/pg||"},
		{"wal-g file prefix", "WALG_FILE_PREFIX=/backup/walg wal-g wal-push %p", "wal", "wal-g|posix|||/backup/walg||"},
		{"wal-e envdir", "envdir /etc/wal-e.d/env wal-e wal-push %p", "wal", "wal-e||||||the destination is in the envdir /etc/wal-e.d/env on the server - not known"},
		{"wal-g config", "wal-g --config /etc/walg.json wal-push %p", "wal", "wal-g||||||the destination is in its configuration file /etc/walg.json on the server - not known"},
		{"wal-g environment", "wal-g wal-push %p", "wal", "wal-g||||||the destination is in the server's environment - not known"},
		{"wal-g a secret inline", "AWS_SECRET_ACCESS_KEY=abc WALG_S3_PREFIX=s3://b/p wal-g wal-push %p", "wal", "wal-g|s3||b|/p|||SECRET"},
		{"wal-g hostile", "WALG_S3_PREFIX=s3://$B/p wal-g wal-push %p", "wal", "wal-g||||||not known: the prefix"},
		// 5 object stores
		{"aws s3", "timeout 300 aws s3 cp %p s3://wal-b/pg/%f --endpoint-url https://minio.lab", "wal", "aws|s3|minio.lab|wal-b|/pg||endpoint minio.lab"},
		{"gsutil", "gsutil -q cp %p gs://wal-b/pg/%f", "wal", "gsutil|gcs||wal-b|/pg||"},
		{"az", "az storage blob upload --account-name acct --container-name wal --name %f --file %p --account-key K", "wal", "az|azure|acct.blob.core.windows.net|wal||||SECRET"},
		{"azcopy sas", `azcopy copy %p 'https://acct.blob.core.windows.net/wal/%f?sv=2020&sig=X'`, "wal", "azcopy|azure|acct.blob.core.windows.net||/wal|||SECRET"},
		{"https user:pw", "curl -T %p https://user:pw@files.lab/wal/%f", "wal", "curl|https|files.lab||/wal|||SECRET"},
		{"rclone", "rclone copyto %p offsite:pg/wal/%f", "wal", "rclone|rclone-remote||offsite|/pg/wal||the remote offsite is defined in the server's rclone configuration"},
		{"rclone inline", "rclone copyto %p :s3,secret_access_key=XYZ:b/%f", "wal", "rclone||||||not known: an inline rclone remote|SECRET"},
		{"mc", "mc cp %p lab/wal-b/pg/%f", "wal", "mc|mc-alias||lab|/wal-b/pg||the alias lab is defined in the server's mc configuration"},
		{"s3 hostile", "aws s3 cp %p s3://wal-b/`hostname`/%f", "wal", "||||||not known: a command substitution"},
		{"s3 a variable", "aws s3 cp %p s3://wal-b/$HOST/%f", "wal", "aws||||||not known: aws's destination"},
		// 6 rsync / scp
		{"rsync", "PGPASSWORD=hunter2 rsync -a -e 'ssh -o StrictHostKeyChecking=no' %p backup@host1:/wal/%f", "wal", "rsync|host|host1||/wal|||SECRET"},
		{"rsync to barman", "rsync -a %p barman@backup1:/var/lib/barman/pg/incoming/%f", "wal", "barman|host|backup1||/var/lib/barman/pg/incoming||barman server pg (rsync into its incoming directory)"},
		{"rsync module", "rsync %p backup1::wal/pg/%f", "wal", "rsync|rsync-module|backup1|wal|/pg||"},
		{"scp", "scp -i /var/lib/postgresql/.ssh/id -P 2222 %p wal@host2:/srv/wal/%f", "wal", "scp|host|host2||/srv/wal||"},
		{"sshpass", "sshpass -p hunter2 scp %p wal@host2:/srv/wal/%f", "wal", "scp|host|host2||/srv/wal|||SECRET"},
		{"rsync hostile", "rsync -a %p host1:$DIR/%f", "wal", "rsync||||||not known: rsync's destination"},
		// 7 a local copy
		{"the documented copy", "test ! -f /mnt/server/archivedir/%f && cp %p /mnt/server/archivedir/%f", "wal", "copy|posix|||/mnt/server/archivedir||"},
		{"gzip", "gzip < %p > /mnt/server/archivedir/%f.gz", "wal", "copy|posix|||/mnt/server/archivedir||compressed with gzip"},
		{"windows copy", `copy "%p" "C:\server\archivedir\%f"`, "wal", `copy|posix|||C:\server\archivedir||`},
		{"restore cp", "cp /mnt/server/archivedir/%f %p", "restore", "copy|posix|||/mnt/server/archivedir||"},
		{"cp a password", "cp --password=hunter2 %p /a/%f", "wal", "copy|posix|||/a|||SECRET"},
		{"discard", "cp %p /dev/null", "wal", "copy|discard|||||WAL is discarded: the command copies to /dev/null"},
		{"true", "/bin/true", "wal", "none|discard|||||WAL is discarded: the command archives nothing (true)"},
		{"copy hostile", "cp %p $(cat /etc/dest)/%f", "wal", "||||||not known: a command substitution"},
		{"copy a variable", "cp %p $DEST/%f", "wal", "copy||||||not known: cp's target"},
		// 9 a script, and what no shape reads
		{"script", "/usr/local/bin/archive.sh %p %f", "wal", "script||||||a script (archive.sh): the destination is inside it - not known"},
		{"unknown", "frob %p", "wal", "||||||not known: frob is no command pgvigil reads"},
		{"newline", "cp %p /a/%f\nrm -rf /", "wal", "||||||not known: a newline in the command"},
		// 10 nothing
		{"disabled", "(disabled)", "wal", ""},
	} {
		if got := show(parseDestCommand(c.cmd, "archive_command", c.role)); got != c.want {
			t.Errorf("%s: %q\n  got  %q\n  want %q", c.name, c.cmd, got, c.want)
		}
	}
	// 8 the archive library
	if got := show(parseDestLibrary("basic_archive", "/var/lib/pg/archive")); got != "basic_archive|posix|||/var/lib/pg/archive||" {
		t.Errorf("basic_archive: %q", got)
	}
	if got := show(parseDestLibrary("my_archiver", "")); got != "library||||||the archive library my_archiver: the destination is the module's own setting - not known" {
		t.Errorf("another library: %q", got)
	}
	// no value of a secret is in any field of any row
	for _, c := range []string{"PGPASSWORD=hunter2 rsync -a %p backup@host1:/wal/%f", "cp --password=hunter2 %p /a/%f", "sshpass -p hunter2 scp %p w@h:/w/%f",
		"https://user:hunter2@files.lab/wal/%f", "rclone copyto %p :s3,secret_access_key=hunter2:b/%f"} {
		if s := show(parseDestCommand(c, "archive_command", "wal")); strings.Contains(s, "hunter2") {
			t.Errorf("%q kept the secret: %q", c, s)
		}
	}
}

// The settings into rows: F7 (a library wins over archive_command), archive_mode off, base backups where the tool's WAL
// goes and none for a plain copy, F12's standby and primary words.
func TestBackupDestRows(t *testing.T) {
	show := func(rows []Row) string {
		var out []string
		for _, r := range rows[1:] {
			out = append(out, fmt.Sprintf("%v %v %v %v %v", r["role"], r["seq"], r["source"], r["tool"], r["detail"]))
		}
		return strings.Join(out, " ;; ")
	}
	for _, c := range []struct {
		name string
		st   destSettings
		want string
	}{
		{"a library wins", destSettings{archiveMode: "on", archiveCmd: "cp %p /a/%f", archiveLib: "basic_archive", basicDir: "/arch"},
			"wal 1 archive_library basic_archive <nil>"},
		{"archive_mode off", destSettings{archiveMode: "off", archiveCmd: "cp %p /a/%f"}, "wal 1 archive_mode none WAL is not archived (archive_mode off)"},
		{"pgbackrest: base where WAL goes", destSettings{archiveMode: "on", archiveCmd: "pgbackrest --stanza=demo archive-push %p"},
			"wal 1 archive_command pgbackrest stanza demo: the repository is in pgBackRest's configuration (read with read_tools on) ;; " +
				"base 1 archive_command pgbackrest stanza demo: the repository is in pgBackRest's configuration (read with read_tools on) (base backups go where its WAL goes)"},
		{"a plain copy: no base row", destSettings{archiveMode: "on", archiveCmd: "cp %p /a/%f", isReplica: false}, "wal 1 archive_command copy <nil>"},
		{"a standby with archive_mode on", destSettings{archiveMode: "on", archiveCmd: "cp %p /a/%f", isReplica: true},
			"wal 1 archive_command copy (this standby does not archive: archive_mode on archives on a primary only, always in recovery too)"},
		{"a restore_command on a primary", destSettings{archiveMode: "on", archiveCmd: "cp %p /a/%f", restoreCmd: "cp /a/%f %p"},
			"wal 1 archive_command copy <nil> ;; restore 1 restore_command copy (set, not in use: this server is a primary)"},
		{"an empty archive_command", destSettings{archiveMode: "on"}, "wal 1 archive_command none WAL is not archived (archive_command is empty)"},
	} {
		if got := show(destRows(c.st)); got != c.want {
			t.Errorf("%s:\n  got  %q\n  want %q", c.name, got, c.want)
		}
	}
}

// F8: pgBackRest's configuration as the collector host's pgBackRest reads it - [stanza:cmd] over [stanza] over
// [global:cmd] over [global], the include directory, PGBACKREST_CONFIG alone, the environment over the files, the
// server's inline options over all; a key's or a passphrase's value is never read (only whitelisted names).
func TestPgbrConfig(t *testing.T) {
	dir := t.TempDir()
	write := func(p, s string) string {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	main := write(filepath.Join(dir, "pgbackrest.conf"), "[global]\nrepo1-path=/global\nrepo1-type=s3\nrepo1-s3-bucket=gb\nrepo1-s3-key=hunter2\nrepo1-cipher-pass=hunter3\n"+
		"[global:archive-push]\nrepo1-path=/global-push\n[demo]\nrepo1-s3-bucket=demob\n[demo:backup]\nrepo1-path=/demo-backup\n[other]\nrepo1-path=/other\n")
	write(filepath.Join(dir, "conf.d", "b.conf"), "[demo]\nrepo2-path=/second\n")
	pgbrFiles.file, pgbrFiles.oldFile, pgbrFiles.include = main, filepath.Join(dir, "none"), filepath.Join(dir, "conf.d")
	env := map[string]string{}
	pgbrGetenv = func(k string) string { return env[k] }
	pgbrEnviron = func() []string {
		var out []string
		for k, v := range env {
			out = append(out, k+"="+v)
		}
		return out
	}
	defer func() { pgbrGetenv, pgbrEnviron = os.Getenv, os.Environ }()
	join := func(m map[string]string) string {
		var ks []string
		for k, v := range m {
			ks = append(ks, k+"="+v)
		}
		sort.Strings(ks)
		return strings.Join(ks, " ")
	}
	opts, _, why := pgbrConfig("demo", "archive-push", "", nil)
	if why != "" || join(opts) != "repo1-path=/global-push repo1-s3-bucket=demob repo1-type=s3 repo2-path=/second" {
		t.Errorf("archive-push: %s | %s", join(opts), why)
	}
	opts, _, _ = pgbrConfig("demo", "backup", "", nil)
	if opts["repo1-path"] != "/demo-backup" {
		t.Errorf("backup: %s", join(opts))
	}
	env["PGBACKREST_REPO1_PATH"], env["PGBACKREST_REPO1_S3_KEY_SECRET"] = "/from-env", "hunter4"
	opts, from, _ := pgbrConfig("demo", "archive-push", "", map[string]string{"repo1-s3-bucket": "inline"})
	if opts["repo1-path"] != "/from-env" || from["repo1-path"] != "environment" || opts["repo1-s3-bucket"] != "inline" || from["repo1-s3-bucket"] != "the server's command" {
		t.Errorf("environment and inline: %s", join(opts))
	}
	alone := write(filepath.Join(dir, "alone.conf"), "[global]\nrepo1-path=/alone\n")
	delete(env, "PGBACKREST_REPO1_PATH")
	env["PGBACKREST_CONFIG"] = alone
	opts, _, _ = pgbrConfig("demo", "archive-push", "", nil)
	if opts["repo1-path"] != "/alone" || opts["repo2-path"] != "" {
		t.Errorf("PGBACKREST_CONFIG alone (no include directory): %s", join(opts))
	}
	delete(env, "PGBACKREST_CONFIG")
	for _, o := range []map[string]string{opts} {
		if strings.Contains(join(o), "hunter") {
			t.Errorf("a secret was read: %s", join(o))
		}
	}
	opts, _, _ = pgbrConfig("demo", "archive-push", "", nil)
	if strings.Contains(join(opts), "hunter") {
		t.Errorf("a secret was read: %s", join(opts))
	}
	ds := pgbrDests("demo", "wal", opts, map[string]string{"repo1-path": main})
	if len(ds) != 2 || ds[0].kind != "s3" || ds[0].container != "demob" || ds[0].path != "/global-push" || ds[1].path != "/second" || ds[1].kind != "posix" ||
		!strings.Contains(ds[1].detail, "type posix (pgBackRest's default)") {
		t.Errorf("the destinations: %+v", ds)
	}
	if ds := pgbrDests("demo", "wal", map[string]string{"repo1-host": "backup1"}, map[string]string{"repo1-host": main}); len(ds) != 1 || ds[0].kind != "host" ||
		!strings.Contains(ds[0].detail, "repository host backup1") {
		t.Errorf("a repository host: %+v", ds)
	}
	if _, _, why := pgbrConfig("demo", "archive-push", filepath.Join(dir, "missing.conf"), nil); why != "file not readable" {
		t.Errorf("a missing file: %q", why)
	}
}

// The tool reads behind the gate: off = a 'not_read' / 'off' row and nothing run; on, barman's show-servers decoded
// into the whitelisted keys only (its conninfo's password in no row); a failure in the fixed words, stderr never read.
func TestBackupDestToolReads(t *testing.T) {
	ran := 0
	origLook, origRun := lookTool, runTool
	defer func() { lookTool, runTool = origLook, origRun }()
	lookTool = func(string) (string, error) { return "/stand-in", nil }
	runTool = func(_ context.Context, _ string, _ ...string) ([]byte, error) {
		ran++
		return []byte(`{"pg": {"conninfo": "host=pg1 user=barman password=hunter2", "ssh_command": "ssh postgres@pg1", "post_backup_script": "/x.sh",
			"barman_home": "/var/lib/barman", "backup_directory": "/var/lib/barman/pg", "basebackups_directory": "s3://bk/pg/base",
			"wals_directory": "", "backup_method": "rsync", "archiver": true, "retention_policy": "RECOVERY WINDOW OF 4 WEEKS"}}`), nil
	}
	if rows := readBackupTool(context.Background(), backupTool{tool: "pgbackrest", name: "demo", from: "archive_command"}, 0, false); len(rows) != 1 ||
		rows[0]["state"] != "not_read" || rows[0]["message"] != backupNotRead || ran != 0 {
		t.Errorf("backup_tools off: %v (ran %d)", rows, ran)
	}
	if rows := readDestTool(destTool{tool: "barman", name: "pg"}, false); len(rows) != 1 || rows[0]["state"] != "off" || ran != 0 {
		t.Errorf("backup_dest off: %v (ran %d)", rows, ran)
	}
	rows := readDestTool(destTool{tool: "barman", name: "pg"}, true)
	all := fmt.Sprint(rows)
	if len(rows) != 3 || rows[0]["state"] != "ok" || strings.Contains(all, "hunter2") || strings.Contains(all, "ssh") || strings.Contains(all, "x.sh") ||
		rows[1]["role"] != "base" || rows[1]["dest_kind"] != "s3" || rows[1]["container"] != "bk" || rows[1]["path"] != "/pg/base" ||
		rows[2]["role"] != "wal" || rows[2]["path"] != "/var/lib/barman/pg/wals" || !strings.Contains(fmt.Sprint(rows[2]["detail"]), "retention RECOVERY WINDOW OF 4 WEEKS") {
		t.Errorf("barman show-servers: %v", rows)
	}
	runTool = func(context.Context, string, ...string) ([]byte, error) { return nil, errors.New("exit code 2") }
	if rows := readBackupTool(context.Background(), backupTool{tool: "pgbackrest", name: "demo", from: "archive_command"}, 0, true); rows[0]["state"] != "error" ||
		rows[0]["message"] != "exit code 2" {
		t.Errorf("a failure's words: %v", rows)
	}
}

// runTool's failure words: the exit code, never the tool's stderr (F3).
func TestRunToolWords(t *testing.T) {
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skip("no sh")
	}
	_, err = runTool(context.Background(), sh, "-c", "echo hunter2 >&2; exit 3")
	if err == nil || err.Error() != "exit code 3" {
		t.Errorf("runTool's error: %v", err)
	}
}
