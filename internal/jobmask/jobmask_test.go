package jobmask

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

// prefilterRE is Prefilter as Go reads it, the way PostgreSQL's ~* does (no case, . across lines).
var prefilterRE = regexp.MustCompile("(?is)" + Prefilter)

// inPrefilter fails the test when a text the masking changes is one a migration's prefilter would not read, as the
// text and as a jsonb value's text form.
func inPrefilter(t *testing.T, in string) {
	t.Helper()
	var j strings.Builder // jsonb's text form escapes no < or > (json.Marshal would)
	e := json.NewEncoder(&j)
	e.SetEscapeHTML(false)
	_ = e.Encode(in)
	if !prefilterRE.MatchString(in) || !prefilterRE.MatchString(j.String()) {
		t.Errorf("the prefilter does not read %q", in)
	}
}

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
		got := Text(c.in)
		if got != c.in {
			inPrefilter(t, c.in)
		}
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
		// -P only on a line naming bcp, sqlcmd, osql or isql, -K only on a line naming a LiteSpeed tool: a
		// PowerShell -Path and sqlcmd's own -K ReadOnly stay readable
		{`Get-ChildItem -Path D:\Backup -PassThru`, `Get-ChildItem -Path D:\Backup -PassThru`},
		{`sqlcmd -S srv -E -K ReadOnly -Q "SELECT 1"`, `sqlcmd -S srv -E -K ReadOnly -Q "SELECT 1"`},
		{"Get-ChildItem -Path D:\\x\nsqlcmd -S s -U u -P pw24\nslssqlmaint.exe -K k24 -Verify", "Get-ChildItem -Path D:\\x\nsqlcmd -S s -U u -P <masked>\nslssqlmaint.exe -K <masked> -Verify"},
		{`osql -S s -U u -Ppw25 -Q "SELECT 1"`, `osql -S s -U u -P<masked> -Q "SELECT 1"`},
		{`isql.exe -S s -U u -P pw26`, `isql.exe -S s -U u -P <masked>`},
		{`EXEC xp_cmdshell 'BCP db.dbo.t out f.dat -S srv -U u -Ppw27 -c'`, `EXEC xp_cmdshell 'BCP db.dbo.t out f.dat -S srv -U u -P<masked> -c'`},
		// the tool's line is the logical one (cmd's ^, PowerShell's backtick and a shell's \ continue it), and a tool
		// named through a variable ($sqlcmd, ${sqlcmd}, %SQLCMD%) is that tool
		{"bcp db.dbo.t out t.dat -S s -U u ^\r\n-P cnpw28 -c", "bcp db.dbo.t out t.dat -S s -U u ^\r\n-P <masked> -c"},
		{"bcp db.dbo.t out t.dat -S s `\n  -U u -P cnpw29 -c", "bcp db.dbo.t out t.dat -S s `\n  -U u -P <masked> -c"},
		{"sqlcmd -S s \\\n -U u \\\n -P cnpw30", "sqlcmd -S s \\\n -U u \\\n -P <masked>"},
		{`& $sqlcmd -S s -U u -P vapw31 -Q "SELECT 1"`, `& $sqlcmd -S s -U u -P <masked> -Q "SELECT 1"`},
		{`& ${sqlcmd} -S s -U u -P vapw32`, `& ${sqlcmd} -S s -U u -P <masked>`},
		{`"%SQLCMD%" -S s -U u -P vapw33`, `"%SQLCMD%" -S s -U u -P <masked>`},
		// a line break without a continuation ends the tool's line
		{"bcp db.dbo.t out t.dat -S s\nGet-ChildItem -Path D:\\x", "bcp db.dbo.t out t.dat -S s\nGet-ChildItem -Path D:\\x"},
		// on a tool's line -P is never read out of -Password, -Pwd or -Pw (a name the switch rule masks itself); an
		// attached key starting with w stays masked
		{`sqlcmd -S s -U u -Password pw34 -Q "SELECT 1"`, `sqlcmd -S s -U u -Password <masked> -Q "SELECT 1"`},
		{`osql -S s -U u -Pwd pw35`, `osql -S s -U u -Pwd <masked>`},
		{`osql -S s -U u -Pw0rd36 -Q x`, `osql -S s -U u -P<masked> -Q x`},
		// PostgreSQL's role password (S16b): [ ENCRYPTED ] PASSWORD and a string constant, no '=' (CREATE / ALTER ROLE
		// and USER), and a user mapping's password option; each string constant form, inside another string doubled
		{`ALTER ROLE app PASSWORD 'pgr1'`, `ALTER ROLE app PASSWORD '<masked>'`},
		{`ALTER ROLE app WITH LOGIN ENCRYPTED PASSWORD 'pgr2' VALID UNTIL 'infinity'`, `ALTER ROLE app WITH LOGIN ENCRYPTED PASSWORD '<masked>' VALID UNTIL 'infinity'`},
		{`CREATE ROLE r LOGIN PASSWORD $$pgr3$$`, `CREATE ROLE r LOGIN PASSWORD '<masked>'`},
		{`CREATE USER u PASSWORD $pw$pgr4'x$pw$; SELECT 1`, `CREATE USER u PASSWORD '<masked>'; SELECT 1`},
		{`ALTER USER app PASSWORD E'pgr5\'x' VALID UNTIL 'infinity'`, `ALTER USER app PASSWORD '<masked>' VALID UNTIL 'infinity'`},
		{`ALTER ROLE app PASSWORD U&'pgr6\0061'`, `ALTER ROLE app PASSWORD '<masked>'`},
		{`SELECT dblink_exec('dbname=postgres', 'ALTER ROLE app PASSWORD ''pgr7''')`, `SELECT dblink_exec('dbname=postgres', 'ALTER ROLE app PASSWORD ''<masked>''')`},
		{`CREATE USER MAPPING FOR app SERVER s OPTIONS (user 'app', password 'pgr8')`, `CREATE USER MAPPING FOR app SERVER s OPTIONS (user 'app', password '<masked>')`},
		{`ALTER USER MAPPING FOR app SERVER s OPTIONS (SET password 'pgr9')`, `ALTER USER MAPPING FOR app SERVER s OPTIONS (SET password '<masked>')`},
		{`alter role app password 'pgr10'`, `alter role app password '<masked>'`},
		{`ALTER ROLE app PASSWORD 'pgr11cut`, `ALTER ROLE app PASSWORD '<masked>`},
		{`CREATE ROLE r PASSWORD $$pgr12cut`, `CREATE ROLE r PASSWORD '<masked>`},
		// readable: PASSWORD NULL, a parameter or a format placeholder, prose, a T-SQL PASSWORD = (its own rule)
		{`ALTER ROLE app PASSWORD NULL; COMMENT ON ROLE app IS 'reset the password monthly'`, `ALTER ROLE app PASSWORD NULL; COMMENT ON ROLE app IS 'reset the password monthly'`},
		{`EXECUTE format('ALTER ROLE %I PASSWORD %L', r, v_pw); PREPARE p AS SELECT 1 WHERE $1 = 'password'`, `EXECUTE format('ALTER ROLE %I PASSWORD %L', r, v_pw); PREPARE p AS SELECT 1 WHERE $1 = 'password'`},
		{`ALTER ROLE app PASSWORD $1`, `ALTER ROLE app PASSWORD $1`},
		// a quote right after the word is the end of the string around it, never a value
		{`DO $$BEGIN EXECUTE 'ALTER ROLE app PASSWORD ' || quote_literal(v_pw); END$$`, `DO $$BEGIN EXECUTE 'ALTER ROLE app PASSWORD ' || quote_literal(v_pw); END$$`},
		{`DO $$BEGIN EXECUTE 'ALTER ROLE app PASSWORD ' || quote_literal(v_pw) || ' VALID UNTIL ''2027-01-01'''; END$$`, `DO $$BEGIN EXECUTE 'ALTER ROLE app PASSWORD ' || quote_literal(v_pw) || ' VALID UNTIL ''2027-01-01'''; END$$`},
		{`RAISERROR('wrong password ', 16, 1); PRINT 'done'`, `RAISERROR('wrong password ', 16, 1); PRINT 'done'`},
		{"Write-Host -Message 'Type the password '\nRead-Host -AsSecureString\nWrite-Host done", "Write-Host -Message 'Type the password '\nRead-Host -AsSecureString\nWrite-Host done"},
		// an escape or Unicode string inside another string, quotes doubled; a backslash-escaped one; a dollar body's
		// lone quote does not turn the reading round (3)
		{`SELECT dblink_exec('dbname=postgres', 'ALTER ROLE app PASSWORD E''pgr13''')`, `SELECT dblink_exec('dbname=postgres', 'ALTER ROLE app PASSWORD ''<masked>''')`},
		{`SELECT dblink_exec('dbname=postgres', 'ALTER ROLE app PASSWORD U&''pgr14''')`, `SELECT dblink_exec('dbname=postgres', 'ALTER ROLE app PASSWORD ''<masked>''')`},
		{`DO $d$BEGIN EXECUTE E'ALTER ROLE app PASSWORD \'pgr15\''; END$d$`, `DO $d$BEGIN EXECUTE E'ALTER ROLE app PASSWORD \'<masked>\''; END$d$`},
		{`ALTER ROLE a PASSWORD $pw$x'y$pw$; ALTER ROLE b PASSWORD E'pgr16'`, `ALTER ROLE a PASSWORD '<masked>'; ALTER ROLE b PASSWORD '<masked>'`},
		// a user mapping's sslpassword, its option name in double quotes, a comment before the value, a cut after a
		// backslash (4, 5)
		{`CREATE USER MAPPING FOR app SERVER s OPTIONS (user 'app', sslpassword 'pgr17')`, `CREATE USER MAPPING FOR app SERVER s OPTIONS (user 'app', sslpassword '<masked>')`},
		{`CREATE USER MAPPING FOR app SERVER s OPTIONS ("password" 'pgr18')`, `CREATE USER MAPPING FOR app SERVER s OPTIONS ("password" '<masked>')`},
		{`ALTER ROLE app PASSWORD /* new */ 'pgr19'`, `ALTER ROLE app PASSWORD /* new */ '<masked>'`},
		{`ALTER ROLE app PASSWORD E'pgr20\`, `ALTER ROLE app PASSWORD '<masked>`},
		// unchanged: no key given, a variable, NULL
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = NULL, @Verify = 'Y'; EXECUTE dbo.DatabaseBackup @EncryptionKey = @key`, `EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = NULL, @Verify = 'Y'; EXECUTE dbo.DatabaseBackup @EncryptionKey = @key`},
		{`EXECUTE master..sqbutility 1032, N'db1', N'D:\b', 'D', '24h', NULL`, `EXECUTE master..sqbutility 1032, N'db1', N'D:\b', 'D', '24h', NULL`},
	}
	for _, c := range cases {
		if got := Text(c.in); got != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.in, got, c.want)
		}
		if c.want != c.in {
			inPrefilter(t, c.in)
		}
	}
}

// TestStored: texts an older build stored - its rules took an empty literal at the start of a doubled value, the N
// of N'...', a bracketed value up to a space, the opening quotes of a switch's doubled value, or knew no rule for the
// form - keep no key once masked again, at the step's level and one quote level deeper (a job's script); a text the
// older rules masked whole, and today's own marks, come back as they are; masking again changes nothing.
func TestStored(t *testing.T) {
	cases := []struct{ in, want string }{
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/db1.sqb'' WITH PASSWORD = '<masked>'rgkey1'', KEYSIZE = 256"'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/db1.sqb'' WITH PASSWORD = '<masked>', KEYSIZE = 256"'`},
		{`DECLARE @ReturnCode int EXECUTE @ReturnCode = dbo.sqlbackup N'-SQL "BACKUP DATABASE [db1] TO DISK = N''/b/db1.sqb'' WITH CHECKSUM, PASSWORD = '<masked>'rgkey2''"' IF @ReturnCode <> 0 RAISERROR('Error performing SQLBackup backup.', 16, 1)`, `DECLARE @ReturnCode int EXECUTE @ReturnCode = dbo.sqlbackup N'-SQL "BACKUP DATABASE [db1] TO DISK = N''/b/db1.sqb'' WITH CHECKSUM, PASSWORD = '<masked>'"' IF @ReturnCode <> 0 RAISERROR('Error performing SQLBackup backup.', 16, 1)`},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = <masked> rgkey3] "'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = <masked> "'`},
		{`RESTORE DATABASE db1 FROM DISK = N'/b/db1.bak' WITH MEDIAPASSWORD = <masked>'mpkey4', REPLACE`, `RESTORE DATABASE db1 FROM DISK = N'/b/db1.bak' WITH MEDIAPASSWORD = <masked>, REPLACE`},
		{`EXEC (N'ALTER LOGIN app WITH PASSWORD = '<masked>'dynpw5'', CHECK_POLICY = OFF')`, `EXEC (N'ALTER LOGIN app WITH PASSWORD = '<masked>', CHECK_POLICY = OFF')`},
		// a job's script: the step's command inside @command = N'...', every quote doubled once more
		{`@command = N'EXECUTE master..sqlbackup ''-SQL "BACKUP DATABASE [db1] TO DISK = ''''/b/db1.sqb'''' WITH PASSWORD = ''<masked>''rgkey6'''', KEYSIZE = 256"'''`, `@command = N'EXECUTE master..sqlbackup ''-SQL "BACKUP DATABASE [db1] TO DISK = ''''/b/db1.sqb'''' WITH PASSWORD = ''<masked>'', KEYSIZE = 256"'''`},
		{`@command = N'RESTORE DATABASE db1 FROM DISK = N''/b/db1.bak'' WITH MEDIAPASSWORD = <masked>''mpkey7'', REPLACE'`, `@command = N'RESTORE DATABASE db1 FROM DISK = N''/b/db1.bak'' WITH MEDIAPASSWORD = <masked>, REPLACE'`},
		{`@command = N'EXECUTE master..sqlbackup ''-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = <masked> rgkey8] "'''`, `@command = N'EXECUTE master..sqlbackup ''-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = <masked> "'''`},
		{`EXEC xp_cmdshell 'powershell -Command "Invoke-Thing -Password <masked>pw9'' -Force"'`, `EXEC xp_cmdshell 'powershell -Command "Invoke-Thing -Password <masked> -Force"'`},
		// forms the older rules did not know, stored as read
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = N'olakey10'`, `EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = '<masked>'`},
		{`EXECUTE dbo.DatabaseBackup @EncryptionKey = N'cutkey11ab`, `EXECUTE dbo.DatabaseBackup @EncryptionKey = '<masked>`},
		// masked whole by the older rules, or today's marks: as they are
		{`postgresql://agg:<masked>@db1/app`, `postgresql://agg:<masked>@db1/app`},
		{`Server=s;Password=<masked>;Encrypt=yes`, `Server=s;Password=<masked>;Encrypt=yes`},
		{`ALTER LOGIN x WITH PASSWORD = '<masked>', CHECK_POLICY = OFF`, `ALTER LOGIN x WITH PASSWORD = '<masked>', CHECK_POLICY = OFF`},
		{`bcp t out f -S s -U u -P<masked> -c`, `bcp t out f -S s -U u -P<masked> -c`},
		{`host=h password=<masked> dbname=app`, `host=h password=<masked> dbname=app`},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/x.sqb'' WITH PASSWORD = ''<masked>'', KEYSIZE = 256"'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/x.sqb'' WITH PASSWORD = ''<masked>'', KEYSIZE = 256"'`},
		{`RESTORE DATABASE db1 FROM DISK = N'/b/db1.bak' WITH MEDIAPASSWORD = <masked>, INIT`, `RESTORE DATABASE db1 FROM DISK = N'/b/db1.bak' WITH MEDIAPASSWORD = <masked>, INIT`},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] WITH PASSWORD = [<masked>] "'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] WITH PASSWORD = [<masked>] "'`},
		{`$p = ConvertTo-SecureString <masked> -AsPlainText -Force`, `$p = ConvertTo-SecureString <masked> -AsPlainText -Force`},
		// a complete mark at the closing quote of the string around it (the older key = value rule stopped at a quote):
		// as it is, the text after it kept
		{`SELECT dblink_exec('host=h user=u password=<masked>', 'VACUUM t')`, `SELECT dblink_exec('host=h user=u password=<masked>', 'VACUUM t')`},
		{`SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=s;Uid=u;Pwd=<masked>', 'SELECT 1')`, `SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=s;Uid=u;Pwd=<masked>', 'SELECT 1')`},
		{`EXEC ('SELECT * FROM OPENROWSET(''MSOLEDBSQL'', ''Server=s;Pwd=<masked>'', ''SELECT 1'')')`, `EXEC ('SELECT * FROM OPENROWSET(''MSOLEDBSQL'', ''Server=s;Pwd=<masked>'', ''SELECT 1'')')`},
		{`$cs = "Server=s;Password=<masked>"; Invoke-Sqlcmd -ConnectionString $cs -Query "SELECT 1"`, `$cs = "Server=s;Password=<masked>"; Invoke-Sqlcmd -ConnectionString $cs -Query "SELECT 1"`},
		// a doubled value an older rule took the empty literal of, its string closed after it
		{`SELECT dblink_exec('host=h password=<masked>pgk14 zz''', 'SELECT 1')`, `SELECT dblink_exec('host=h password=<masked>', 'SELECT 1')`},
		{`SELECT dblink_exec('dbname=x password=<masked>pgk15'' host=K16h', 'VACUUM')`, `SELECT dblink_exec('dbname=x password=<masked> host=K16h', 'VACUUM')`},
		// the same as the older build stored them (its T-SQL rule took the empty literal: maskred6's pk1 / pk2)
		{`SELECT dblink_exec('dbname=x password='<masked>'pgk19'' host=K16h', 'VACUUM')`, `SELECT dblink_exec('dbname=x password='<masked>' host=K16h', 'VACUUM')`},
		{`SELECT dblink_exec('host=h password='<masked>'pgk20 zz''', 'SELECT 1')`, `SELECT dblink_exec('host=h password='<masked>'', 'SELECT 1')`},
		// a bracketed key an older word rule cut at a comma, a semicolon or a parenthesis: to its ]
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = <masked>,rgk16] "'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = [/b/db1.sqb] WITH PASSWORD = <masked> "'`},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] WITH PASSWORD = <masked>;rgk17] "'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] WITH PASSWORD = <masked> "'`},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] WITH PASSWORD = <masked>)rgk18] "'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] WITH PASSWORD = <masked> "'`},
		// a role's password the older rules did not know (S16b), as a pg_cron job's script holds it
		{`ALTER ROLE app PASSWORD 'pgst1'`, `ALTER ROLE app PASSWORD '<masked>'`},
		{`SELECT cron.schedule('j', '0 0 1 1 *', 'ALTER ROLE app PASSWORD ''pgst2''');`, `SELECT cron.schedule('j', '0 0 1 1 *', 'ALTER ROLE app PASSWORD ''<masked>''');`},
		{`SELECT cron.schedule('j', '0 0 1 1 *', 'CREATE ROLE r PASSWORD $$pgst3$$');`, `SELECT cron.schedule('j', '0 0 1 1 *', 'CREATE ROLE r PASSWORD ''<masked>''');`},
	}
	for _, c := range cases {
		if got := Stored(c.in); got != c.want {
			t.Errorf("%q:\n got %q\nwant %q", c.in, got, c.want)
		}
		if c.want != c.in {
			inPrefilter(t, c.in)
		}
		if got := Stored(c.want); got != c.want {
			t.Errorf("masked again, %q changed: %q", c.want, got)
		}
	}
}

// TestStoredScript: a SQL Server Agent script an older build stored is decoded as agentScript encodes it (each
// @command literal, its quotes doubled once more): a step's command at the script's level is masked exactly as the
// step's own text; a command that still holds a key after its masking is replaced whole; the rest of the script and
// a command with nothing to mask are kept byte for byte; a script without such a literal is masked as a text.
func TestStoredScript(t *testing.T) {
	enc := func(cmd string) string { return "@command = N'" + strings.ReplaceAll(cmd, "'", "''") + "'" }
	head := "EXEC msdb.dbo.sp_add_job @job_name = N'pgvjm x', @enabled = 1\n-- step 1: Ola's step\nEXEC msdb.dbo.sp_add_jobstep @job_name = N'pgvjm x', @step_id = 1, "
	tail := ", @on_success_action = 1, @retry_attempts = 0"
	// each step's command as stored, the command masked as written out here (never computed by the code under
	// test), the key
	steps := []struct{ cmd, masked, secret string }{
		{`EXEC xp_cmdshell 'extractor.exe -F /b/db1.bak -K ''sk1'' -E db1'`, `EXEC xp_cmdshell 'extractor.exe -F /b/db1.bak -K <masked> -E db1'`, "sk1"},
		{`PRINT N'Command: EXECUTE master.dbo.xp_backup_database @database = N''master'', @encryptionkey = N''sk2''';`, `PRINT N'Command: EXECUTE master.dbo.xp_backup_database @database = N''master'', @encryptionkey = ''<masked>''';`, "sk2"},
		{`EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = N'sk3abc`, `EXECUTE dbo.DatabaseBackup @Databases = 'USER_DATABASES', @EncryptionKey = '<masked>`, "sk3"},
		{`EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/db1.sqb'' WITH PASSWORD = '<masked>'sk4'', KEYSIZE = 256"'`, `EXECUTE master..sqlbackup '-SQL "BACKUP DATABASE [db1] TO DISK = ''/b/db1.sqb'' WITH PASSWORD = '<masked>', KEYSIZE = 256"'`, "sk4"},
		{`SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=s;Uid=u;Pwd=<masked>', 'SELECT 1 AS k')`, `SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=s;Uid=u;Pwd=<masked>', 'SELECT 1 AS k')`, "sk-none"},
	}
	for _, c := range steps {
		in := head + enc(c.cmd) + tail
		got := StoredScript(in)
		if want := head + enc(c.masked) + tail; got != want {
			t.Errorf("%q:\n got %q\nwant %q", c.cmd, got, want)
		}
		if strings.Contains(got, c.secret) {
			t.Errorf("%q: the key is still there: %q", c.cmd, got)
		}
	}
	// two levels of dynamic SQL: no rule reads the key, the guard replaces the command whole
	deep := `EXEC ('EXEC (''ALTER LOGIN a WITH PASSWORD = ''''sk5'''''')')`
	if got := StoredScript(head + enc(deep) + tail); got != head+GuardedCommand+tail {
		t.Errorf("two levels deep: %q", got)
	}
	// nothing to mask: byte for byte; two commands, each its own
	plain := head + enc(`EXECUTE dbo.IndexOptimize @Databases = 'USER_DATABASES'`) + tail
	if got := StoredScript(plain); got != plain {
		t.Errorf("nothing to mask: %q", got)
	}
	two := head + enc(`EXEC dbo.p @passwd = 'sk6'`) + tail + "\n" + head + enc(`SELECT 1`) + tail
	if got := StoredScript(two); strings.Contains(got, "sk6") || !strings.Contains(got, enc(`SELECT 1`)) {
		t.Errorf("two commands: %q", got)
	}
	// the job's description: decoded and masked as a command is (the collector masks it too)
	step := "\nEXEC msdb.dbo.sp_add_jobstep @job_name = N'pgvjm d', @step_id = 1, " + enc(`SELECT 1`) + tail
	desc := "EXEC msdb.dbo.sp_add_job @job_name = N'pgvjm d', @description = N'copy: Server=s;Uid=u;Pwd=sk8;', @enabled = 1" + step
	if got, want := StoredScript(desc), "EXEC msdb.dbo.sp_add_job @job_name = N'pgvjm d', @description = N'copy: Server=s;Uid=u;Pwd=<masked>;', @enabled = 1"+step; got != want {
		t.Errorf("the description:\n got %q\nwant %q", got, want)
	}
	// not an Agent script: masked as a text
	if got := StoredScript(`SELECT cron.schedule('j', '* * * * *', $$SELECT dblink_exec('host=h password=sk7', 'SELECT 1')$$)`); strings.Contains(got, "sk7") {
		t.Errorf("a pg_cron script: %q", got)
	}
}

