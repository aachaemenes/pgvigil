package collect

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestNormalizeSQL(t *testing.T) {
	cases := []struct{ in, want string }{
		{"SELECT * FROM t1 WHERE id = 42 AND name = 'bob'", "SELECT * FROM t1 WHERE id = ? AND name = ?"},
		{"select col2, 3.5e10 from s.t2 where x in (1, 2,3) and y = $1", "select col2, ? from s.t2 where x in (?) and y = $1"},
		{"insert into a values (E'it''s', 'o''k', -7)", "insert into a values (?, ?, -?)"},
		{"do $body$ begin perform 1; end $body$; select $$raw 'x'$$", "do ?; select ?"},
		{"ALTER ROLE app PASSWORD '<masked>' VALID UNTIL '2030-01-01'", "ALTER ROLE app PASSWORD ? VALID UNTIL ?"},
		{"select   *\n  from  t\twhere a = 1  ", "select * from t where a = ?"},
		{"select ts - interval '1 day', 0.5 * price, ip = '10.0.0.1'::inet from o", "select ts - interval ?, ? * price, ip = ?::inet from o"},
		// review 14: shapes that desynchronised the regex chain
		{`select E'it\'s' , 'secret-1' from t`, "select ? , ? from t"},
		{"/* app: user's dashboard */ select 'secret-6' from t where a = 7", "select ? from t where a = ?"},
		{"-- don't log this\nselect 'secret-7' from t", "select ? from t"},
		{`select "it's" from t where k = 'secret-8'`, `select "it's" from t where k = ?`},
		{"select $a$ x $b$ secret-10 $a$", "select ?"},
		{"select .5, a-1, t.col3, 2.", "select ?, a-?, t.col3, ?"},
		{"/* outer /* nested 'x' */ still comment */ select 1", "select ?"},
		{"select U&'d\\0061t\\+000061' , B'1010', x'FF', n'txt' , nope'", "select ? , ?, ?, ? , nope?"},
		{"select 'unterminated and the rest is literal; select secret", "select ?"},
		{"select e from t where $2 = e", "select e from t where $2 = e"},
		{"select \"a\"\"b\" from \"we're\"", "select \"a\"\"b\" from \"we're\""},
	}
	for _, c := range cases {
		if got := normalizeSQL(c.in); got != c.want {
			t.Errorf("normalizeSQL(%q)\n got %q\nwant %q", c.in, got, c.want)
		}
	}
}

func TestApplyTextPolicy(t *testing.T) {
	mk := func() []Row {
		return []Row{
			{"kind": "session", "query": "select 1 from t where k = 'v'", "query_hash": int64(7)},
			{"kind": "session", "query": "select 1 from t where k = 'w'", "query_hash": int64(8)},
			{"kind": "event", "statement": "update t set a = 2", "detail": "Process 10: delete from t where id = 3", "pid": 10},
			{"kind": "summary", "total": 3},
			{"kind": "session", "query": nil, "query_hash": int64(9)},
		}
	}
	rows := mk()
	applyTextPolicy(rows, "full")
	if rows[0]["query"] != "select 1 from t where k = 'v'" || rows[0]["query_hash"] != int64(7) {
		t.Errorf("full changed the row: %v", rows[0])
	}
	rows = mk()
	applyTextPolicy(rows, "")
	if rows[2]["statement"] != "update t set a = 2" {
		t.Errorf("an empty mode is full: %v", rows[2]["statement"])
	}
	rows = mk()
	applyTextPolicy(rows, "normalized")
	if rows[0]["query"] != "select ? from t where k = ?" || rows[2]["statement"] != "update t set a = ?" || rows[2]["detail"] != "Process ?: delete from t where id = ?" {
		t.Errorf("normalized: %v | %v | %v", rows[0]["query"], rows[2]["statement"], rows[2]["detail"])
	}
	// the same shape with different literals shares one hash, and it is not the raw text's hash
	if rows[0]["query_hash"] != rows[1]["query_hash"] || rows[0]["query_hash"] == int64(7) {
		t.Errorf("normalized hashes: %v %v (raw 7 and 8)", rows[0]["query_hash"], rows[1]["query_hash"])
	}
	if rows[4]["query_hash"] != nil {
		t.Errorf("a session without text keeps a raw hash under normalized: %v", rows[4]["query_hash"])
	}
	if rows[2]["pid"] != 10 || rows[3]["total"] != 3 {
		t.Error("a non-text column changed")
	}
	rows = mk()
	applyTextPolicy(rows, "none")
	if rows[0]["query"] != nil || rows[2]["statement"] != nil || rows[2]["detail"] != nil || rows[0]["query_hash"] != nil {
		t.Errorf("none kept text or a hash: %v | %v", rows[0], rows[2])
	}
	if _, ok := rows[0]["query"]; !ok {
		t.Error("none should keep the column with a nil value, not drop it")
	}
}

