package temporal_test

import "core:testing"
import "core:time"
import "core:time/datetime"
import temporal "../../vendor/temporal"
import test_support "../support"

@(test)
test_validate_local_date_boundaries_and_gregorian_neighbors :: proc(t: ^testing.T) {
	cases := [?]struct {
		value: temporal.Local_Date,
		err:   temporal.Error,
	}{
		{{0, 1, 1}, .None},
		{{9999, 12, 31}, .None},
		{{10000, 1, 1}, .Invalid_Year},
		{{2024, 0, 1}, .Invalid_Month},
		{{2024, 13, 1}, .Invalid_Month},
		{{2024, 1, 0}, .Invalid_Day},
		{{2024, 1, 31}, .None},
		{{2024, 1, 32}, .Invalid_Day},
		{{2024, 4, 30}, .None},
		{{2024, 4, 31}, .Invalid_Day},
		{{1900, 2, 28}, .None},
		{{1900, 2, 29}, .Invalid_Day},
		{{2000, 2, 29}, .None},
		{{2100, 2, 29}, .Invalid_Day},
	}

	for test_case in cases {
		testing.expect_value(t, temporal.validate(test_case.value), test_case.err)
	}
}

@(test)
test_validate_local_time_boundaries :: proc(t: ^testing.T) {
	cases := [?]struct {
		value: temporal.Local_Time,
		err:   temporal.Error,
	}{
		{{0, 0, 0, 0}, .None},
		{{23, 59, 59, 999_999_999}, .None},
		{{23, 59, 60, 999_999_999}, .None},
		{{24, 0, 0, 0}, .Invalid_Hour},
		{{0, 60, 0, 0}, .Invalid_Minute},
		{{0, 0, 61, 0}, .Invalid_Second},
		{{0, 0, 0, 1_000_000_000}, .Invalid_Nanosecond},
	}

	for test_case in cases {
		testing.expect_value(t, temporal.validate(test_case.value), test_case.err)
	}
}

@(test)
test_validate_offsets_and_composite_precedence :: proc(t: ^testing.T) {
	offset_cases := [?]struct {
		value: temporal.UTC_Offset,
		err:   temporal.Error,
	}{
		{{.Known, -1439}, .None},
		{{.Known, 0}, .None},
		{{.Known, 1439}, .None},
		{{.Known, -1440}, .Invalid_Offset_Minutes},
		{{.Known, 1440}, .Invalid_Offset_Minutes},
		{{.Unknown, 0}, .None},
		{{.Unknown, 1}, .Invalid_Unknown_Offset},
		{{temporal.Offset_Kind(255), 0}, .Invalid_Offset_Kind},
	}
	for test_case in offset_cases {
		testing.expect_value(t, temporal.validate(test_case.value), test_case.err)
	}

	all_invalid := temporal.Offset_Date_Time{
		local = {
			date = {10000, 13, 0},
			time = {24, 60, 61, 1_000_000_000},
		},
		offset = {temporal.Offset_Kind(255), 1440},
	}
	testing.expect_value(t, temporal.validate(all_invalid), temporal.Error.Invalid_Year)

	invalid_time := all_invalid
	invalid_time.local.date = {2024, 1, 1}
	testing.expect_value(t, temporal.validate(invalid_time), temporal.Error.Invalid_Hour)

	invalid_offset := invalid_time
	invalid_offset.local.time = {}
	testing.expect_value(t, temporal.validate(invalid_offset), temporal.Error.Invalid_Offset_Kind)
}

