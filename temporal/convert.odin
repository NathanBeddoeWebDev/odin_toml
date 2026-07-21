package temporal

import "core:time"
import "core:time/datetime"

@(require_results)
local_date_to_datetime :: proc(value: Local_Date) -> (datetime.Date, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
local_date_from_datetime :: proc(value: datetime.Date) -> (Local_Date, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
local_time_to_datetime :: proc(value: Local_Time) -> (datetime.Time, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
local_time_from_datetime :: proc(value: datetime.Time) -> (Local_Time, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
local_date_time_to_datetime :: proc(value: Local_Date_Time) -> (datetime.DateTime, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
local_date_time_from_datetime :: proc(value: datetime.DateTime) -> (Local_Date_Time, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
offset_date_time_to_time :: proc(value: Offset_Date_Time) -> (time.Time, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
offset_date_time_from_time_utc :: proc(value: time.Time) -> (Offset_Date_Time, Error) {
	_ = value
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}

@(require_results)
offset_date_time_from_time :: proc(value: time.Time, offset: UTC_Offset) -> (Offset_Date_Time, Error) {
	_, _ = value, offset
	unimplemented("temporal conversion is scheduled for implementation ticket 4")
}
