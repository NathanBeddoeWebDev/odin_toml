package float_parse_test

import "core:math/big"
import "core:mem"
import "core:testing"
import toml "../.."
import test_support "../support"

Gate_Status :: enum u8 {
	Success,
	Invalid,
	Overflow,
}

runtime_decimal_to_binary64 :: proc(text: string) -> (value: f64, status: Gate_Status) {
	valid, overflow: bool
	conversion_error: big.Error
	value, valid, overflow, conversion_error = toml.decimal_to_binary64_gate(text)
	if conversion_error != nil {
		return value, .Invalid
	}
	if !valid {
		return value, .Invalid
	}
	if overflow {
		return value, .Overflow
	}
	return value, .Success
}

// The oracle keeps decimal text as the exact rational numerator/denominator.
// It never calls the runtime converter or a floating-point arithmetic operation.
parse_exact_decimal_oracle :: proc(
	text: string,
	numerator, denominator: ^big.Int,
) -> (negative, too_large, too_small, ok: bool) {
	if len(text) == 0 {
		return false, false, false, false
	}
	digits, allocation_error := make([]byte, len(text))
	if allocation_error != nil {
		return false, false, false, false
	}
	defer delete(digits)
	digit_count := 0
	fraction_digit_count := 0
	leading_zero_count := 0
	saw_nonzero := false
	saw_dot := false
	index := 0

	if text[index] == '+' || text[index] == '-' {
		negative = text[index] == '-'
		index += 1
		if index == len(text) {
			return false, false, false, false
		}
	}

	previous_was_digit := false
	digit_loop: for index < len(text) {
		character := text[index]
		switch {
		case '0' <= character && character <= '9':
			digits[digit_count] = character
			digit_count += 1
			if !saw_nonzero {
				if character == '0' {
					leading_zero_count += 1
				} else {
					saw_nonzero = true
				}
			}
			if saw_dot {
				fraction_digit_count += 1
			}
			previous_was_digit = true
			index += 1
		case character == '_' && previous_was_digit && index+1 < len(text) &&
		     '0' <= text[index+1] && text[index+1] <= '9':
			previous_was_digit = false
			index += 1
		case character == '.' && !saw_dot && previous_was_digit &&
		     index+1 < len(text) && '0' <= text[index+1] && text[index+1] <= '9':
			saw_dot = true
			previous_was_digit = false
			index += 1
		case:
			break digit_loop
		}
	}
	if digit_count == 0 || !previous_was_digit {
		return false, false, false, false
	}

	exponent := 0
	if index < len(text) && (text[index] == 'e' || text[index] == 'E') {
		index += 1
		exponent_negative := false
		if index < len(text) && (text[index] == '+' || text[index] == '-') {
			exponent_negative = text[index] == '-'
			index += 1
		}
		exponent_digits := 0
		previous_was_digit = false
		for index < len(text) {
			character := text[index]
			if '0' <= character && character <= '9' {
				if exponent < 1_000_000_000 {
					exponent = exponent*10 + int(character-'0')
				}
				exponent_digits += 1
				previous_was_digit = true
				index += 1
				continue
			}
			if character == '_' && previous_was_digit && index+1 < len(text) &&
			   '0' <= text[index+1] && text[index+1] <= '9' {
				previous_was_digit = false
				index += 1
				continue
			}
			break
		}
		if exponent_digits == 0 || !previous_was_digit {
			return false, false, false, false
		}
		if exponent_negative {
			exponent = -exponent
		}
	}
	if index != len(text) {
		return false, false, false, false
	}
	if !saw_nonzero {
		if big.set(numerator, 0) != .None || big.set(denominator, 1) != .None {
			return false, false, false, false
		}
		return negative, false, false, true
	}
	decimal_order := digit_count-leading_zero_count-fraction_digit_count+exponent
	if decimal_order > 309 {
		return negative, true, false, true
	}
	if decimal_order < -323 {
		return negative, false, true, true
	}
	exponent -= fraction_digit_count

	if big.string_to_int(numerator, string(digits[:digit_count])) != .None ||
	   big.set(denominator, 1) != .None {
		return false, false, false, false
	}

	scale, scaled: big.Int
	defer big.destroy(&scale, &scaled)
	if exponent > 0 {
		if big.int_pow_int(&scale, 10, exponent) != .None ||
		   big.mul(&scaled, numerator, &scale) != .None ||
		   big.copy(numerator, &scaled) != .None {
			return false, false, false, false
		}
	} else if exponent < 0 {
		if big.int_pow_int(denominator, 10, -exponent) != .None {
			return false, false, false, false
		}
	}
	return negative, false, false, true
}