@(test)
test_compare_civil_values_and_operand_precedence :: proc(t: ^testing.T) {
	ordering, err := temporal.compare(
		temporal.Local_Date{0, 1, 1},
		temporal.Local_Date{9999, 12, 31},
	)
	testing.expect_value(t, ordering, -1)
	testing.expect_value(t, err, temporal.Error.None)

	ordering, err = temporal.compare(
		temporal.Local_Time{23, 59, 59, 999_999_998},
		temporal.Local_Time{23, 59, 59, 999_999_999},
	)
	testing.expect_value(t, ordering, -1)
	testing.expect_value(t, err, temporal.Error.None)

	ordering, err = temporal.compare(
		temporal.Local_Time{23, 59, 60, 0},
		temporal.Local_Time{23, 59, 59, 999_999_999},
	)
	testing.expect_value(t, ordering, 1)
	testing.expect_value(t, err, temporal.Error.None)

	a := temporal.Local_Date_Time{{2024, 2, 29}, {23, 59, 59, 999_999_999}}
	b := temporal.Local_Date_Time{{2024, 3, 1}, {0, 0, 0, 0}}
	ordering, err = temporal.compare(a, b)
	testing.expect_value(t, ordering, -1)
	testing.expect_value(t, err, temporal.Error.None)
	ordering, err = temporal.compare(b, a)
	testing.expect_value(t, ordering, 1)
	testing.expect_value(t, err, temporal.Error.None)
	ordering, err = temporal.compare(a, a)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.None)

	ordering, err = temporal.compare(
		temporal.Local_Date{10000, 13, 0},
		temporal.Local_Date{10001, 0, 0},
	)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.Invalid_Year)

	ordering, err = temporal.compare(
		temporal.Local_Date{2024, 1, 1},
		temporal.Local_Date{2024, 13, 0},
	)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.Invalid_Month)
}

@(test)
test_compare_instants_with_offsets_unknown_state_and_leap_seconds :: proc(t: ^testing.T) {
	utc := temporal.Offset_Date_Time{
		local = {{2023, 12, 31}, {23, 0, 0, 123}},
		offset = {.Known, 0},
	}
	plus_one := temporal.Offset_Date_Time{
		local = {{2024, 1, 1}, {0, 0, 0, 123}},
		offset = {.Known, 60},
	}
	ordering, err := temporal.compare_instant(plus_one, utc)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.None)
	testing.expect(t, plus_one != utc)

	unknown := utc
	unknown.offset.kind = .Unknown
	before := unknown
	ordering, err = temporal.compare_instant(unknown, utc)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.None)
	testing.expect_value(t, unknown, before)

	same_local_utc := plus_one
	same_local_utc.offset.minutes = 0
	ordering, err = temporal.compare_instant(plus_one, same_local_utc)
	testing.expect_value(t, ordering, -1)
	testing.expect_value(t, err, temporal.Error.None)

	leap := utc
	leap.local.time.second = 60
	normal := utc
	normal.local.time.second = 59
	ordering, err = temporal.compare_instant(leap, normal)
	testing.expect_value(t, ordering, 1)
	testing.expect_value(t, err, temporal.Error.None)

	differently_offset := leap
	differently_offset.offset.minutes = 1
	ordering, err = temporal.compare_instant(leap, differently_offset)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.Leap_Second_Not_Comparable)

	unknown_offset := leap
	unknown_offset.offset.kind = .Unknown
	ordering, err = temporal.compare_instant(leap, unknown_offset)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.Leap_Second_Not_Comparable)

	invalid_left := leap
	invalid_left.local.date.year = 10000
	invalid_right := differently_offset
	invalid_right.local.time.hour = 24
	ordering, err = temporal.compare_instant(invalid_left, invalid_right)
	testing.expect_value(t, ordering, 0)
	testing.expect_value(t, err, temporal.Error.Invalid_Year)
}

