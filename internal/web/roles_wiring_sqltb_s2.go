package web

// B24f's join wiring for rel-sqltb-s2: the refusal words of its writes, kept beside roles.go's
// routeWhat in a file of their own so each branch's wiring touches no line another branch's does
func init() {
	routeWhat["POST /api/alertwindows"] = "changing an alert window"
	routeWhat["POST /api/mssql/security/config"] = "changing a SQL Server security setting"
	routeWhat["POST /api/mssql/xecaptures/config"] = "changing an XE capture setting"
}