// The log reader's rows under the policy, on the real lab batch: normalized leaves no quoted literal
// and no standalone number in any statement or detail; none leaves no text at all.
func TestTextPolicyOnLogRows(t *testing.T) {
	raw, err := os.ReadFile("testdata/aurora-lab-events.json")
	if err != nil {
		t.Fatal(err)
	}
	var rec []struct {
		S string `json:"s"`
		T int64  `json:"t"`
		M string `json:"m"`
	}
	if err := json.Unmarshal(raw, &rec); err != nil {
		t.Fatal(err)
	}
	var evs []cwEvent
	for _, r := range rec {
		evs = append(evs, cwEvent{Stream: r.S, Time: time.UnixMilli(r.T), Message: r.M})
	}
	rows := logRows(evs, "cloudwatch:/g", evs[0].Time, time.UTC, false)
	applyTextPolicy(rows, "normalized")
	literal := regexp.MustCompile(`'|(^|[^A-Za-z0-9_$.])\d`)
	texts := 0
	for _, r := range rows {
		for _, k := range []string{"statement", "detail"} {
			if s, ok := r[k].(string); ok {
				texts++
				if literal.MatchString(s) {
					t.Errorf("%s still carries a literal: %q", k, s)
				}
			}
		}
	}
	if texts == 0 {
		t.Fatal("no text rows in the fixture")
	}
	rows = logRows(evs, "cloudwatch:/g", evs[0].Time, time.UTC, false)
	applyTextPolicy(rows, "none")
	for _, r := range rows {
		if r["statement"] != nil || r["detail"] != nil {
			t.Errorf("none kept text: %v", r)
		}
	}
	if !strings.Contains(normalizeSQL("Process 1092: begin; update pgvigil_proof_7090 set v = 1"), "pgvigil_proof_7090") {
		t.Error("an identifier with digits must stay whole")
	}
}

// A corruption event keeps its detail (the server's message about the damage) under every policy, its statement
// follows the policy; a plan row loses its statement under normalized and none (plans are stored under full only).
func TestTextPolicyKindRules(t *testing.T) {
	mk := func() []Row {
		return []Row{
			{"kind": "event", "kind_of": "corruption", "statement": "SELECT * FROM t WHERE id = 42", "detail": "invalid page in block 3 of relation base/16384/24576"},
			{"kind": "event", "kind_of": "plan", "statement": "Seq Scan on t  (cost=0.00..35.50 rows=2550 width=4)\n  Filter: (id = 42)", "detail": "duration: 812.4 ms"},
			{"kind": "event", "kind_of": "slow", "statement": "SELECT * FROM t WHERE id = 42", "detail": nil},
			// a corruption event whose CONTEXT carried PL/pgSQL's SQL statement "...": the reader stores the inner SQL
			// (plain, unwrapped) above the STATEMENT line, so the normalizer masks its literal
			{"kind": "event", "kind_of": "corruption", "statement": "SELECT secret FROM accounts WHERE ssn = '123-45-6789'\nselect load_accounts()", "detail": "invalid page in block 9 of relation base/16384/16390\nCONTEXT: PL/pgSQL function load_accounts() line 4 at PERFORM"},
			// a pganalyze class: the detail is the server's message (the size and path stay), the statement follows the policy
			{"kind": "event", "kind_of": "temp_file", "statement": "SELECT * FROM big WHERE id = 42 ORDER BY v", "detail": "temporary file: path \"base/pgsql_tmp/pgsql_tmp148.1\", size 1073741824"},
		}
	}
	rows := mk()
	applyTextPolicy(rows, "full")
	if rows[1]["statement"] == nil || rows[0]["detail"] != "invalid page in block 3 of relation base/16384/24576" {
		t.Fatalf("full must change nothing: %v", rows)
	}
	rows = mk()
	applyTextPolicy(rows, "normalized")
	if rows[0]["detail"] != "invalid page in block 3 of relation base/16384/24576" {
		t.Errorf("normalized changed a corruption detail: %v", rows[0]["detail"])
	}
	if s, _ := rows[0]["statement"].(string); strings.Contains(s, "42") {
		t.Errorf("normalized kept a literal in a corruption row's statement: %q", s)
	}
	if rows[1]["statement"] != nil {
		t.Errorf("normalized kept a plan: %v", rows[1]["statement"])
	}
	if s, _ := rows[2]["statement"].(string); strings.Contains(s, "42") {
		t.Errorf("normalized kept a literal in a slow row: %q", s)
	}
	if s, _ := rows[3]["statement"].(string); strings.Contains(s, "123-45") || !strings.Contains(s, "load_accounts") {
		t.Errorf("normalized on a CONTEXT-born statement: %q", s)
	}
	if s, _ := rows[4]["statement"].(string); strings.Contains(s, "42") || rows[4]["detail"] != "temporary file: path \"base/pgsql_tmp/pgsql_tmp148.1\", size 1073741824" {
		t.Errorf("normalized on a temp_file row: statement %q detail %v", s, rows[4]["detail"])
	}
	rows = mk()
	applyTextPolicy(rows, "none")
	if rows[4]["detail"] != "temporary file: path \"base/pgsql_tmp/pgsql_tmp148.1\", size 1073741824" || rows[4]["statement"] != nil {
		t.Errorf("none: a temp_file row keeps its detail and loses its statement: %v", rows[4])
	}
	if rows[0]["detail"] != "invalid page in block 3 of relation base/16384/24576" || rows[0]["statement"] != nil {
		t.Errorf("none: a corruption row keeps its detail and loses its statement: %v", rows[0])
	}
	if rows[1]["statement"] != nil || rows[2]["statement"] != nil {
		t.Errorf("none kept statement text: %v %v", rows[1]["statement"], rows[2]["statement"])
	}
}

