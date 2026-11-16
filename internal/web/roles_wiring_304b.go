package web

// B24f's join wiring for rel-304b / rel-inv: the refusal words of their writes, kept beside
// roles.go's routeWhat in a file of their own so each branch's wiring touches no line another branch's does
func init() {
	routeWhat["POST /api/mssql/actions/verify/preview"] = "reading a backup to verify"
	routeWhat["POST /api/mssql/actions/verify/run"] = "verifying a backup"
	routeWhat["POST /api/pg/backup_dest"] = "entering where the backups go"
}
