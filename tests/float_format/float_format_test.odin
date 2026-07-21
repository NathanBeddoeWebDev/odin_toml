package float_format_test

import "core:math/big"
import "core:testing"
import toml "../.."
import test_support "../support"

expect_format :: proc(t: ^testing.T, bits: u64, expected: string) {
	buffer: [32]byte
	actual, ok := toml.binary64_format_gate(transmute(f64)bits, buffer[:])
	testing.expect(t, ok)
	testing.expect_value(t, actual, expected)
}

@(test)
test_binary64_format_finite_values_choose_canonical_candidate :: proc(t: ^testing.T) {
	cases := [?]struct {
		bits:     u64,
		expected: string,
	}{
		{0x3ff0_0000_0000_0000, "1.0"},
		{0xbff0_0000_0000_0000, "-1.0"},
		{0x3ff8_0000_0000_0000, "1.5"},
		{0x4024_0000_0000_0000, "1e1"},
		{0x4059_0000_0000_0000, "1e2"},
		{0x405e_c000_0000_0000, "123.0"},
		{0x3fb9_9999_9999_999a, "0.1"},
		{0x3f84_7ae1_47ae_147b, "0.01"},
		{0x3f50_624d_d2f1_a9fc, "1e-3"},
		{0x3f1a_36e2_eb1c_432d, "1e-4"},
		{0x412e_8480_0000_0000, "1e6"},
		{0x4415_af1d_78b5_8c40, "1e20"},
		{0x3eb0_c6f7_a0b5_ed8d, "1e-6"},
		{0x3ff3_c0ca_428c_59fb, "1.2345678901234567"},
	}
	for test_case in cases {
		expect_format(t, test_case.bits, test_case.expected)
	}
}

@(test)
test_binary64_format_shortest_ties_choose_closest_then_even_decimal :: proc(t: ^testing.T) {
	// These named raw values reach exact shortest-decimal ties. The expected
	// final digit is the even choice independently confirmed by the pinned oracle.
	cases := [?]struct {
		bits:     u64,
		expected: string,
	}{
		{0x4305_edd4_5e85_c45a, "771558860699787.2"},
		{0x4315_72bb_837e_ea91, "1509281050376868.2"},
		{0x4315_de36_da3c_d0bf, "1538825420485679.8"},
		{0xc30d_3d13_99ec_316e, "-1028741090084397.8"},
		{0x42d3_2d3f_e9f0_2778, "84340267008157.88"},
	}
	for test_case in cases {
		expect_format(t, test_case.bits, test_case.expected)
	}
}

@(test)
test_binary64_format_named_boundaries_use_shortest_decimal :: proc(t: ^testing.T) {
	cases := [?]struct {
		bits:     u64,
		expected: string,
	}{
		{0x0000_0000_0000_0001, "5e-324"},
		{0x000f_ffff_ffff_ffff, "2.225073858507201e-308"},
		{0x0010_0000_0000_0000, "2.2250738585072014e-308"},
		{0x7fef_ffff_ffff_ffff, "1.7976931348623157e308"},
		{0x3fef_ffff_ffff_ffff, "0.9999999999999999"},
		{0x3ff0_0000_0000_0001, "1.0000000000000002"},
		{0x4340_0000_0000_0000, "9007199254740992.0"},
		{0x3e60_0000_0000_0000, "2.9802322387695312e-8"},
		{0x4830_f0cf_064d_d592, "5.764607523034235e39"},
		{0x0000_0000_000f_4240, "4.940656e-318"},
		{0x7fe0_0000_0000_0000, "8.98846567431158e307"},
	}
	for test_case in cases {
		expect_format(t, test_case.bits, test_case.expected)
	}
	expect_format(t, 0xffef_ffff_ffff_ffff, "-1.7976931348623157e308")
}

@(test)
test_binary64_format_is_stable_and_supplementally_reparses_samples :: proc(t: ^testing.T) {
	random := test_support.replay_random_init(0x3c6e_f372_fe94_f82b)
	for _ in 0..<1024 {
		bits := test_support.replay_u64(&random)
		first_buffer, second_buffer: [32]byte
		first, first_ok := toml.binary64_format_gate(transmute(f64)bits, first_buffer[:])
		second, second_ok := toml.binary64_format_gate(transmute(f64)bits, second_buffer[:])
		testing.expect(t, first_ok)
		testing.expect(t, second_ok)
		testing.expect_value(t, first, second)

		exponent := bits & 0x7ff0_0000_0000_0000
		magnitude := bits & 0x7fff_ffff_ffff_ffff
		if exponent != 0x7ff0_0000_0000_0000 && magnitude != 0 {
			reparsed, valid, overflow, conversion_error := toml.decimal_to_binary64_gate(first)
			testing.expect_value(t, conversion_error, big.Error.None)
			testing.expect(t, valid)
			testing.expect(t, !overflow)
			testing.expect_value(t, transmute(u64)reparsed, bits)
		}
	}
}

@(test)
test_binary64_format_normalizes_sampled_nan_payloads :: proc(t: ^testing.T) {
	random := test_support.replay_random_init(0xa54f_f53a_5f1d_36f1)
	for _ in 0..<1024 {
		payload := test_support.replay_u64(&random) & 0x000f_ffff_ffff_ffff
		if payload == 0 {
			payload = 1
		}
		expect_format(t, 0x7ff0_0000_0000_0000 | payload, "nan")
		expect_format(t, 0xfff0_0000_0000_0000 | payload, "nan")
	}
}

@(test)
test_binary64_format_reports_insufficient_output_capacity :: proc(t: ^testing.T) {
	exact: [22]byte
	actual, ok := toml.binary64_format_gate(
		transmute(f64)u64(0x7fef_ffff_ffff_ffff),
		exact[:],
	)
	testing.expect(t, ok)
	testing.expect_value(t, actual, "1.7976931348623157e308")

	short: [21]byte
	actual, ok = toml.binary64_format_gate(
		transmute(f64)u64(0x7fef_ffff_ffff_ffff),
		short[:],
	)
	testing.expect(t, !ok)
	testing.expect_value(t, actual, "")
}

@(test)
test_binary64_format_special_values_have_canonical_spellings :: proc(t: ^testing.T) {
	cases := [?]struct {
		bits:     u64,
		expected: string,
	}{
		{0x0000_0000_0000_0000, "0.0"},
		{0x8000_0000_0000_0000, "-0.0"},
		{0x7ff0_0000_0000_0000, "inf"},
		{0xfff0_0000_0000_0000, "-inf"},
		{0x7ff8_0000_0000_0000, "nan"},
		{0xfff8_0000_0000_0001, "nan"},
		{0x7ff0_0000_0000_0001, "nan"},
		{0xffff_ffff_ffff_ffff, "nan"},
	}
	for test_case in cases {
		expect_format(t, test_case.bits, test_case.expected)
	}
}
