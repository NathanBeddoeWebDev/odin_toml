package temporal

validate :: proc {
	validate_local_date,
	validate_local_time,
	validate_local_date_time,
	validate_utc_offset,
	validate_offset_date_time,
}

@(private)
is_leap_year :: proc "contextless" (year: u16) -> bool {
	return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

@(private)
days_in_month :: proc "contextless" (year: u16, month: u8) -> u8 {
	days := [12]u8{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if month == 2 && is_leap_year(year) {
		return 29
	}
	return days[month - 1]
}

@(require_results)
validate_local_date :: proc(value: Local_Date) -> Error {
	if value.year > 9999 {
		return .Invalid_Year
	}
	if value.month < 1 || value.month > 12 {
		return .Invalid_Month
	}
	if value.day < 1 || value.day > days_in_month(value.year, value.month) {
		return .Invalid_Day
	}
	return .None
}

@(require_results)
validate_local_time :: proc(value: Local_Time) -> Error {
	if value.hour > 23 {
		return .Invalid_Hour
	}
	if value.minute > 59 {
		return .Invalid_Minute
	}
	if value.second > 60 {
		return .Invalid_Second
	}
	if value.nanosecond >= 1_000_000_000 {
		return .Invalid_Nanosecond
	}
	return .None
}

@(require_results)
validate_local_date_time :: proc(value: Local_Date_Time) -> Error {
	if err := validate_local_date(value.date); err != .None {
		return err
	}
	return validate_local_time(value.time)
}

@(require_results)
validate_utc_offset :: proc(value: UTC_Offset) -> Error {
	if u8(value.kind) > u8(Offset_Kind.Unknown) {
		return .Invalid_Offset_Kind
	}
	if value.kind == .Known {
		if value.minutes < -1439 || value.minutes > 1439 {
			return .Invalid_Offset_Minutes
		}
		return .None
	}
	if value.minutes != 0 {
		return .Invalid_Unknown_Offset
	}
	return .None
}

@(require_results)
validate_offset_date_time :: proc(value: Offset_Date_Time) -> Error {
	if err := validate_local_date_time(value.local); err != .None {
		return err
	}
	return validate_utc_offset(value.offset)
}
