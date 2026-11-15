package config

// MSSQLSchema is a sqlserver instance's mssql_schema block (task A26): the databases whose schema history the
// collection mssql_schema keeps - '*' every user database, a name that one, '-name' leaves one out. No block = the
// collection is off on the instance. Placed on Instance by the A26 wiring patch.
type MSSQLSchema struct {
	Databases []string `yaml:"databases"`
}
