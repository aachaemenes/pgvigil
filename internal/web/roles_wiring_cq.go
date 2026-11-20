package web

// B24f's join wiring for the request queue's cancel: the refusal words of its write, kept beside roles.go's routeWhat
// in a file of their own so each branch's wiring touches no line another branch's does
func init() {
	routeWhat["POST /api/requests/{id}/cancel"] = "cancelling a queued request"
}
