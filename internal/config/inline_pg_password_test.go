package config

import "testing"

// TestHasInlinePGPassword (L181 / L9; rn-2's difference): a PostgreSQL connection string's inline password is seen in
// both of libpq's forms - the keyword/value string's password keyword (quoted or bare, never a word inside another
// value) and the URL's userinfo or password= query - and an empty one, a passfile or no password at all is not one.
func TestHasInlinePGPassword(t *testing.T) {
	for _, c := range []struct {
		dsn  string
		want bool
	}{
		{"host=h port=5432 user=u password=zz dbname=d sslmode=disable", true},
		{"host=h user=u dbname=d", false},
		{"host=h password='' dbname=d", false},
		{"password=", false},
		{"host=h password = 'a b' connect_timeout=3", true},
		{"host=h PASSWORD=zz", true},
		{`host=h password='it\'s' dbname=d`, true},
		{"host=h passfile=/etc/pgvigil/pgpass user=u", false},
		{"application_name='my password=fake' host=h user=u", false},
		{"postgres://u:pw@h:5432/db", true},
		{"postgres://u@h/db", false},
		{"postgresql://h/db?password=x", true},
		{"postgresql://h/db?sslmode=require", false},
		{"", false},
		// rn-l181 S3: a '://' inside a value or inside the password is no URL (libpq decides by the prefix)
		{"host=db user=u password=pw application_name=svc://collector", true},
		{"password=a://b host=db", true},
		{"host=db application_name=svc://collector user=u", false},
		// rn-l9 N1: an empty password is none, in the URL's userinfo or its query
		{"postgres://u:@h/db", false},
		{"postgresql://h/db?password=", false},
		{"host=db password=s3cret application_name=http://x", true},
	} {
		if got := HasInlinePGPassword(c.dsn); got != c.want {
			t.Errorf("HasInlinePGPassword(%q) = %v, want %v", c.dsn, got, c.want)
		}
	}
}
