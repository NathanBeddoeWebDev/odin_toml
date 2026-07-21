package temporal

import "core:time"
import "core:time/datetime"

@(private)
validate_datetime_date :: proc "contextless" (value: datetime.Date) -> Error {
	if value.year < 0 || value.year > 9999 {
		return .Invalid_Year
	}
	if value.month < 1 || value.month > 12 {
		return .Invalid_Month
	}
	month := u8(value.month)
	if value.day < 1 || value.day > i8(days_in_month(u16(value.year), month)) {
		return .Invalid_Day
	}
	return .None
}

@(private)
validate_datetime_time :: proc "contextless" (value: datetime.Time) -> Error {
	if value.hour < 0 || value.hour > 23 {
		return .Invalid_Hour
	}
	if value.minute < 0 || value.minute > 59 {
		return .Invalid_Minute
	}
	if value.second < 0 || value.second > 59 {
		return .Invalid_Second
	}
	if value.nano < 0 || value.nano >= 1_000_000_000 {
		return .Invalid_Nanosecond
	}
	return .None
}

@(require_results)
local_date_to_datetime :: proc(value: Local_Date) -> (datetime.Date, Error) {
	if err := validate_local_date(value); err != .None {
		return {}, err
	}
	return {i64(value.year), i8(value.month), i8(value.day)}, .None
}

@(require_results)
local_date_from_datetime :: proc(value: datetime.Date) -> (Local_Date, Error) {
	if err := validate_datetime_date(value); err != .None {
		return {}, err
	}
	return {u16(value.year), u8(value.month), u8(value.day)}, .None
}

@(require_results)
local_time_to_datetime :: proc(value: Local_Time) -> (datetime.Time, Error) {
	if err := validate_local_time(value); err != .None {
		return {}, err
	}
	if value.second == 60 {
		return {}, .Unsupported_Leap_Second
	}
	return {i8(value.hour), i8(value.minute), i8(value.second), i32(value.nanosecond)}, .None
}

@(require_results)
local_time_from_datetime :: proc(value: datetime.Time) -> (Local_Time, Error) {
	if err := validate_datetime_time(value); err != .None {
		return {}, err
	}
	return {u8(value.hour), u8(value.minute), u8(value.second), u32(value.nano)}, .None
}

@(require_results)
local_date_time_to_datetime :: proc(value: Local_Date_Time) -> (datetime.DateTime, Error) {
	if err := validate_local_date_time(value); err != .None {
		return {}, err
	}
	if value.time.second == 60 {
		return {}, .Unsupported_Leap_Second
	}
	return {
		{i64(value.date.year), i8(value.date.month), i8(value.date.day)},
		{i8(value.time.hour), i8(value.time.minute), i8(value.time.second), i32(value.time.nanosecond)},
		nil,
	}, .None
}

@(require_results)
local_date_time_from_datetime :: proc(value: datetime.DateTime) -> (Local_Date_Time, Error) {
	if err := validate_datetime_date(value.date); err != .None {
		return {}, err
	}
	if err := validate_datetime_time(value.time); err != .None {
		return {}, err
	}
	if value.tz != nil {
		return {}, .Timezone_Not_Local
	}
	return {
		{u16(value.year), u8(value.month), u8(value.day)},
		{u8(value.hour), u8(value.minute), u8(value.second), u32(value.nano)},
	}, .None
}

@(private)
local_ordinal :: proc "contextless" (value: Local_Date) -> datetime.Ordinal {
	return datetime.unsafe_date_to_ordinal({i64(value.year), i8(value.month), i8(value.day)})
}

@(private)
epoch_ordinal :: proc "contextless" () -> datetime.Ordinal {
	return datetime.unsafe_date_to_ordinal({1970, 1, 1})
}

@(private)
floor_divmod_i128 :: proc "contextless" (numerator, denominator: i128) -> (quotient, remainder: i128) {
	quotient = numerator / denominator
	remainder = numerator % denominator
	if remainder < 0 {
		quotient -= 1
		remainder += denominator
	}
	return
}

@(require_results)
offset_date_time_to_time :: proc(value: Offset_Date_Time) -> (time.Time, Error) {
	if err := validate_offset_date_time(value); err != .None {
		return {}, err
	}
	if value.local.time.second == 60 {
		return {}, .Unsupported_Leap_Second
	}

	day_difference := i128(local_ordinal(value.local.date) - epoch_ordinal())
	seconds := day_difference * 86_400 +
	           i128(value.local.time.hour) * 3600 +
	           i128(value.local.time.minute) * 60 +
	           i128(value.local.time.second) -
	           i128(value.offset.minutes) * 60
	nanoseconds := seconds * 1_000_000_000 + i128(value.local.time.nanosecond)
	if nanoseconds < i128(-9_223_372_036_854_775_808) ||
	   nanoseconds > i128(9_223_372_036_854_775_807) {
		return {}, .Out_Of_Range
	}
	return time.from_nanoseconds(i64(nanoseconds)), .None
}

@(require_results)
offset_date_time_from_time_utc :: proc(value: time.Time) -> (Offset_Date_Time, Error) {
	return offset_date_time_from_time(value, {.Known, 0})
}

@(require_results)
offset_date_time_from_time :: proc(
	value: time.Time,
	offset: UTC_Offset,
) -> (Offset_Date_Time, Error) {
	if err := validate_utc_offset(offset); err != .None {
		return {}, err
	}

	NANOSECONDS_PER_DAY :: i128(86_400_000_000_000)
	local_nanoseconds := i128(time.time_to_unix_nano(value)) +
	                     i128(offset.minutes) * 60_000_000_000
	day_difference, day_nanoseconds := floor_divmod_i128(
		local_nanoseconds,
		NANOSECONDS_PER_DAY,
	)
	ordinal_i128 := i128(epoch_ordinal()) + day_difference
	if ordinal_i128 < i128(datetime.MIN_ORD) || ordinal_i128 > i128(datetime.MAX_ORD) {
		return {}, .Out_Of_Range
	}
	date, date_err := datetime.ordinal_to_date(datetime.Ordinal(ordinal_i128))
	if date_err != .None || date.year < 0 || date.year > 9999 {
		return {}, .Out_Of_Range
	}

	seconds, nanosecond := floor_divmod_i128(day_nanoseconds, 1_000_000_000)
	hour, hour_remainder := floor_divmod_i128(seconds, 3600)
	minute, second := floor_divmod_i128(hour_remainder, 60)
	return {
		local = {
			date = {u16(date.year), u8(date.month), u8(date.day)},
			time = {u8(hour), u8(minute), u8(second), u32(nanosecond)},
		},
		offset = offset,
	}, .None
}
