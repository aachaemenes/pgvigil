package config

import (
	"strings"
	"testing"
)

// password_secret (task B24e): its reference and region; refused beside a dsn password (URL, ADO and libpq keyword
// forms, through env:) or an Entra / Windows sign-in.
func TestPasswordSecretBlock(t *testing.T) {
	t.Setenv("PGV_TEST_DSN_KW", "host=h user=u password=p dbname=d")
	t.Setenv("PGV_TEST_DSN_OK", "host=h user=u dbname=d")
	cfg := func(engine, dsn string, ps *PasswordSecret) Config {
		return Config{Repository: Repository{DSNRaw: "r"}, Instances: []Instance{{Name: "a", Engine: engine, DSNRaw: dsn, PasswordSecret: ps}}}
	}
	ok := &PasswordSecret{Ref: "aws-secretsmanager:pgvigil/read", Region: "us-east-2"}
	cases := []struct {
		what   string
		c      Config
		refuse string
	}{
		{"postgres, env dsn without a password", cfg(EnginePostgres, "env:PGV_TEST_DSN_OK", ok), ""},
		{"sqlserver URL without a password", cfg(EngineSQLServer, "sqlserver://u@h:1433?database=d", ok), ""},
		{"an ARN without a region", cfg(EnginePostgres, "env:PGV_TEST_DSN_OK", &PasswordSecret{Ref: "aws-secretsmanager:arn:aws:secretsmanager:us-east-2:1:secret:x"}), ""},
		{"no region", cfg(EnginePostgres, "env:PGV_TEST_DSN_OK", &PasswordSecret{Ref: "aws-secretsmanager:x"}), "region"},
		{"a bad reference", cfg(EnginePostgres, "env:PGV_TEST_DSN_OK", &PasswordSecret{Ref: "secret:x", Region: "us-east-2"}), "aws-secretsmanager:"},
		{"a libpq keyword password through env:", cfg(EnginePostgres, "env:PGV_TEST_DSN_KW", ok), "carries a password"},
		{"fedauth", cfg(EngineSQLServer, "sqlserver://u@h:1433?database=d&fedauth=ActiveDirectoryServicePrincipal", ok), "fedauth"},
	}
	for _, c := range cases {
		err := c.c.Validate()
		switch {
		case c.refuse == "" && err != nil:
			t.Errorf("%s: refused: %v", c.what, err)
		case c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)):
			t.Errorf("%s: %v, want a refusal naming %q", c.what, err, c.refuse)
		}
	}
}
