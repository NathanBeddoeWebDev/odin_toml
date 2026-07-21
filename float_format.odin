package toml

import decimal "core:strconv/decimal"

@(private)
TOML_BINARY64_FORMAT_GATE_TESTING :: #config(TOML_BINARY64_FORMAT_GATE_TESTING, false)

@(private)
binary64_copy_literal :: proc(buffer: []byte, literal: string) -> (string, bool) {
	if len(buffer) < len(literal) {
		return "", false
	}
	count := copy(buffer, literal)
	return string(buffer[:count]), true
}

// Adapted from the shortest-rounding interval procedure in the pinned
// Reference Odin core:strconv implementation. This altered version owns only
// the significand decision; the TOML candidate spelling below is package code.
//
// Copyright (c) 2016-2025 Ginger Bill. All rights reserved.
//
// This software is provided 'as-is', without any express or implied
// warranty. In no event will the authors be held liable for any damages
// arising from the use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it
// freely, subject to the following restrictions:
//
// 1. The origin of this software must not be misrepresented; you must not
//    claim that you wrote the original software. If you use this software in
//    a product, an acknowledgment in the product documentation would be
//    appreciated but is not required.
// 2. Altered source versions must be plainly marked as such, and must not be
//    misrepresented as being the original software.
// 3. This notice may not be removed or altered from any source distribution.
@(private)
binary64_round_shortest :: proc(decimal_value: ^decimal.Decimal, mantissa: u64, exponent: int) {
	if mantissa == 0 {
		decimal_value.count = 0
		return
	}

	BINARY64_MANTISSA_BITS :: 52
	BINARY64_MINIMUM_EXPONENT :: -1022
	if exponent > BINARY64_MINIMUM_EXPONENT &&
	   332*(decimal_value.decimal_point-decimal_value.count) >=
	   100*(exponent-BINARY64_MANTISSA_BITS) {
		return
	}

	upper: decimal.Decimal
	decimal.assign(&upper, 2*mantissa+1)
	decimal.shift(&upper, exponent-BINARY64_MANTISSA_BITS-1)

	lower_mantissa: u64
	lower_exponent: int
	if mantissa > 1<<BINARY64_MANTISSA_BITS || exponent == BINARY64_MINIMUM_EXPONENT {
		lower_mantissa = mantissa-1
		lower_exponent = exponent
	} else {
		lower_mantissa = 2*mantissa-1
		lower_exponent = exponent-1
	}
	lower: decimal.Decimal
	decimal.assign(&lower, 2*lower_mantissa+1)
	decimal.shift(&lower, lower_exponent-BINARY64_MANTISSA_BITS-1)

	inclusive := mantissa&1 == 0
	for index in 0..<decimal_value.count {
		lower_digit := byte('0')
		if index < lower.count {
			lower_digit = lower.digits[index]
		}
		middle_digit := decimal_value.digits[index]
		upper_digit := byte('0')
		if index < upper.count {
			upper_digit = upper.digits[index]
		}

		can_round_down := lower_digit != middle_digit || inclusive && index+1 == lower.count
		can_round_up := middle_digit != upper_digit &&
		                (inclusive || middle_digit+1 < upper_digit || index+1 < upper.count)
		if can_round_down && can_round_up {
			decimal.round(decimal_value, index+1)
			return
		}
		if can_round_down {
			decimal.round_down(decimal_value, index+1)
			return
		}
		if can_round_up {
			decimal.round_up(decimal_value, index+1)
			return
		}
	}
}

@(private)
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

	reversed: [3]byte
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

@(private)
binary64_fixed_candidate :: proc(decimal_value: ^decimal.Decimal, buffer: []byte) -> int {
	index := 0
	switch {
	case decimal_value.decimal_point <= 0:
		buffer[index] = '0'
		index += 1
		buffer[index] = '.'
		index += 1
		for _ in 0..<(-decimal_value.decimal_point) {
			buffer[index] = '0'
			index += 1
		}
		index += copy(buffer[index:], decimal_value.digits[:decimal_value.count])
	case decimal_value.decimal_point >= decimal_value.count:
		index += copy(buffer[index:], decimal_value.digits[:decimal_value.count])
		for _ in decimal_value.count..<decimal_value.decimal_point {
			buffer[index] = '0'
			index += 1
		}
		buffer[index] = '.'
		index += 1
		buffer[index] = '0'
		index += 1
	case:
		index += copy(buffer[index:], decimal_value.digits[:decimal_value.decimal_point])
		buffer[index] = '.'
		index += 1
		index += copy(
			buffer[index:],
			decimal_value.digits[decimal_value.decimal_point:decimal_value.count],
		)
	}
	return index
}

@(private)
binary64_scientific_candidate :: proc(decimal_value: ^decimal.Decimal, buffer: []byte) -> int {
	index := 0
	buffer[index] = decimal_value.digits[0]
	index += 1
	if decimal_value.count > 1 {
		buffer[index] = '.'
		index += 1
		index += copy(buffer[index:], decimal_value.digits[1:decimal_value.count])
	}
	write_decimal_exponent(buffer, &index, decimal_value.decimal_point-1)
	return index
}

@(private)
binary64_format :: proc(value: f64, buffer: []byte) -> (string, bool) {
	bits := transmute(u64)value
	negative := bits>>63 != 0
	exponent_bits := (bits >> 52) & 0x7ff
	fraction := bits & 0x000f_ffff_ffff_ffff

	if exponent_bits == 0x7ff {
		if fraction != 0 {
			return binary64_copy_literal(buffer, "nan")
		}
		return binary64_copy_literal(buffer, "-inf" if negative else "inf")
	}
	if exponent_bits == 0 && fraction == 0 {
		return binary64_copy_literal(buffer, "-0.0" if negative else "0.0")
	}

	mantissa := fraction
	exponent := int(exponent_bits)
	if exponent_bits == 0 {
		exponent = 1
	} else {
		mantissa |= 0x0010_0000_0000_0000
	}
	exponent -= 1023

	decimal_value: decimal.Decimal
	decimal.assign(&decimal_value, mantissa)
	decimal.shift(&decimal_value, exponent-52)
	binary64_round_shortest(&decimal_value, mantissa, exponent)

	fixed_buffer: [384]byte
	scientific_buffer: [24]byte
	fixed_count := binary64_fixed_candidate(&decimal_value, fixed_buffer[:])
	scientific_count := binary64_scientific_candidate(&decimal_value, scientific_buffer[:])
	selected := fixed_buffer[:fixed_count]
	if scientific_count < fixed_count {
		selected = scientific_buffer[:scientific_count]
	}

	required_count := len(selected)
	if negative {
		required_count += 1
	}
	if len(buffer) < required_count {
		return "", false
	}
	index := 0
	if negative {
		buffer[index] = '-'
		index += 1
	}
	index += copy(buffer[index:], selected)
	return string(buffer[:index]), true
}

when TOML_BINARY64_FORMAT_GATE_TESTING {
	binary64_format_gate :: proc(value: f64, buffer: []byte) -> (string, bool) {
		return binary64_format(value, buffer)
	}
}
