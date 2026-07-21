package temporal

import "core:time/datetime"

compare :: proc {
	compare_local_date,
	compare_local_time,
	compare_local_date_time,
}

@(private)
compare_i64 :: proc "contextless" (a, b: i64) -> int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

@(private)
compare_valid_local_date :: proc "contextless" (a, b: Local_Date) -> int {
	if ordering := compare_i64(i64(a.year), i64(b.year)); ordering != 0 {
		return ordering
	}
	if ordering := compare_i64(i64(a.month), i64(b.month)); ordering != 0 {
		return ordering
	}
	return compare_i64(i64(a.day), i64(b.day))
}

@(private)
compare_valid_local_time :: proc "contextless" (a, b: Local_Time) -> int {
	if ordering := compare_i64(i64(a.hour), i64(b.hour)); ordering != 0 {
		return ordering
	}
	if ordering := compare_i64(i64(a.minute), i64(b.minute)); ordering != 0 {
		return ordering
	}
	if ordering := compare_i64(i64(a.second), i64(b.second)); ordering != 0 {
		return ordering
	}
	return compare_i64(i64(a.nanosecond), i64(b.nanosecond))
}

@(private)
compare_valid_local_date_time :: proc "contextless" (a, b: Local_Date_Time) -> int {
	if ordering := compare_valid_local_date(a.date, b.date); ordering != 0 {
		return ordering
	}
	return compare_valid_local_time(a.time, b.time)
}

@(require_results)
compare_local_date :: proc(a, b: Local_Date) -> (ordering: int, err: Error) {
	if err = validate_local_date(a); err != .None {
		return
	}
	if err = validate_local_date(b); err != .None {
		return
	}
	ordering = compare_valid_local_date(a, b)
	return
}

@(require_results)
compare_local_time :: proc(a, b: Local_Time) -> (ordering: int, err: Error) {
	if err = validate_local_time(a); err != .None {
		return
	}
	if err = validate_local_time(b); err != .None {
		return
	}
	ordering = compare_valid_local_time(a, b)
	return
}

@(require_results)
compare_local_date_time :: proc(a, b: Local_Date_Time) -> (ordering: int, err: Error) {
	if err = validate_local_date_time(a); err != .None {
		return
	}
	if err = validate_local_date_time(b); err != .None {
		return
	}
	ordering = compare_valid_local_date_time(a, b)
	return
}

@(private)
normalized_instant_parts :: proc "contextless" (
	value: Offset_Date_Time,
) -> (day: datetime.Ordinal, second: i64, nanosecond: u32) {
	day = datetime.unsafe_date_to_ordinal({
		i64(value.local.date.year),
		i8(value.local.date.month),
		i8(value.local.date.day),
	})
	second = i64(value.local.time.hour) * 3600 +
	         i64(value.local.time.minute) * 60 +
	         i64(value.local.time.second) -
	         i64(value.offset.minutes) * 60
	if second < 0 {
		day -= 1
		second += 86_400
	} else if second >= 86_400 {
		day += 1
		second -= 86_400
	}
	nanosecond = value.local.time.nanosecond
	return
}

@(require_results)
compare_instant :: proc(a, b: Offset_Date_Time) -> (ordering: int, err: Error) {
	if err = validate_offset_date_time(a); err != .None {
		return
	}
	if err = validate_offset_date_time(b); err != .None {
		return
	}

	has_leap_second := a.local.time.second == 60 || b.local.time.second == 60
	if has_leap_second {
		if a.offset != b.offset {
			err = .Leap_Second_Not_Comparable
			return
		}
		ordering = compare_valid_local_date_time(a.local, b.local)
		return
	}

	a_day, a_second, a_nanosecond := normalized_instant_parts(a)
	b_day, b_second, b_nanosecond := normalized_instant_parts(b)
	if ordering = compare_i64(i64(a_day), i64(b_day)); ordering != 0 {
		return
	}
	if ordering = compare_i64(a_second, b_second); ordering != 0 {
		return
	}
	ordering = compare_i64(i64(a_nanosecond), i64(b_nanosecond))
	return
}