// TestHoldsKey: a key name followed by a value no rule masked is a key; a masked, empty, NULL or variable value is not.
func TestHoldsKey(t *testing.T) {
	for _, s := range []string{
		`ALTER LOGIN a WITH PASSWORD = ''<masked>''sk1''''''`,
		`EXECUTE dbo.DatabaseBackup @EncryptionKey = sk2`,
		`extractor.exe -F x -K <masked>sk3'''' -E db1`,
		`Server=s;Password=sk4;`,
		`WITH PASSWORD = <masked>,sk5] "'`,
		`ALTER ROLE app PASSWORD 'sk6'`,
		`CREATE ROLE r PASSWORD $$sk7$$`,
		`SELECT cron.schedule('j', '0 0 1 1 *', E'ALTER ROLE app PASSWORD E''sk8\\''x''')`,
		`DO $d$BEGIN EXECUTE E'ALTER ROLE app PASSWORD \'sk9\''; END$d$`,
	} {
		if !HoldsKey(s) {
			t.Errorf("no key found in %q", s)
		}
		inPrefilter(t, s)
	}
	for _, s := range []string{
		`ALTER LOGIN a WITH PASSWORD = '<masked>', CHECK_POLICY = OFF`,
		`PASSWORD = ''<masked>'', KEYSIZE = 256"'`,
		`WITH PASSWORD = [<masked>] "'`,
		`@EncryptionKey = '<masked>`,
		`CREATE LOGIN a WITH PASSWORD = '', CHECK_POLICY = OFF`,
		`@EncryptionKey = NULL, @Verify = 'Y'; @EncryptionKey = @key`,
		`postgresql://agg:<masked>@db1/app`,
		`bcp t out f -S s -U u -P<masked> -c`,
		`Get-ChildItem -Path D:\x -PassThru`,
		`sqlcmd -S s -E -K ReadOnly`,
		`MEDIAPASSWORD = <masked>, REPLACE`,
		`PASSWORD = <masked> "'`,
		`sqlcmd -S s -U u -Password <masked> -Q x`,
		`SELECT dblink_exec('host=h password=<masked>', 'VACUUM t')`,
		`COMMENT ON ROLE app IS 'reset the password monthly'`,
		`ALTER ROLE app PASSWORD NULL`,
		`ALTER ROLE app PASSWORD '<masked>' VALID UNTIL 'infinity'`,
		`EXECUTE format('ALTER ROLE %I PASSWORD %L', r, v_pw)`,
		"    command  => $cmd$ALTER ROLE app PASSWORD '<masked>'$cmd$,\n    database => 'postgres',",
		`DO $d$BEGIN EXECUTE E'ALTER ROLE app PASSWORD \'<masked>\''; END$d$`,
	} {
		if HoldsKey(s) {
			t.Errorf("a key found in %q", s)
		}
	}
}

