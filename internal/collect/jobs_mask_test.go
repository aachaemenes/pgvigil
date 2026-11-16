package collect

import (
	"strings"
	"testing"
)

// TestMaskJobText: every password form a job step, a connection string or a run's output is known to carry is
// masked, and the text around it is kept.
func TestMaskJobText(t *testing.T) {
	cases := []struct{ in, secret, keep string }{
		{`ALTER LOGIN x WITH PASSWORD = 'top''secret'`, "secret", "ALTER LOGIN x WITH PASSWORD = '<masked>'"},
		{`CREATE CREDENTIAL c WITH IDENTITY = 'u', SECRET = N'topsecret'`, "topsecret", "SECRET = '<masked>'"},
		{`EXEC sp_addlinkedsrvlogin @rmtsrvname = 'S', @rmtuser = 'u', @rmtpassword = N'topsecret'`, "topsecret", "@rmtuser = 'u'"},
		{`EXEC sp_addlogin @loginame = 'u', @passwd = 'topsecret'`, "topsecret", "@loginame = 'u'"},
		{`sqlcmd -S srv -U u -P topsecret -Q "SELECT 1"`, "topsecret", `-Q "SELECT 1"`},
		{`bcp db.dbo.t out f.dat -S srv -U u -Ptopsecret -c`, "topsecret", "-c"},
		{`Invoke-Thing -Server s -Password 'topsecret' -Force`, "topsecret", "-Force"},
		{`$p = ConvertTo-SecureString 'topsecret' -AsPlainText -Force`, "topsecret", "-AsPlainText"},
		{`net use \\h\s topsecret /user:dom\u`, "topsecret", "/user:dom"},
		{`dtexec /F pkg.dtsx /DE topsecret /REP E`, "topsecret", "/REP E"},
		{`Server=s;Database=d;User Id=u;Password=topsecret;`, "topsecret", "Database=d"},
		{`Data Source=s;Pwd = "top secret";Encrypt=yes`, "secret", "Encrypt=yes"},
		{`host=db1 user=agg password = topsecret dbname=app`, "topsecret", "dbname=app"},
		{`host=db1 password='top secret' dbname=app`, "secret", "dbname=app"},
		{`postgresql://agg:topsecret@db1/app`, "topsecret", "postgresql://agg:<masked>@db1/app"},
		{`ERROR:  password authentication failed for user "agg"`, "", `password authentication failed for user "agg"`},
		// backup products' keys (S16): Ola Hallengren's DatabaseBackup, LiteSpeed's procedures and tools, Red Gate SQL
		// Backup's PASSWORD inside the -SQL string (quotes doubled, or square brackets), Idera SQL Safe, MEDIAPASSWORD
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @BackupSoftware = 'LITESPEED', @Encrypt = 'Y', @EncryptionAlgorithm = 'AES_256', @EncryptionKey = N'olakey1'`, "olakey1", "@EncryptionAlgorithm = 'AES_256', @EncryptionKey = '<masked>'"},
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @ENCRYPTIONKEY='olakey2', @Verify = 'Y'`, "olakey2", "@Verify = 'Y'"},
		{`EXEC master.dbo.xp_backup_database @database = N'db1', @filename = N'/b/db1.bak', @encryptionkey = 'lskey1', @cryptlevel = 8`, "lskey1", "@cryptlevel = 8"},
		{`EXEC master.dbo.xp_restore_database @database = N'db1', @filename = N'/b/db1.bak', @jobp = N'lsjobp1'`, "lsjobp1", "@filename = N'/b/db1.bak', @jobp = '<masked>'"},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/db1.sqb'' WITH PASSWORD = ''rgkey1'', KEYSIZE = 256"'`, "rgkey1", "PASSWORD = ''<masked>'', KEYSIZE = 256\"'"},
		{`DECLARE @ReturnCode int EXECUTE @ReturnCode = dbo.sqlbackup N'-SQL "BACKUP DATABASE [db1] TO DISK = N''/b/db1.sqb'' WITH CHECKSUM, PASSWORD = N''rgkey2''"'`, "rgkey2", "PASSWORD = ''<masked>''\"'"},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [rg key3] "'`, "key3", "PASSWORD = [<masked>] \"'"},
		{`EXEC master.dbo.xp_ss_backup @database = N'db1', @filename = N'/b/db1.safe', @encryptiontype = N'AES256', @encryptedbackuppassword = N'sskey1'`, "sskey1", "@encryptiontype = N'AES256'"},
		{`RESTORE DATABASE db1 FROM DISK = N'/b/db1.bak' WITH MEDIAPASSWORD = N'mpkey1', REPLACE`, "mpkey1", "MEDIAPASSWORD = '<masked>', REPLACE"},
		{`BACKUP DATABASE db1 TO DISK = '/b/db1.bak' WITH MEDIAPASSWORD = 'mpkey2', INIT`, "mpkey2", ", INIT"},
		{`EXEC (N'ALTER LOGIN app WITH PASSWORD = ''dynpw1'', CHECK_POLICY = OFF')`, "dynpw1", "PASSWORD = ''<masked>'', CHECK_POLICY = OFF')"},
		{`CREATE LOGIN app WITH PASSWORD = '', CHECK_POLICY = OFF`, "", "PASSWORD = '<masked>', CHECK_POLICY = OFF"},
		{`ALTER LOGIN app WITH PASSWORD = '''qpw1', CHECK_POLICY = OFF`, "qpw1", "PASSWORD = '<masked>', CHECK_POLICY = OFF"},
		{`slssqlmaint.exe -BackupKey lscli1 -Verify`, "lscli1", "-Verify"},
		{`SLSFastCompression.exe -e 8 --JobP lscli2 -F x.bak`, "lscli2", "-F x.bak"},
		{`extractor.exe -F /b/db1.bak -K lscli3 --Key lscli4 -E db1`, "lscli", "-E db1"},
		// readable: a parameter that only names a key, a certificate or a placeholder is not a secret
		{`EXECUTE dbo.DatabaseBackup @Encrypt = 'Y', @ServerCertificate = N'BackupCert', @EncryptionKeyPlaceholder = N'ph1', @KeyColumns = N'id,name', KEYSIZE = 256`, "", "@ServerCertificate = N'BackupCert', @EncryptionKeyPlaceholder = N'ph1', @KeyColumns = N'id,name', KEYSIZE = 256"},
		{`Invoke-Thing -KeepAlive -Name keep1 -Force`, "", "-KeepAlive -Name keep1 -Force"},
	}
	for _, c := range cases {
		got := MaskJobText(c.in)
		if c.secret != "" && strings.Contains(got, c.secret) {
			t.Errorf("%q: the secret is still there: %q", c.in, got)
		}
		if !strings.Contains(got, c.keep) {
			t.Errorf("%q: %q lost %q", c.in, got, c.keep)
		}
	}
}