// review 1 of parity3 s2: an 'error' event's detail carries row values the normalizer cannot mask, and a message shape
// is not stored under none
func TestTextPolicyErrorAndMessage(t *testing.T) {
	mk := func() []Row {
		return []Row{{"kind": "event", "kind_of": "error", "statement": "insert into users values (17, 'alice@example.com')",
			"detail":  "duplicate key value violates unique constraint \"users_email_key\"\nDETAIL: Key (email)=(alice@example.com) already exists.",
			"message": `duplicate key value violates unique constraint "..."`}}
	}
	rows := mk()
	applyTextPolicy(rows, "full")
	if rows[0]["detail"] == nil || rows[0]["message"] == nil {
		t.Fatalf("full must change nothing: %v", rows[0])
	}
	rows = mk()
	applyTextPolicy(rows, "normalized")
	if rows[0]["detail"] != nil || rows[0]["message"] != `duplicate key value violates unique constraint "..."` {
		t.Errorf("normalized: detail %v, message %v", rows[0]["detail"], rows[0]["message"])
	}
	if s, _ := rows[0]["statement"].(string); strings.Contains(s, "alice") {
		t.Errorf("normalized kept a literal in an error's statement: %q", s)
	}
	rows = mk()
	applyTextPolicy(rows, "none")
	if rows[0]["detail"] != nil || rows[0]["message"] != nil || rows[0]["statement"] != nil {
		t.Errorf("none kept text: %v", rows[0])
	}
}

// the join's review: the message rule is the log events' alone; a collector_error's message is the reason the run's
// note names (a missing right, a failed read) and stays under every mode, as an AlwaysOn event's message does
func TestTextPolicyMessageOnEventsOnly(t *testing.T) {
	rows := []Row{
		{"kind": "collector_error", "source": "amcheck", "message": "permission denied for function bt_index_check"},
		{"kind": "event", "kind_of": "slow", "message": "duration: ... ms"},
	}
	applyTextPolicy(rows, "none")
	if rows[0]["message"] != "permission denied for function bt_index_check" {
		t.Errorf("none removed a collector_error's reason: %v", rows[0]["message"])
	}
	if rows[1]["message"] != nil {
		t.Errorf("none kept a log event's message: %v", rows[1]["message"])
	}
}

