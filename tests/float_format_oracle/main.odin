package main

import "core:fmt"
import "core:os"
import toml "../.."
import test_support "../support"

emit :: proc(bits: u64) -> bool {
	buffer: [32]byte
	text, ok := toml.binary64_format_gate(transmute(f64)bits, buffer[:])
	if !ok {
		return false
	}
	fmt.printfln("%016x\t%s", bits, text)
	return true
}

main :: proc() {
	named := [?]u64{
		0x0000_0000_0000_0000,
		0x8000_0000_0000_0000,
		0x7ff0_0000_0000_0000,
		0xfff0_0000_0000_0000,
		0x7ff0_0000_0000_0001,
		0x7ff8_0000_0000_0000,
		0xffff_ffff_ffff_ffff,
		0x0000_0000_0000_0001,
		0x000f_ffff_ffff_ffff,
		0x0010_0000_0000_0000,
		0x3fef_ffff_ffff_ffff,
		0x3ff0_0000_0000_0000,
		0x3ff0_0000_0000_0001,
		0x4305_edd4_5e85_c45a,
		0x4315_72bb_837e_ea91,
		0x4315_de36_da3c_d0bf,
		0xc30d_3d13_99ec_316e,
		0x42d3_2d3f_e9f0_2778,
		0x4340_0000_0000_0000,
		0x7fef_ffff_ffff_ffff,
	}
	for bits in named {
		if !emit(bits) {
			os.exit(2)
		}
	}

	random := test_support.replay_random_init(0xbb67_ae85_84ca_a73b)
	for _ in 0..<4096 {
		if !emit(test_support.replay_u64(&random)) {
			os.exit(2)
		}
	}
}
