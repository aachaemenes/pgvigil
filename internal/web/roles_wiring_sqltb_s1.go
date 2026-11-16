package web

// B24f's join wiring for rel-sqltb-s1 (the lead 11-15 16:3x): the refusal words of its write, kept beside roles.go's
// routeWhat in a file of their own so each branch's wiring touches no line another branch's does
func init() {
	routeWhat["POST /api/mssql/counteradmin"] = "changing a SQL Server counter list"
}