// Task 415: the credential mask runs under every text policy, full included, on both engines' text. Each case names
// the secret that must be gone; want, when set, is the whole masked text (the rest of the statement is kept).
func TestMaskCredentials(t *testing.T) {
	cases := []struct{ name, in, secret, want string }{
		// T-SQL: a PASSWORD / SECRET literal and a password-named parameter (MaskJobText's set, which maskText missed)
		{"tsql login", "CREATE LOGIN app WITH PASSWORD = N'Tq1secret', CHECK_POLICY = ON", "Tq1secret",
			"CREATE LOGIN app WITH PASSWORD = '<masked>', CHECK_POLICY = ON"},
		{"tsql credential", "CREATE CREDENTIAL c WITH IDENTITY = 'u', SECRET='Tq2secret'", "Tq2secret",
			"CREATE CREDENTIAL c WITH IDENTITY = 'u', SECRET='<masked>'"},
		{"tsql parameter", "EXEC sp_addlinkedsrvlogin @rmtsrvname = N'x', @rmtpassword = N'Tq3secret'", "Tq3secret",
			"EXEC sp_addlinkedsrvlogin @rmtsrvname = N'x', @rmtpassword = '<masked>'"},
		{"positional linked login", "EXEC sp_addlinkedsrvlogin 'srv', 'false', NULL, 'u', 'Ps7secret'", "Ps7secret",
			"EXEC sp_addlinkedsrvlogin '<masked>', '<masked>', NULL, '<masked>', '<masked>'"},
		{"tsql named parameter", "EXEC dbo.p @user = N'x', @password = N'Tq5secret'", "Tq5secret", "EXEC dbo.p @user = N'x', @password = '<masked>'"},
		{"tsql hashed", "CREATE LOGIN app WITH PASSWORD = 0x0200AB12CD34EF HASHED", "0x0200AB12CD34EF",
			"CREATE LOGIN app WITH PASSWORD = '<masked>' HASHED"},
		// finding 10: a statement cut by the text cap inside the literal keeps nothing of the secret
		{"tsql unterminated", "CREATE CREDENTIAL c WITH IDENTITY = 'u', SECRET = 'Tq4secretcutby", "Tq4secret",
			"CREATE CREDENTIAL c WITH IDENTITY = 'u', SECRET = '<masked>'"},
		// a command line inside a T-SQL literal: sqlcmd / bcp / osql / isql -P, the doubled-quote form (finding 10)
		{"sqlcmd -P", "EXEC xp_cmdshell 'sqlcmd -S . -U app -P Cl1secret -Q \"select 1\"'", "Cl1secret",
			"EXEC xp_cmdshell 'sqlcmd -S . -U app -P <masked> -Q \"select 1\"'"},
		{"sqlcmd -P doubled quotes", "EXEC xp_cmdshell 'sqlcmd -S . -P''Cl2secret'' -Q x'", "Cl2secret",
			"EXEC xp_cmdshell 'sqlcmd -S . -P<masked> -Q x'"},
		{"bcp -P at the end", "EXEC xp_cmdshell 'bcp db.dbo.t out f.dat -c -U app -P Cl3secret'", "Cl3secret",
			"EXEC xp_cmdshell 'bcp db.dbo.t out f.dat -c -U app -P <masked>'"},
		{"osql -P", "osql -E -S . -P Cl4secret", "Cl4secret", "osql -E -S . -P <masked>"},
		{"SQLCMDPASSWORD with spaces", "SET SQLCMDPASSWORD = Cl5secret && sqlcmd -S .", "Cl5secret",
			"SET SQLCMDPASSWORD = <masked> && sqlcmd -S ."},
		{"SQLCMDPASSWORD bare", "SQLCMDPASSWORD=Cl6secret sqlcmd -S .", "Cl6secret", "SQLCMDPASSWORD=<masked> sqlcmd -S ."},
		// connection strings and URIs
		{"connection string", "SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=x;UID=sa;PWD=Cs1secret;', 'SELECT 1')", "Cs1secret",
			"SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=x;UID=sa;PWD=<masked>;', 'SELECT 1')"},
		{"uri", "select dblink('postgresql://app:Cs2secret@db/x', 'select 1')", "Cs2secret",
			"select dblink('postgresql://app:<masked>@db/x', 'select 1')"},
		{"libpq keyword", "select dblink_connect('host=h user=u password=Cs3secret dbname=d')", "Cs3secret",
			"select dblink_connect('host=h user=u password=<masked> dbname=d')"},
		// SQL Server passphrase functions with a literal
		{"encryptbypassphrase", "SELECT ENCRYPTBYPASSPHRASE('Pp1secret', N'data') FROM t", "Pp1secret",
			"SELECT ENCRYPTBYPASSPHRASE('<masked>', '<masked>') FROM t"},
		{"decryptbypassphrase N", "select DecryptByPassPhrase(N'Pp2secret', c) from t", "Pp2secret",
			"select DecryptByPassPhrase('<masked>', c) from t"},
		{"passphrase variable stays", "SELECT ENCRYPTBYPASSPHRASE(@p, @x)", "", "SELECT ENCRYPTBYPASSPHRASE(@p, @x)"},
		// PostgreSQL: roles, pgcrypto with every literal form (finding 10)
		{"pg role", "ALTER ROLE app PASSWORD 'Pg1secret' VALID UNTIL 'infinity'", "Pg1secret",
			"ALTER ROLE app PASSWORD '<masked>' VALID UNTIL 'infinity'"},
		{"pg role escape", "CREATE ROLE a LOGIN ENCRYPTED PASSWORD E'Pg2\\'secret'", "Pg2", "CREATE ROLE a LOGIN ENCRYPTED PASSWORD '<masked>'"},
		{"pgp_sym_encrypt", "select pgp_sym_encrypt('data', 'Pg3secret')", "Pg3secret", "select pgp_sym_encrypt('<masked>', '<masked>')"},
		{"pgp dollar quote", "select pgp_sym_decrypt(col, $k$Pg4secret$k$) from t", "Pg4secret", "select pgp_sym_decrypt(col, '<masked>') from t"},
		{"encrypt E''", "select encrypt('d'::bytea, E'Pg5secret'::bytea, 'aes')", "Pg5secret",
			"select encrypt('<masked>'::bytea, '<masked>'::bytea, '<masked>')"},
		{"crypt", "select crypt('Pg6secret', gen_salt('bf'))", "Pg6secret", "select crypt('<masked>', gen_salt('<masked>'))"},
		{"hmac nested", "SELECT HMAC(convert_to(x, 'UTF8'), 'Pg7secret', 'sha256') FROM t", "Pg7secret",
			"SELECT HMAC(convert_to(x, '<masked>'), '<masked>', '<masked>') FROM t"},
		{"pgcrypto unterminated", "select pgp_sym_encrypt('data', 'Pg8secretcut", "Pg8secret", "select pgp_sym_encrypt('<masked>', '<masked>'"},
		// private key blocks: whole, or from BEGIN to the end of a text cut before END
		{"pgp block", "select dearmor('-----BEGIN PGP PRIVATE KEY BLOCK-----\nKb1secret\n-----END PGP PRIVATE KEY BLOCK-----') as k",
			"Kb1secret", "select dearmor('<masked>') as k"},
		{"pgp block cut", "select length('-----BEGIN PGP PRIVATE KEY BLOCK----- Kb2secret xxxxxxxx", "Kb2secret", "select length('<masked>"},
		{"pem key", "-----BEGIN RSA PRIVATE KEY-----\nKb3secret\n-----END RSA PRIVATE KEY----- after", "Kb3secret", "<masked> after"},
		// the PowerShell and Windows forms MaskJobText covers
		{"securestring", "ConvertTo-SecureString 'Ps1secret' -AsPlainText -Force", "Ps1secret", "ConvertTo-SecureString <masked> -AsPlainText -Force"},
		{"net use", `net use \\h\s Ps2secret /user:u`, "Ps2secret", `net use \\h\s <masked> /user:u`},
		// nothing to mask: text unchanged (a column whose name holds 'password' compared with a column, not a literal)
		{"plain", "SELECT a, b FROM t WHERE k = 'value' AND n = 3", "", "SELECT a, b FROM t WHERE k = 'value' AND n = 3"},
		{"loginproperty", "SELECT LOGINPROPERTY(name, 'PasswordLastSetTime') FROM sys.sql_logins", "",
			"SELECT LOGINPROPERTY(name, 'PasswordLastSetTime') FROM sys.sql_logins"},
		// the 415 review, finding 3: a value in T-SQL's doubled quotes inside a literal is one value
		{"doubled SQLCMDPASSWORD", "EXEC xp_cmdshell 'set SQLCMDPASSWORD=''od3 secret'' && sqlcmd -S .'", "od3",
			"EXEC xp_cmdshell 'set SQLCMDPASSWORD=''<masked>'' && sqlcmd -S .'"},
		{"doubled PWD", "SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=x;UID=sa;PWD=''od1;secret'';', 'SELECT 1')", "od1",
			"SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=x;UID=sa;PWD=''<masked>'';', 'SELECT 1')"},
		{"doubled provstr", "EXEC sp_addlinkedserver @server = N'x', @provstr = N'Server=y;Password=''od2 secret'''", "od2",
			"EXEC sp_addlinkedserver @server = N'x', @provstr = N'Server=y;Password=''<masked>'''"},
		{"doubled libpq", "select dblink('host=h password=''dq15secret'' dbname=d', 'select 1')", "dq15secret",
			"select dblink('host=h password=''<masked>'' dbname=d', 'select 1')"},
		{"doubled -Password", `EXEC xp_cmdshell 'powershell -c "Invoke-Sqlcmd -Password ''od5secret'' -Query x"'`, "od5secret",
			`EXEC xp_cmdshell 'powershell -c "Invoke-Sqlcmd -Password <masked> -Query x"'`},
		// finding 4: the quote that closes the enclosing literal never starts a value
		{"closing quote 1", "UPDATE t SET kind = 'password' WHERE id = 5", "", "UPDATE t SET kind = 'password' WHERE id = 5"},
		{"closing quote 2", "SELECT * FROM t WHERE auth_method = 'password' OR auth_method = 'md5'", "",
			"SELECT * FROM t WHERE auth_method = 'password' OR auth_method = 'md5'"},
		{"closing quote 3", "SELECT 'Reset your password' AS msg, name FROM users WHERE id = 3", "",
			"SELECT 'Reset your password' AS msg, name FROM users WHERE id = 3"},
		{"closing quote 4", "select dblink_connect('host=h password=') , 'abc'", "", "select dblink_connect('host=h password=') , 'abc'"},
		// finding 5: a named argument (a plan's parameter values are MaskXML's: TestMaskXML)
		{"named argument", "SELECT app.set_password(p_user => 'u', p_password => 'na1secret')", "na1secret",
			"SELECT app.set_password(p_user => 'u', p_password => '<masked>')"},
		// finding 6: no false positives on arithmetic, -Path or a cast
		{"arithmetic", "SELECT Total -Paid AS due FROM inv", "", "SELECT Total -Paid AS due FROM inv"},
		{"powershell -Path", `EXEC xp_cmdshell 'powershell Get-ChildItem -Path C:\x'`, "", `EXEC xp_cmdshell 'powershell Get-ChildItem -Path C:\x'`},
		{"cast", "SELECT password::text, name FROM t", "", "SELECT password::text, name FROM t"},
		// finding 7: the certificate and key functions, KEY_SOURCE / IDENTITY_VALUE, positional procedure calls
		{"decryptbycert", "SELECT DECRYPTBYCERT(CERT_ID('c'), ct, N'Cp1secret') FROM t", "Cp1secret",
			"SELECT DECRYPTBYCERT(CERT_ID('<masked>'), ct, '<masked>') FROM t"},
		{"open key", "OPEN SYMMETRIC KEY k DECRYPTION BY PASSWORD = 'Cp2secret'", "Cp2secret", "OPEN SYMMETRIC KEY k DECRYPTION BY PASSWORD = '<masked>'"},
		{"key source", "CREATE SYMMETRIC KEY k WITH KEY_SOURCE = 'Cp3secret', IDENTITY_VALUE = 'Cp4secret', ALGORITHM = AES_256", "secret",
			"CREATE SYMMETRIC KEY k WITH KEY_SOURCE = '<masked>', IDENTITY_VALUE = '<masked>', ALGORITHM = AES_256"},
		{"sp_addlogin", "EXEC sp_addlogin 'appuser', 'Cp5secret'\nSELECT 'kept'", "Cp5secret", "EXEC sp_addlogin '<masked>', '<masked>'\nSELECT 'kept'"},
		{"sp_password", "EXEC sp_password NULL, 'Cp6secret', 'u'", "Cp6secret", "EXEC sp_password NULL, '<masked>', '<masked>'"},
		{"multi-byte", "SELECT N'Grüße', ENCRYPTBYPASSPHRASE('Mb1secrét', N'ünïcode')", "Mb1", "SELECT N'Grüße', ENCRYPTBYPASSPHRASE('<masked>', '<masked>')"},
		{"dynamic sql", "EXEC (N'SELECT ENCRYPTBYPASSPHRASE(''Dy1secret'', x) FROM t; ALTER LOGIN a WITH PASSWORD = ''Dy2secret''')", "Dy",
			"EXEC (N'SELECT ENCRYPTBYPASSPHRASE(''<masked>'', x) FROM t; ALTER LOGIN a WITH PASSWORD = ''<masked>''')"},
	}
	for _, c := range cases {
		got := MaskCredentials(c.in)
		if c.secret != "" && strings.Contains(got, c.secret) {
			t.Errorf("%s: the secret %q is still there: %q", c.name, c.secret, got)
		}
		if c.want != "" && got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
		if again := MaskCredentials(got); again != got {
			t.Errorf("%s: a second pass changed the text: %q -> %q", c.name, got, again)
		}
	}
}