@(test)
test_convert_local_values_without_loss :: proc(t: ^testing.T) {
	date_value := temporal.Local_Date{0, 1, 1}
	core_date, err := temporal.local_date_to_datetime(date_value)
	testing.expect_value(t, err, temporal.Error.None)
	testing.expect_value(t, core_date, datetime.Date{0, 1, 1})
	date_round_trip, date_round_trip_err := temporal.local_date_from_datetime(core_date)
	testing.expect_value(t, date_round_trip_err, temporal.Error.None)
	testing.expect_value(t, date_round_trip, date_value)

	_, err = temporal.local_date_to_datetime({10000, 1, 1})
	testing.expect_value(t, err, temporal.Error.Invalid_Year)
	_, err = temporal.local_date_from_datetime({-1, 1, 1})
	testing.expect_value(t, err, temporal.Error.Invalid_Year)
	_, err = temporal.local_date_from_datetime({2024, 2, 30})
	testing.expect_value(t, err, temporal.Error.Invalid_Day)
	_, err = temporal.local_date_to_datetime({2024, 13, 1})
	testing.expect_value(t, err, temporal.Error.Invalid_Month)

	time_value := temporal.Local_Time{23, 59, 59, 999_999_999}
	core_time, time_err := temporal.local_time_to_datetime(time_value)
	testing.expect_value(t, time_err, temporal.Error.None)
	testing.expect_value(t, core_time, datetime.Time{23, 59, 59, 999_999_999})
	time_round_trip, time_round_trip_err := temporal.local_time_from_datetime(core_time)
	testing.expect_value(t, time_round_trip_err, temporal.Error.None)
	testing.expect_value(t, time_round_trip, time_value)

	_, time_err = temporal.local_time_to_datetime({23, 59, 60, 0})
	testing.expect_value(t, time_err, temporal.Error.Unsupported_Leap_Second)
	_, time_err = temporal.local_time_to_datetime({23, 59, 60, 1_000_000_000})
	testing.expect_value(t, time_err, temporal.Error.Invalid_Nanosecond)
	_, time_err = temporal.local_time_from_datetime({23, 59, 60, 0})
	testing.expect_value(t, time_err, temporal.Error.Invalid_Second)
	_, time_err = temporal.local_time_from_datetime({23, 59, 59, 1_000_000_000})
	testing.expect_value(t, time_err, temporal.Error.Invalid_Nanosecond)
	_, time_err = temporal.local_time_to_datetime({24, 60, 60, 0})
	testing.expect_value(t, time_err, temporal.Error.Invalid_Hour)
	_, time_err = temporal.local_time_from_datetime({0, -1, 0, 0})
	testing.expect_value(t, time_err, temporal.Error.Invalid_Minute)

	date_time_value := temporal.Local_Date_Time{{9999, 12, 31}, {23, 59, 59, 1}}
	core_date_time, date_time_err := temporal.local_date_time_to_datetime(date_time_value)
	testing.expect_value(t, date_time_err, temporal.Error.None)
	testing.expect_value(t, core_date_time.tz, (^datetime.TZ_Region)(nil))
	date_time_round_trip, date_time_round_trip_err := temporal.local_date_time_from_datetime(core_date_time)
	testing.expect_value(t, date_time_round_trip_err, temporal.Error.None)
	testing.expect_value(t, date_time_round_trip, date_time_value)

	leap_date_time := date_time_value
	leap_date_time.time.second = 60
	_, date_time_err = temporal.local_date_time_to_datetime(leap_date_time)
	testing.expect_value(t, date_time_err, temporal.Error.Unsupported_Leap_Second)
	invalid_date_time := leap_date_time
	invalid_date_time.date.day = 0
	_, date_time_err = temporal.local_date_time_to_datetime(invalid_date_time)
	testing.expect_value(t, date_time_err, temporal.Error.Invalid_Day)

	region: datetime.TZ_Region
	non_local := core_date_time
	non_local.tz = &region
	_, date_time_err = temporal.local_date_time_from_datetime(non_local)
	testing.expect_value(t, date_time_err, temporal.Error.Timezone_Not_Local)
	non_local.date.month = 13
	_, date_time_err = temporal.local_date_time_from_datetime(non_local)
	testing.expect_value(t, date_time_err, temporal.Error.Invalid_Month)
	non_local.date = core_date_time.date
	non_local.time.second = 60
	_, date_time_err = temporal.local_date_time_from_datetime(non_local)
	testing.expect_value(t, date_time_err, temporal.Error.Invalid_Second)
}

