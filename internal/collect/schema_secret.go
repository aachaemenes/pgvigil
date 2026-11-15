package collect

// In a file of its own (not schema.go) so a build can put main's schema.go back beside it: SQL Server's schema
// collection uses it too.

import "regexp"

// schemaSecretRE is the DDL log's own test (pgvigil_ddl_capture, schema.go): a body it matches may carry a password, so its
// text is never kept, under any policy - the hashed form alone, with SchemaBodyWithheld after it. The masks (maskBody)
// stay for the bodies it does not match.
var schemaSecretRE = regexp.MustCompile(`(?i)(password|secret|pwd|://[^\s/@]*:[^\s/@]*@|(create|alter)\s+(server|user\s+mapping|subscription))`)

// SchemaBodyWithheld is the line stored after a body's hash when its text names a password or a secret.
const SchemaBodyWithheld = "(body text not kept: it names a password or a secret)"

// SchemaBodyNamesSecret says whether a body's text matches the DDL log's test (schemaSecretRE); SQL Server's schema
// collection uses it too.
func SchemaBodyNamesSecret(s string) bool { return schemaSecretRE.MatchString(s) }