// TestMaskXML: the credential mask of an XML document (a showplan, a deadlock graph, a blocked process report) masks
// each attribute value and text node and writes <masked> escaped, so the document stays XML (the join of 406's plans
// with 415's mask: the text mask wrote a raw <masked> there); CDATA and comments are masked as raw text; a document with
// no credential keeps its bytes; a second pass changes nothing; the stored row takes MaskXML for an XML value only.
func TestMaskXML(t *testing.T) {
	cases := []struct{ name, in, secret, want string }{
		{"plan parameters", `<ColumnReference Column="@password" ParameterDataType="nvarchar(50)" ParameterCompiledValue="N'Plan1secret'" ParameterRuntimeValue="N&apos;Plan2secret&apos;" />`, "Plan",
			`<ColumnReference Column="@password" ParameterDataType="nvarchar(50)" ParameterCompiledValue="&apos;&lt;masked&gt;&apos;" ParameterRuntimeValue="&apos;&lt;masked&gt;&apos;" />`},
		{"another parameter kept", `<ColumnReference Column="@user" ParameterCompiledValue="N&apos;Plan3keep&apos;" />`, "",
			`<ColumnReference Column="@user" ParameterCompiledValue="N&apos;Plan3keep&apos;" />`},
		{"attribute", `<StmtSimple StatementText="ALTER LOGIN a WITH PASSWORD = &apos;Ax1secret&apos;&#xA;GO" StatementId="1" />`, "Ax1secret",
			`<StmtSimple StatementText="ALTER LOGIN a WITH PASSWORD = &apos;&lt;masked&gt;&apos;&#xA;GO" StatementId="1" />`},
		{"an already masked pair", `<StmtSimple StatementText="UPDATE u SET PasswordHash = &lt;masked&gt; WHERE id = @id" />`, "",
			`<StmtSimple StatementText="UPDATE u SET PasswordHash = &lt;masked&gt; WHERE id = @id" />`},
		{"text node", "<inputbuf>\nEXEC xp_cmdshell &apos;sqlcmd -S . -P Tx1secret -Q x&apos;   </inputbuf>", "Tx1secret",
			"<inputbuf>\nEXEC xp_cmdshell 'sqlcmd -S . -P &lt;masked&gt; -Q x'   </inputbuf>"},
		{"cdata", "<x><![CDATA[Server=s;PWD=Cd1secret;]]><!-- password=Cm1secret --></x>", "1secret",
			"<x><![CDATA[Server=s;PWD=<masked>;]]><!-- password=<masked> --></x>"},
		{"no credential", "<?xml version=\"1.0\"?>\n<deadlock><process id=\"p1\" note='a &amp; b'><inputbuf>SELECT N&apos;x&apos; &lt; 2</inputbuf></process></deadlock>", "",
			"<?xml version=\"1.0\"?>\n<deadlock><process id=\"p1\" note='a &amp; b'><inputbuf>SELECT N&apos;x&apos; &lt; 2</inputbuf></process></deadlock>"},
		{"cut inside a tag", `<a><StmtSimple StatementText="ALTER LOGIN a WITH PASSWORD = &apos;Ct1secr`, "Ct1secr", ""},
	}
	for _, c := range cases {
		got := MaskXML(c.in)
		if c.secret != "" && strings.Contains(got, c.secret) {
			t.Errorf("%s: the secret %q is still there: %q", c.name, c.secret, got)
		}
		if c.want != "" && got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", c.name, got, c.want)
		}
		if again := MaskXML(got); again != got {
			t.Errorf("%s: a second pass changed the text: %q -> %q", c.name, got, again)
		}
	}
	// the row: an XML value takes MaskXML, a statement MaskCredentials (its <masked> raw), PostgreSQL's <IDLE> stays
	rows := []Row{{"graph": "<deadlock><inputbuf>PWD=Rg1secret;</inputbuf></deadlock>", "statement": "ALTER LOGIN a WITH PASSWORD = 'Rs1secret'", "query": "<IDLE>"}}
	ApplyTextPolicy(rows, "full")
	if g := rows[0]["graph"]; g != "<deadlock><inputbuf>PWD=&lt;masked&gt;;</inputbuf></deadlock>" {
		t.Errorf("graph: %q", g)
	}
	if st := rows[0]["statement"]; st != "ALTER LOGIN a WITH PASSWORD = '<masked>'" {
		t.Errorf("statement: %q", st)
	}
	if q := rows[0]["query"]; q != "<IDLE>" {
		t.Errorf("query: %q", q)
	}
}