// Every finite positive binary64 is an integer multiple of 2^-1074.
binary64_in_min_subnormal_units :: proc(bits: u64, result: ^big.Int) -> bool {
	fraction := bits & 0x000f_ffff_ffff_ffff
	exponent_bits := (bits >> 52) & 0x7ff
	if exponent_bits == 0 {
		return big.set(result, fraction) == .None
	}
	if exponent_bits == 0x7ff {
		return false
	}
	if big.set(result, fraction | 0x0010_0000_0000_0000) != .None {
		return false
	}
	return big.shl(result, result, int(exponent_bits-1)) == .None
}

compare_exact_to_binary64 :: proc(
	exact_scaled, denominator: ^big.Int,
	bits: u64,
) -> (ordering: int, ok: bool) {
	binary_scaled, right: big.Int
	defer big.destroy(&binary_scaled, &right)
	if !binary64_in_min_subnormal_units(bits, &binary_scaled) ||
	   big.mul(&right, &binary_scaled, denominator) != .None {
		return 0, false
	}
	comparison, err := big.compare(exact_scaled, &right)
	return comparison, err == .None
}

overflow_neighbor_in_min_subnormal_units :: proc(result: ^big.Int) -> bool {
	one: big.Int
	defer big.destroy(&one)
	return big.set(&one, 1) == .None && big.shl(result, &one, 2098) == .None
}

exact_decimal_to_binary64_oracle :: proc(text: string) -> (
	bits: u64,
	status: Gate_Status,
	ok: bool,
) {
	numerator, denominator, exact_scaled: big.Int
	defer big.destroy(&numerator, &denominator, &exact_scaled)
	negative, too_large, too_small, parsed := parse_exact_decimal_oracle(
		text,
		&numerator,
		&denominator,
	)
	if !parsed {
		return 0, .Invalid, true
	}
	sign_bit := u64(0x8000_0000_0000_0000) if negative else u64(0)
	if too_large {
		return sign_bit | 0x7ff0_0000_0000_0000, .Overflow, true
	}
	if too_small {
		return sign_bit, .Success, true
	}
	if big.shl(&exact_scaled, &numerator, 1074) != .None {
		return 0, .Invalid, false
	}
	zero_comparison, err := big.compare(&numerator, 0)
	if err != .None {
		return 0, .Invalid, false
	}
	if zero_comparison == 0 {
		if negative {
			return 0x8000_0000_0000_0000, .Success, true
		}
		return 0, .Success, true
	}

	// Bracket the exact rational between adjacent raw binary64 values.
	MAX_FINITE_BITS :: u64(0x7fef_ffff_ffff_ffff)
	lower_bits := u64(0)
	low, high := u64(0), MAX_FINITE_BITS
	for low <= high {
		middle := low + (high-low)/2
		ordering, compared := compare_exact_to_binary64(&exact_scaled, &denominator, middle)
		if !compared {
			return 0, .Invalid, false
		}
		if ordering < 0 {
			if middle == 0 {
				break
			}
			high = middle-1
		} else {
			lower_bits = middle
			if ordering == 0 {
				bits = lower_bits
				if negative {
					bits |= 0x8000_0000_0000_0000
				}
				return bits, .Success, true
			}
			if middle == MAX_FINITE_BITS {
				break
			}
			low = middle+1
		}
	}

	lower_scaled, upper_scaled, lower_right, upper_right: big.Int
	lower_distance, upper_distance: big.Int
	defer big.destroy(
		&lower_scaled,
		&upper_scaled,
		&lower_right,
		&upper_right,
		&lower_distance,
		&upper_distance,
	)
	if !binary64_in_min_subnormal_units(lower_bits, &lower_scaled) ||
	   big.mul(&lower_right, &lower_scaled, &denominator) != .None {
		return 0, .Invalid, false
	}
	upper_is_overflow := lower_bits == MAX_FINITE_BITS
	if upper_is_overflow {
		if !overflow_neighbor_in_min_subnormal_units(&upper_scaled) {
			return 0, .Invalid, false
		}
	} else if !binary64_in_min_subnormal_units(lower_bits+1, &upper_scaled) {
		return 0, .Invalid, false
	}
	if big.mul(&upper_right, &upper_scaled, &denominator) != .None {
		return 0, .Invalid, false
	}
	comparison_to_upper, compare_err := big.compare(&exact_scaled, &upper_right)
	if compare_err != .None {
		return 0, .Invalid, false
	}
	if upper_is_overflow && comparison_to_upper >= 0 {
		bits = 0x7ff0_0000_0000_0000
		if negative {
			bits |= 0x8000_0000_0000_0000
		}
		return bits, .Overflow, true
	}
	if big.sub(&lower_distance, &exact_scaled, &lower_right) != .None ||
	   big.sub(&upper_distance, &upper_right, &exact_scaled) != .None {
		return 0, .Invalid, false
	}
	// Both distances have the same exact denominator. Select the nearest,
	// choosing the raw value with an even significand on an exact tie.
	distance_ordering, distance_err := big.compare(&lower_distance, &upper_distance)
	if distance_err != .None {
		return 0, .Invalid, false
	}
	if distance_ordering < 0 || distance_ordering == 0 && lower_bits&1 == 0 {
		bits = lower_bits
		status = .Success
	} else if upper_is_overflow {
		bits = 0x7ff0_0000_0000_0000
		status = .Overflow
	} else {
		bits = lower_bits+1
		status = .Success
	}
	if negative {
		bits |= 0x8000_0000_0000_0000
	}
	return bits, status, true
}