@(test)
test_convert_offset_date_times_and_explicit_offsets :: proc(t: ^testing.T) {
	epoch := temporal.Offset_Date_Time{
		local = {{1970, 1, 1}, {0, 0, 0, 0}},
		offset = {.Known, 0},
	}
	instant, err := temporal.offset_date_time_to_time(epoch)
	testing.expect_value(t, err, temporal.Error.None)
	testing.expect_value(t, time.time_to_unix_nano(instant), i64(0))

	plus_one := epoch
	plus_one.offset.minutes = 60
	instant, err = temporal.offset_date_time_to_time(plus_one)
	testing.expect_value(t, err, temporal.Error.None)
	testing.expect_value(t, time.time_to_unix_nano(instant), i64(-3_600_000_000_000))

	unknown := epoch
	unknown.offset.kind = .Unknown
	before := unknown
	instant, err = temporal.offset_date_time_to_time(unknown)
	testing.expect_value(t, err, temporal.Error.None)
	testing.expect_value(t, time.time_to_unix_nano(instant), i64(0))
	testing.expect_value(t, unknown, before)

	leap := epoch
	leap.local.time.second = 60
	_, err = temporal.offset_date_time_to_time(leap)
	testing.expect_value(t, err, temporal.Error.Unsupported_Leap_Second)
	out_of_range := epoch
	out_of_range.local.date.year = 0
	_, err = temporal.offset_date_time_to_time(out_of_range)
	testing.expect_value(t, err, temporal.Error.Out_Of_Range)

	utc_value, utc_err := temporal.offset_date_time_from_time_utc(time.from_nanoseconds(1))
	testing.expect_value(t, utc_err, temporal.Error.None)
	testing.expect_value(t, utc_value.local, temporal.Local_Date_Time{{1970, 1, 1}, {0, 0, 0, 1}})
	testing.expect_value(t, utc_value.offset, temporal.UTC_Offset{.Known, 0})

	positive, positive_err := temporal.offset_date_time_from_time(time.from_nanoseconds(1), {.Known, 60})
	testing.expect_value(t, positive_err, temporal.Error.None)
	testing.expect_value(t, positive.local, temporal.Local_Date_Time{{1970, 1, 1}, {1, 0, 0, 1}})
	testing.expect_value(t, positive.offset, temporal.UTC_Offset{.Known, 60})

	negative, negative_err := temporal.offset_date_time_from_time(time.from_nanoseconds(0), {.Known, -60})
	testing.expect_value(t, negative_err, temporal.Error.None)
	testing.expect_value(t, negative.local, temporal.Local_Date_Time{{1969, 12, 31}, {23, 0, 0, 0}})
	testing.expect_value(t, negative.offset, temporal.UTC_Offset{.Known, -60})

	unknown_value, unknown_err := temporal.offset_date_time_from_time(time.from_nanoseconds(0), {.Unknown, 0})
	testing.expect_value(t, unknown_err, temporal.Error.None)
	testing.expect_value(t, unknown_value.local, epoch.local)
	testing.expect_value(t, unknown_value.offset, temporal.UTC_Offset{.Unknown, 0})

	_, err = temporal.offset_date_time_from_time(time.from_nanoseconds(0), {.Unknown, 1})
	testing.expect_value(t, err, temporal.Error.Invalid_Unknown_Offset)
	invalid_offset_source := epoch
	invalid_offset_source.offset = {.Known, 1440}
	_, err = temporal.offset_date_time_to_time(invalid_offset_source)
	testing.expect_value(t, err, temporal.Error.Invalid_Offset_Minutes)

	round_trip_source := temporal.Offset_Date_Time{
		local = {{2000, 2, 29}, {0, 15, 30, 987_654_321}},
		offset = {.Known, -1439},
	}
	round_trip_instant, round_trip_to_err := temporal.offset_date_time_to_time(round_trip_source)
	testing.expect_value(t, round_trip_to_err, temporal.Error.None)
	round_trip_result, round_trip_from_err := temporal.offset_date_time_from_time(round_trip_instant, round_trip_source.offset)
	testing.expect_value(t, round_trip_from_err, temporal.Error.None)
	testing.expect_value(t, round_trip_result, round_trip_source)

	negative_nanosecond, negative_nanosecond_err := temporal.offset_date_time_from_time_utc(
		time.from_nanoseconds(-1),
	)
	testing.expect_value(t, negative_nanosecond_err, temporal.Error.None)
	testing.expect_value(
		t,
		negative_nanosecond.local,
		temporal.Local_Date_Time{{1969, 12, 31}, {23, 59, 59, 999_999_999}},
	)

	boundaries := [2]i64{min(i64), max(i64)}
	offsets := [2]temporal.UTC_Offset{{.Known, -1439}, {.Known, 1439}}
	for boundary in boundaries {
		for offset in offsets {
			boundary_value, boundary_from_err := temporal.offset_date_time_from_time(
				time.from_nanoseconds(boundary),
				offset,
			)
			testing.expect_value(t, boundary_from_err, temporal.Error.None)
			boundary_round_trip, boundary_to_err := temporal.offset_date_time_to_time(boundary_value)
			testing.expect_value(t, boundary_to_err, temporal.Error.None)
			testing.expect_value(t, time.time_to_unix_nano(boundary_round_trip), boundary)
		}
	}
}

