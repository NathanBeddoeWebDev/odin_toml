package temporal

compare :: proc {
	compare_local_date,
	compare_local_time,
	compare_local_date_time,
}

@(require_results)
compare_local_date :: proc(a, b: Local_Date) -> (ordering: int, err: Error) {
	_, _ = a, b
	unimplemented("temporal comparison is scheduled for implementation ticket 4")
}

@(require_results)
compare_local_time :: proc(a, b: Local_Time) -> (ordering: int, err: Error) {
	_, _ = a, b
	unimplemented("temporal comparison is scheduled for implementation ticket 4")
}

@(require_results)
compare_local_date_time :: proc(a, b: Local_Date_Time) -> (ordering: int, err: Error) {
	_, _ = a, b
	unimplemented("temporal comparison is scheduled for implementation ticket 4")
}

@(require_results)
compare_instant :: proc(a, b: Offset_Date_Time) -> (ordering: int, err: Error) {
	_, _ = a, b
	unimplemented("temporal comparison is scheduled for implementation ticket 4")
}