// Task 415 (408 pass finding 1): under full, the default, the text keys of every row are masked on the way to the
// repository; normalized and none keep their own rules after the mask.
func TestApplyTextPolicyMasksUnderEveryMode(t *testing.T) {
	mk := func() []Row {
		return []Row{
			{"kind": "request", "statement": "SELECT 1 WHERE N'sqlcmd -S . -P Rw1secret' <> name", "session_id": 52},
			{"kind": "session", "query": "select pgp_sym_encrypt('d', 'Rw2secret')", "query_hash": int64(5)},
			{"kind": "event", "statement": "ALTER LOGIN a WITH PASSWORD = 'Rw3secret'", "detail": "Process 9: CREATE CREDENTIAL c WITH IDENTITY = 'u', SECRET = 'Rw4secret'"},
			{"kind": "slow", "statement": "exec p @password = N'Rw5secret'", "shape": "p"},
			{"kind": "collector_error", "message": "login failed: password=Rw6secret"},
			{"kind": "plan_xml", "kind_of": "plan", "statement": "<StmtSimple StatementText=\"SELECT ENCRYPTBYPASSPHRASE('Rw7secret', x)\"/>"},
			// the 415 review, finding 1: a deadlock graph and a blocked process report hold the input buffers
			{"kind": "deadlock", "graph": "<deadlock><process-list><process id=\"p1\" spid=\"55\"><inputbuf>EXEC xp_cmdshell 'sqlcmd -S . -U app -P Rw8secret -Q x'</inputbuf></process></process-list></deadlock>"},
			{"kind": "blocked", "report": "<blocked-process-report><blocked-process><process spid=\"60\"><inputbuf>SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=x;UID=sa;PWD=Rw9secret;', 'SELECT 1')</inputbuf></process></blocked-process></blocked-process-report>"},
			// finding 2: a plan's text and every string of its JSON form
			{"kind": "plan", "query": "select pgp_sym_decrypt(data, 'RwAsecret') from t", "plan_text": "Seq Scan on t\n  Filter: (pgp_sym_decrypt(data, 'RwBsecret'::text) IS NOT NULL)",
				"plan": map[string]any{"Plan": map[string]any{"Node Type": "Seq Scan", "Filter": "(pgp_sym_decrypt(data, 'RwCsecret'::text) IS NOT NULL)", "Plans": []any{map[string]any{"Output": []any{"crypt('RwDsecret', x)"}}}}}},
		}
	}
	secrets := []string{"Rw1secret", "Rw2secret", "Rw3secret", "Rw4secret", "Rw5secret", "Rw6secret", "Rw7secret", "Rw8secret", "Rw9secret", "RwAsecret", "RwBsecret", "RwCsecret", "RwDsecret"}
	for _, mode := range []string{"", "full", "normalized", "none"} {
		rows := mk()
		applyTextPolicy(rows, mode)
		b, _ := json.Marshal(rows)
		for _, s := range secrets {
			if strings.Contains(string(b), s) {
				t.Errorf("mode %q: %s survived: %s", mode, s, b)
			}
		}
		if rows[0]["session_id"] != 52 || rows[3]["shape"] != "p" {
			t.Errorf("mode %q: a non-text column changed: %v %v", mode, rows[0]["session_id"], rows[3]["shape"])
		}
	}
	rows := mk()
	applyTextPolicy(rows, "full")
	if rows[0]["statement"] != "SELECT 1 WHERE N'sqlcmd -S . -P <masked>' <> name" || rows[1]["query_hash"] != int64(5) {
		t.Errorf("full: the rest of the text or the server's hash changed: %v | %v", rows[0]["statement"], rows[1]["query_hash"])
	}
}

// the 415 review, finding 8: the mask is linear in the text - a 1 MB text with 16,000 password literals well under a
// second (it was 3.8 s when every match recounted the runes before it)
func TestMaskCredentialsCost(t *testing.T) {
	var b strings.Builder
	for b.Len() < 1<<20 {
		b.WriteString("ALTER LOGIN a WITH PASSWORD = 'Cs9secret'; SELECT N'ünïcode', x FROM t; ")
	}
	start := time.Now()
	out := MaskCredentials(b.String())
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("1 MB took %v", d)
	}
	if strings.Contains(out, "Cs9secret") {
		t.Error("a secret survived")
	}
}