@(test)
test_temporal_operations_do_not_use_the_context_allocator :: proc(t: ^testing.T) {
	previous_allocator := context.allocator
	rejecting: test_support.Rejecting_Allocator
	context.allocator = test_support.rejecting_allocator(&rejecting)
	defer context.allocator = previous_allocator

	date := temporal.Local_Date{2024, 2, 29}
	local_time := temporal.Local_Time{23, 59, 59, 999_999_999}
	date_time := temporal.Local_Date_Time{date, local_time}
	offset_date_time := temporal.Offset_Date_Time{date_time, {.Known, 60}}

	_ = temporal.validate(date)
	_ = temporal.validate(local_time)
	_ = temporal.validate(date_time)
	_ = temporal.validate(offset_date_time.offset)
	_ = temporal.validate(offset_date_time)
	_, _ = temporal.compare(date, date)
	_, _ = temporal.compare(local_time, local_time)
	_, _ = temporal.compare(date_time, date_time)
	_, _ = temporal.compare_instant(offset_date_time, offset_date_time)
	core_date, _ := temporal.local_date_to_datetime(date)
	_, _ = temporal.local_date_from_datetime(core_date)
	core_time, _ := temporal.local_time_to_datetime(local_time)
	_, _ = temporal.local_time_from_datetime(core_time)
	core_date_time, _ := temporal.local_date_time_to_datetime(date_time)
	_, _ = temporal.local_date_time_from_datetime(core_date_time)
	instant, _ := temporal.offset_date_time_to_time(offset_date_time)
	_, _ = temporal.offset_date_time_from_time_utc(instant)
	_, _ = temporal.offset_date_time_from_time(instant, {.Unknown, 0})

	_ = temporal.validate(temporal.Local_Date{10000, 0, 0})
	_, _ = temporal.compare(date, temporal.Local_Date{10000, 0, 0})
	_, _ = temporal.local_time_to_datetime({23, 59, 60, 0})
	_, _ = temporal.offset_date_time_to_time({{{0, 1, 1}, {}}, {.Known, 0}})

	testing.expect_value(t, rejecting.call_count, 0)
	testing.expect_value(t, rejecting.allocation_attempt_count, 0)
}