write_decimal_exponent :: proc(buffer: []byte, index: ^int, exponent: int) {
	buffer[index^] = 'e'
	index^ += 1
	magnitude := exponent
	if magnitude < 0 {
		buffer[index^] = '-'
		index^ += 1
		magnitude = -magnitude
	}
	if magnitude == 0 {
		buffer[index^] = '0'
		index^ += 1
		return
	}
	reversed: [8]byte
	count := 0
	for magnitude > 0 {
		reversed[count] = byte(magnitude%10)+'0'
		count += 1
		magnitude /= 10
	}
	for count > 0 {
		count -= 1
		buffer[index^] = reversed[count]
		index^ += 1
	}
}

make_subnormal_halfway :: proc(buffer: []byte, multiple: u64) -> (text: string, ok: bool) {
	five, power, multiplier, numerator: big.Int
	defer big.destroy(&five, &power, &multiplier, &numerator)
	if big.set(&five, 5) != .None ||
	   big.int_pow(&power, &five, 1075) != .None ||
	   big.set(&multiplier, multiple) != .None ||
	   big.mul(&numerator, &power, &multiplier) != .None {
		return "", false
	}
	digits, err := big.int_to_string(&numerator)
	if err != .None {
		return "", false
	}
	defer delete(digits)
	decimal_places := 1075
	if 2+decimal_places > len(buffer) || len(digits) > decimal_places {
		return "", false
	}
	buffer[0], buffer[1] = '0', '.'
	first_digit := 2+decimal_places-len(digits)
	for index in 2..<first_digit {
		buffer[index] = '0'
	}
	copy(buffer[first_digit:], digits)
	return string(buffer[:2+decimal_places]), true
}

make_decimal_sample :: proc(
	buffer: []byte,
	random: ^test_support.Replay_Random,
	ordinal: int,
) -> string {
	index := 0
	if ordinal%3 == 0 {
		buffer[index] = '-'
		index += 1
	}
	digit_count := 2 + test_support.replay_int_max(random, 48)
	point := 1 + test_support.replay_int_max(random, digit_count-1)
	for digit_index in 0..<digit_count {
		if digit_index == point {
			buffer[index] = '.'
			index += 1
		}
		digit := byte(test_support.replay_int_max(random, 10))
		if digit_index == 0 && digit == 0 {
			digit = 1
		}
		buffer[index] = '0'+digit
		index += 1
	}
	exponent := test_support.replay_int_max(random, 801)-400
	write_decimal_exponent(buffer, &index, exponent)
	return string(buffer[:index])
}

