package toml

import "core:math/big"
import "core:mem"

@(private)
TOML_DECIMAL_GATE_TESTING :: #config(TOML_DECIMAL_GATE_TESTING, false)

@(private)
Decimal_To_Binary64_Status :: enum u8 {
	Success,
	Invalid,
	Overflow,
}

@(private)
decimal_to_binary64 :: proc(
	text: string,
	allocator := context.allocator,
	individually_release_scratch := true,
) -> (value: f64, status: Decimal_To_Binary64_Status, conversion_error: big.Error) {
	if len(text) == 0 {
		return 0, .Invalid, nil
	}

	index := 0
	negative := false
	if text[index] == '+' || text[index] == '-' {
		negative = text[index] == '-'
		index += 1
		if index == len(text) {
			return 0, .Invalid, nil
		}
	}

	SCRATCH_MINIMUM_SIZE :: 64*1024
	SCRATCH_BYTES_PER_INPUT_BYTE :: 64
	if len(text) > (max(int)-SCRATCH_MINIMUM_SIZE)/SCRATCH_BYTES_PER_INPUT_BYTE {
		return 0, .Invalid, .Integer_Overflow
	}
	scratch_size := max(
		SCRATCH_MINIMUM_SIZE,
		SCRATCH_MINIMUM_SIZE+len(text)*SCRATCH_BYTES_PER_INPUT_BYTE,
	)
	scratch_bytes, allocation_error := mem.alloc_bytes(scratch_size, allocator = allocator)
	if allocation_error != nil {
		return 0, .Invalid, big.Error(allocation_error)
	}
	defer {
		if individually_release_scratch {
			_ = mem.free_bytes(scratch_bytes, allocator)
		} else {
			scratch_bytes = nil
		}
	}
	scratch: mem.Arena
	mem.arena_init(&scratch, scratch_bytes)
	context.allocator = mem.arena_allocator(&scratch)

	numerator, denominator, scale, scaled_numerator: big.Int
	rational: big.Rat
	defer {
		big.destroy(&numerator, &denominator, &scale, &scaled_numerator)
		big.destroy(&rational)
	}
	if err := big.set(&numerator, 0); err != nil {
		return 0, .Invalid, err
	}

	total_digit_count := 0
	fraction_digit_count := 0
	leading_zero_count := 0
	saw_nonzero := false
	saw_dot := false
	previous_was_digit := false
	digit_loop: for index < len(text) {
		character := text[index]
		switch {
		case '0' <= character && character <= '9':
			digit := big.DIGIT(character-'0')
			if err := big.mul(&numerator, &numerator, big.DIGIT(10)); err != nil {
				return 0, .Invalid, err
			}
			if err := big.add(&numerator, &numerator, digit); err != nil {
				return 0, .Invalid, err
			}
			total_digit_count += 1
			if saw_dot {
				fraction_digit_count += 1
			}
			if !saw_nonzero {
				if digit == 0 {
					leading_zero_count += 1
				} else {
					saw_nonzero = true
				}
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
	if total_digit_count == 0 || !previous_was_digit {
		return 0, .Invalid, nil
	}

	exponent := 0
	if index < len(text) && (text[index] == 'e' || text[index] == 'E') {
		index += 1
		exponent_negative := false
		if index < len(text) && (text[index] == '+' || text[index] == '-') {
			exponent_negative = text[index] == '-'
			index += 1
		}
		exponent_digit_count := 0
		previous_was_digit = false
		for index < len(text) {
			character := text[index]
			if '0' <= character && character <= '9' {
				if exponent < 1_000_000_000 {
					exponent = exponent*10 + int(character-'0')
				}
				exponent_digit_count += 1
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
		if exponent_digit_count == 0 || !previous_was_digit {
			return 0, .Invalid, nil
		}
		if exponent_negative {
			exponent = -exponent
		}
	}
	if index != len(text) {
		return 0, .Invalid, nil
	}

	sign_bit := u64(0x8000_0000_0000_0000) if negative else u64(0)
	if !saw_nonzero {
		return transmute(f64)sign_bit, .Success, nil
	}

	// Decimal order is one greater than floor(log10(abs(value))). These
	// conservative cutoffs avoid constructing impossible powers for huge exponents.
	decimal_order := total_digit_count-leading_zero_count-fraction_digit_count+exponent
	if decimal_order > 309 {
		return transmute(f64)(sign_bit | 0x7ff0_0000_0000_0000), .Overflow, nil
	}
	if decimal_order < -323 {
		return transmute(f64)sign_bit, .Success, nil
	}

	if err := big.set(&denominator, 1); err != nil {
		return 0, .Invalid, err
	}
	exponent -= fraction_digit_count
	numerator_to_use := &numerator
	if exponent > 0 {
		if err := big.int_pow_int(&scale, 10, exponent); err != nil {
			return 0, .Invalid, err
		}
		if err := big.mul(&scaled_numerator, &numerator, &scale); err != nil {
			return 0, .Invalid, err
		}
		numerator_to_use = &scaled_numerator
	} else if exponent < 0 {
		if err := big.int_pow_int(&denominator, 10, -exponent); err != nil {
			return 0, .Invalid, err
		}
	}

	if err := big.rat_set_frac(&rational, numerator_to_use, &denominator); err != nil {
		return 0, .Invalid, err
	}
	exact: bool
	if value, exact, conversion_error = big.rat_to_f64(&rational); conversion_error != nil {
		return 0, .Invalid, conversion_error
	}
	_ = exact
	bits := transmute(u64)value | sign_bit
	value = transmute(f64)bits
	if bits & 0x7ff0_0000_0000_0000 == 0x7ff0_0000_0000_0000 {
		return value, .Overflow, nil
	}
	return value, .Success, nil
}

when TOML_DECIMAL_GATE_TESTING {
	decimal_to_binary64_gate :: proc(
		text: string,
		allocator := context.allocator,
		individually_release_scratch := true,
	) -> (value: f64, valid, overflow: bool, conversion_error: big.Error) {
		status: Decimal_To_Binary64_Status
		value, status, conversion_error = decimal_to_binary64(
			text,
			allocator,
			individually_release_scratch,
		)
		return value, status != .Invalid && conversion_error == nil, status == .Overflow, conversion_error
	}
}