// TestStoredValue: a text that still holds a key after Stored is replaced whole; one without is Stored's text.
func TestStoredValue(t *testing.T) {
	deep := `EXEC ('EXEC (''ALTER LOGIN a WITH PASSWORD = ''''sv1'''''')')`
	if got := StoredValue(deep); got != GuardedText {
		t.Errorf("two levels deep: %q", got)
	}
	inPrefilter(t, deep)
	for _, s := range []string{`SELECT 1`, `Server=s;Password=<masked>;Encrypt=yes`, `sqlcmd -S s -U u -Password <masked> -Q x`} {
		if got := StoredValue(s); got != s {
			t.Errorf("%q changed: %q", s, got)
		}
	}
	if got := StoredValue(`Server=s;Password=sv2;`); got != `Server=s;Password=<masked>;` {
		t.Errorf("masked: %q", got)
	}
	// a pg_cron script holding an escape string inside an escape string: no rule reads it, the guard does (S16b)
	esc := `SELECT cron.schedule('j', '0 0 1 1 *', E'ALTER ROLE app PASSWORD E''sv3\\''x''')`
	if got := StoredValue(esc); got != GuardedText {
		t.Errorf("an escape string inside a string: %q", got)
	}
	inPrefilter(t, esc)
	// the scripts the collector writes (cronScript, agentJobScript): a command's password last in its dollar-quoted
	// body is masked and the script stays readable, never guarded
	cron := "-- pg_cron job: j\nSELECT cron.schedule_in_database(\n    job_name => 'j',\n    schedule => '0 0 1 1 *',\n    command  => $cmd$ALTER ROLE app PASSWORD 'sv4'$cmd$,\n    database => 'postgres',\n    username => 'postgres',\n    active   => true);\n"
	if got, want := StoredValue(cron), strings.Replace(cron, "'sv4'", "'<masked>'", 1); got != want {
		t.Errorf("a pg_cron script:\n got %q\nwant %q", got, want)
	}
	agent := "DO $pgagent$\nDECLARE jid integer;\nBEGIN\nINSERT INTO pgagent.pga_jobstep (jstjobid, jstname, jstenabled, jstkind, jstdbname, jstconnstr, jstonerror, jstcode)\nVALUES (\n    jid,\n    'one',\n    true,\n    's',\n    'postgres',\n    '',\n    'f',\n    $code$ALTER ROLE app PASSWORD 'sv5'$code$);\nEND\n$pgagent$;\n"
	if got, want := StoredValue(agent), strings.Replace(agent, "'sv5'", "'<masked>'", 1); got != want {
		t.Errorf("a pgAgent script:\n got %q\nwant %q", got, want)
	}
}