@(test)
test_decimal_to_binary64_named_zero_and_adjacent_vectors :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:   string,
		bits:   u64,
		status: Gate_Status,
	}{
		{"0.0", 0x0000_0000_0000_0000, .Success},
		{"-0.0", 0x8000_0000_0000_0000, .Success},
		{"1.0", 0x3ff0_0000_0000_0000, .Success},
		{"1.0000000000000002", 0x3ff0_0000_0000_0001, .Success},
		{"1.00000000000000011102230246251565404236316680908203125", 0x3ff0_0000_0000_0000, .Success},
		{"1.00000000000000033306690738754696212708950042724609375", 0x3ff0_0000_0000_0002, .Success},
		{"2.4703282292062327e-324", 0x0000_0000_0000_0000, .Success},
		{"2.4703282292062328e-324", 0x0000_0000_0000_0001, .Success},
		{"-1e-4000", 0x8000_0000_0000_0000, .Success},
		{"4.9406564584124654e-324", 0x0000_0000_0000_0001, .Success},
		{"2.225073858507201e-308", 0x000f_ffff_ffff_ffff, .Success},
		{"2.2250738585072014e-308", 0x0010_0000_0000_0000, .Success},
		{"1.7976931348623157e308", 0x7fef_ffff_ffff_ffff, .Success},
		{"1.7976931348623158e308", 0x7fef_ffff_ffff_ffff, .Success},
		{"1.7976931348623159e308", 0x7ff0_0000_0000_0000, .Overflow},
		{"179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792", 0x7ff0_0000_0000_0000, .Overflow},
		{"-1.7976931348623159e308", 0xfff0_0000_0000_0000, .Overflow},
		{"1_2.5_0e+0_2", 0x4093_8800_0000_0000, .Success},
	}

	for test_case in cases {
		value, status := runtime_decimal_to_binary64(test_case.text)
		testing.expect_value(t, status, test_case.status)
		testing.expect_value(t, transmute(u64)value, test_case.bits)

		oracle_bits, oracle_status, oracle_ok := exact_decimal_to_binary64_oracle(test_case.text)
		testing.expect(t, oracle_ok)
		testing.expect_value(t, oracle_status, test_case.status)
		testing.expect_value(t, oracle_bits, test_case.bits)
	}
}

@(test)
test_decimal_to_binary64_subnormal_halfway_ties_to_even :: proc(t: ^testing.T) {
	cases := [?]struct {
		multiple: u64,
		bits:     u64,
	}{
		{1, 0x0000_0000_0000_0000},
		{3, 0x0000_0000_0000_0002},
		{0x001f_ffff_ffff_ffff, 0x0010_0000_0000_0000},
	}
	for test_case in cases {
		buffer: [1080]byte
		text, built := make_subnormal_halfway(buffer[:], test_case.multiple)
		testing.expect(t, built)
		if !built {
			return
		}
		value, status := runtime_decimal_to_binary64(text)
		testing.expect_value(t, status, Gate_Status.Success)
		testing.expect_value(t, transmute(u64)value, test_case.bits)

		oracle_bits, oracle_status, oracle_ok := exact_decimal_to_binary64_oracle(text)
		testing.expect(t, oracle_ok)
		testing.expect_value(t, oracle_status, Gate_Status.Success)
		testing.expect_value(t, oracle_bits, test_case.bits)
	}
}

@(test)
test_decimal_to_binary64_uses_discarded_digits_as_rounding_sticky_bit :: proc(t: ^testing.T) {
	HALFWAY :: "1.00000000000000011102230246251565404236316680908203125"
	buffer: [600]byte
	count := copy(buffer[:], HALFWAY)
	for _ in 0..<400 {
		buffer[count] = '0'
		count += 1
	}
	buffer[count] = '1'
	count += 1
	text := string(buffer[:count])

	value, status := runtime_decimal_to_binary64(text)
	testing.expect_value(t, status, Gate_Status.Success)
	testing.expect_value(t, transmute(u64)value, u64(0x3ff0_0000_0000_0001))
	expected_bits, expected_status, oracle_ok := exact_decimal_to_binary64_oracle(text)
	testing.expect(t, oracle_ok)
	testing.expect_value(t, expected_status, Gate_Status.Success)
	testing.expect_value(t, expected_bits, u64(0x3ff0_0000_0000_0001))
}