// TestMaskJobTextExact: the masked text in full, where the value's place decides its form - a value cut by a read
// (never closed), a value inside another string (its quotes doubled), an empty value, a key given by position or as
// a bare word - and texts that must come back unchanged.
func TestMaskJobTextExact(t *testing.T) {
	cases := []struct{ in, want string }{
		// a key cut by the read: masked to the end of the text
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = N'cutkey1abcdefgh`, `EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = '<masked>`},
		{`ALTER LOGIN a WITH PASSWORD = N'cutpw2abc`, `ALTER LOGIN a WITH PASSWORD = '<masked>`},
		{`EXEC (N'ALTER LOGIN a WITH PASSWORD = ''cutpw3abc`, `EXEC (N'ALTER LOGIN a WITH PASSWORD = ''<masked>`},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [cut key4`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [<masked>`},
		{`Executed as user: sa. Command: EXECUTE master.dbo.xp_backup_database @database = N'master', @encryptionkey = N'histcut5zzzz`, `Executed as user: sa. Command: EXECUTE master.dbo.xp_backup_database @database = N'master', @encryptionkey = '<masked>`},
		// a switch's value inside another string, its quotes doubled
		{`EXEC xp_cmdshell 'extractor.exe -F x.bak -K ''lsk6'' -E db1'`, `EXEC xp_cmdshell 'extractor.exe -F x.bak -K <masked> -E db1'`},
		{`EXEC xp_cmdshell 'powershell -Command "Invoke-Thing -Password ''pw7x'' -Force"'`, `EXEC xp_cmdshell 'powershell -Command "Invoke-Thing -Password <masked> -Force"'`},
		{`EXEC xp_cmdshell 'powershell -Command "$p = ConvertTo-SecureString ''pw8x'' -AsPlainText -Force"'`, `EXEC xp_cmdshell 'powershell -Command "$p = ConvertTo-SecureString <masked> -AsPlainText -Force"'`},
		{`extractor.exe -F x.bak --TgtKey tgtk9 -E db1`, `extractor.exe -F x.bak --TgtKey <masked> -E db1`},
		{`slssqlmaint.exe -jobp jobpk10 -Verify`, `slssqlmaint.exe -jobp <masked> -Verify`},
		// an empty value: never the text up to the next pair of quotes; inside another string, still that string's
		{`ALTER LOGIN a WITH PASSWORD = '', CHECK_POLICY = OFF; ALTER LOGIN b WITH PASSWORD = ''`, `ALTER LOGIN a WITH PASSWORD = '<masked>', CHECK_POLICY = OFF; ALTER LOGIN b WITH PASSWORD = '<masked>'`},
		{"$Password = ''\n$Domain = ''", "$Password = '<masked>'\n$Domain = ''"},
		{`EXEC dbo.p @passwd = ''; EXEC dbo.q @x = N''`, `EXEC dbo.p @passwd = '<masked>'; EXEC dbo.q @x = N''`},
		{`EXEC (N'CREATE LOGIN a WITH PASSWORD = '''', DEFAULT_DATABASE = [master]')`, `EXEC (N'CREATE LOGIN a WITH PASSWORD = ''<masked>'', DEFAULT_DATABASE = [master]')`},
		// Red Gate's clean-up (sqbutility 1032) takes the key as its sixth argument
		{`EXECUTE master..sqbutility 1032, N'db1', N'D:\b', 'D', '24h', 'rgkey15'`, `EXECUTE master..sqbutility 1032, N'db1', N'D:\b', 'D', '24h', '<masked>'`},
		{`EXEC (N'EXECUTE master..sqbutility 1032, N''db1'', N''D:\b'', ''D'', ''24h'', ''rgkey16''')`, `EXEC (N'EXECUTE master..sqbutility 1032, N''db1'', N''D:\b'', ''D'', ''24h'', ''<masked>''')`},
		// a bracketed value holding ]] (an escaped ])
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [ab]]cdkey17] "'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = [<masked>] "'`},
		// a bare word as the key (T-SQL takes one as a procedure's string argument)
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @BackupSoftware = 'LITESPEED', @EncryptionKey = olakeyident18, @Verify = 'Y'`, `EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @BackupSoftware = 'LITESPEED', @EncryptionKey = <masked>, @Verify = 'Y'`},
		{`EXEC master.dbo.xp_restore_database @database = N'db1', @jobp = jobpbare19`, `EXEC master.dbo.xp_restore_database @database = N'db1', @jobp = <masked>`},
		// a comment's apostrophe does not turn the quoting round; an apostrophe the reading does not know still masks
		// a doubled value
		{"-- Ola's key, don't print it\nEXECUTE master..sqlbackup '-SQL \"BACKUP DATABASE [db1] TO DISK = ''/b/x.sqb'' WITH PASSWORD = ''rgkey20''\"'", "-- Ola's key, don't print it\nEXECUTE master..sqlbackup '-SQL \"BACKUP DATABASE [db1] TO DISK = ''/b/x.sqb'' WITH PASSWORD = ''<masked>''\"'"},
		{"# it's\nEXECUTE master..sqlbackup '-SQL \"BACKUP DATABASE [db1] TO DISK = ''/b/x.sqb'' WITH PASSWORD = ''rgkey21''\"'", "# it's\nEXECUTE master..sqlbackup '-SQL \"BACKUP DATABASE [db1] TO DISK = ''/b/x.sqb'' WITH PASSWORD = ''<masked>''\"'"},
		// unchanged: no key given, a variable, NULL
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = NULL, @Verify = 'Y'; EXECUTE dbo.DatabaseBackup @EncryptionKey = @key`, `EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = NULL, @Verify = 'Y'; EXECUTE dbo.DatabaseBackup @EncryptionKey = @key`},
		{`EXECUTE master..sqbutility 1032, N'db1', N'D:\b', 'D', '24h', NULL`, `EXECUTE master..sqbutility 1032, N'db1', N'D:\b', 'D', '24h', NULL`},
	}
	for _, c := range cases {
		if got := MaskJobText(c.in); got != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.in, got, c.want)
		}
	}
}

// TestMaskTree masks the strings of a decoded definition and nothing else.
func TestMaskTree(t *testing.T) {
	d := map[string]any{"name": "j", "steps": map[string]any{"s #1": map[string]any{"connection": "host=h password=pw1", "n": int64(3)}}}
	maskTree(d)
	got := d["steps"].(map[string]any)["s #1"].(map[string]any)
	if got["connection"] != "host=h password=<masked>" || got["n"] != int64(3) || d["name"] != "j" {
		t.Errorf("maskTree: %v", d)
	}
}
