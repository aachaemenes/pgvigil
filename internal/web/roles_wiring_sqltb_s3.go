package web

// B24f's join wiring for rel-sqltb-s3: the refusal words of its writes, kept beside roles.go's
// routeWhat in a file of their own so each branch's wiring touches no line another branch's does
func init() {
	routeWhat["POST /api/mssql/stats/histogram"] = "reading a statistic's histogram"
	routeWhat["POST /api/mssql/indexes/fragmentation"] = "reading index fragmentation"
	routeWhat["POST /api/mssql/indexes/fragmentation/cost"] = "reading the heap size before a fragmentation read"
	routeWhat["POST /api/mssql/indexes/fragmentation/cancel"] = "cancelling a fragmentation read"
}