@(test)
test_decimal_to_binary64_has_no_fixed_lexeme_or_oracle_digit_limit :: proc(t: ^testing.T) {
	buffer: [2060]byte
	count := 0
	buffer[count] = '1'
	count += 1
	for _ in 0..<2048 {
		buffer[count] = '0'
		count += 1
	}
	count += copy(buffer[count:], "e-2048")
	text := string(buffer[:count])

	value, status := runtime_decimal_to_binary64(text)
	testing.expect_value(t, status, Gate_Status.Success)
	testing.expect_value(t, transmute(u64)value, u64(0x3ff0_0000_0000_0000))
	expected_bits, expected_status, oracle_ok := exact_decimal_to_binary64_oracle(text)
	testing.expect(t, oracle_ok)
	testing.expect_value(t, expected_status, Gate_Status.Success)
	testing.expect_value(t, expected_bits, u64(0x3ff0_0000_0000_0000))
}

@(test)
test_decimal_to_binary64_matches_exact_rational_oracle_samples :: proc(t: ^testing.T) {
	random := test_support.replay_random_init(0x6a09_e667_f3bc_c909)
	for ordinal in 0..<256 {
		buffer: [128]byte
		text := make_decimal_sample(buffer[:], &random, ordinal)
		expected_bits, expected_status, oracle_ok := exact_decimal_to_binary64_oracle(text)
		testing.expect(t, oracle_ok)
		if !oracle_ok {
			return
		}
		value, status := runtime_decimal_to_binary64(text)
		testing.expect_value(t, status, expected_status)
		testing.expect_value(t, transmute(u64)value, expected_bits)
	}
}

@(test)
test_decimal_to_binary64_reports_each_scratch_allocation_failure :: proc(t: ^testing.T) {
	backing := context.allocator
	completed := false
	for fail_at in 1..=128 {
		events: [512]test_support.Allocator_Event
		live: [128]test_support.Live_Allocation
		observed: test_support.Observed_Allocator
		test_support.observed_allocator_init(&observed, backing, events[:], live[:])
		observed.fail_at_allocation = fail_at
		selected := test_support.observed_allocator(&observed)

		rejecting: test_support.Rejecting_Allocator
		context.allocator = test_support.rejecting_allocator(&rejecting)
		value, valid, overflow, conversion_error := toml.decimal_to_binary64_gate(
			"1.00000000000000033306690738754696212708950042724609375",
			selected,
		)
		context.allocator = backing

		testing.expect_value(t, observed.live_count, 0)
		testing.expect_value(t, observed.foreign_release_count, 0)
		testing.expect_value(t, rejecting.allocation_attempt_count, 0)
		if conversion_error == nil {
			testing.expect(t, valid)
			testing.expect(t, !overflow)
			testing.expect_value(t, transmute(u64)value, u64(0x3ff0_0000_0000_0002))
			completed = true
			break
		}
		testing.expect(t, !valid)
		testing.expect(t, !overflow)
		testing.expect_value(t, conversion_error, big.Error.Out_Of_Memory)
	}
	context.allocator = backing
	testing.expect(t, completed)
}

@(test)
test_decimal_to_binary64_logically_releases_external_lifetime_scratch :: proc(t: ^testing.T) {
	buffer: [128 * 1024]byte
	arena: mem.Arena
	mem.arena_init(&arena, buffer[:])

	external: test_support.External_Lifetime_Allocator
	test_support.external_lifetime_allocator_init(
		&external,
		mem.arena_allocator(&arena),
		true,
	)
	allocator := test_support.external_lifetime_allocator(&external)
	value, valid, overflow, conversion_error := toml.decimal_to_binary64_gate(
		"1.25",
		allocator,
		false,
	)
	testing.expect_value(t, conversion_error, big.Error.None)
	testing.expect(t, valid)
	testing.expect(t, !overflow)
	testing.expect_value(t, transmute(u64)value, u64(0x3ff4_0000_0000_0000))
	testing.expect_value(t, external.release_attempt_count, 0)
	testing.expect(t, arena.offset > 0)
	testing.expect_value(t, mem.free_all(allocator), nil)
	testing.expect_value(t, arena.offset, 0)
}

@(test)
test_decimal_to_binary64_rejects_non_decimal_gate_inputs :: proc(t: ^testing.T) {
	invalid := [?]string{
		"", "+", "-", ".5", "1.", "1e", "1e+", "1__0.0", "1_.0", "1._0", "1e_2", "nan", "inf", "0x1p0",
	}
	for text in invalid {
		value, status := runtime_decimal_to_binary64(text)
		testing.expect_value(t, status, Gate_Status.Invalid)
		testing.expect_value(t, transmute(u64)value, u64(0))
	}
}
