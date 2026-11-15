package collect

import (
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
