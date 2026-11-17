package actions

// Allows says whether this PostgreSQL instance's actions: list names kind (task 7b: save_table is the first entry of
// the list that is not a job action; review-29 N9: the Door carried no list).
//
// RED STUB: answers false for every kind; task 7b's build gives the Door the instance's list.
func (d Door) Allows(kind string) bool { return false }
