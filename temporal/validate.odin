package temporal

validate :: proc {
	validate_local_date,
	validate_local_time,
	validate_local_date_time,
	validate_utc_offset,
	validate_offset_date_time,
}

@(require_results)
validate_local_date :: proc(value: Local_Date) -> Error {
	_ = value
	unimplemented("temporal validation is scheduled for implementation ticket 4")
}

@(require_results)
validate_local_time :: proc(value: Local_Time) -> Error {
	_ = value
	unimplemented("temporal validation is scheduled for implementation ticket 4")
}

@(require_results)
validate_local_date_time :: proc(value: Local_Date_Time) -> Error {
	_ = value
	unimplemented("temporal validation is scheduled for implementation ticket 4")
}

@(require_results)
validate_utc_offset :: proc(value: UTC_Offset) -> Error {
	_ = value
	unimplemented("temporal validation is scheduled for implementation ticket 4")
}

@(require_results)
validate_offset_date_time :: proc(value: Offset_Date_Time) -> Error {
	_ = value
	unimplemented("temporal validation is scheduled for implementation ticket 4")
}
