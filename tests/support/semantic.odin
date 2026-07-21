package test_support

import "core:math"
import toml "../.."
import temporal "../../temporal"

semantic_value_equal :: proc(a, b: ^toml.Value) -> bool {
	switch a_value in a^ {
	case toml.String:
		b_value, ok := b^.(toml.String)
		return ok && a_value == b_value
	case toml.Integer:
		b_value, ok := b^.(toml.Integer)
		return ok && a_value == b_value
	case toml.Float:
		b_value, ok := b^.(toml.Float)
		if !ok {
			return false
		}
		if math.is_nan(f64(a_value)) || math.is_nan(f64(b_value)) {
			return math.is_nan(f64(a_value)) && math.is_nan(f64(b_value))
		}
		return transmute(u64)a_value == transmute(u64)b_value
	case toml.Boolean:
		b_value, ok := b^.(toml.Boolean)
		return ok && a_value == b_value
	case temporal.Offset_Date_Time:
		b_value, ok := b^.(temporal.Offset_Date_Time)
		return ok && a_value == b_value
	case temporal.Local_Date_Time:
		b_value, ok := b^.(temporal.Local_Date_Time)
		return ok && a_value == b_value
	case temporal.Local_Date:
		b_value, ok := b^.(temporal.Local_Date)
		return ok && a_value == b_value
	case temporal.Local_Time:
		b_value, ok := b^.(temporal.Local_Time)
		return ok && a_value == b_value
	case toml.Array:
		b_value, ok := b^.(toml.Array)
		if !ok || len(a_value) != len(b_value) {
			return false
		}
		for &child, index in a_value {
			if !semantic_value_equal(&child, &b_value[index]) {
				return false
			}
		}
		return true
	case toml.Table:
		b_value, ok := b^.(toml.Table)
		return ok && semantic_table_equal(a_value, b_value)
	}
	unreachable()
}

semantic_table_equal :: proc(a, b: toml.Table) -> bool {
	if len(a) != len(b) {
		return false
	}
	for &entry, index in a {
		if entry.key != b[index].key ||
		   !semantic_value_equal(&entry.value, &b[index].value) {
			return false
		}
	}
	return true
}
