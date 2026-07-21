package main

import "core:io"
import "core:strconv"
import toml "../.."
import temporal "../../temporal"

Adapter_Error_Kind :: enum u8 {
	Malformed_Input,
	Unsupported_Protocol_Value,
}

Adapter_Error :: union {
	Adapter_Error_Kind,
	io.Error,
}

write_text :: proc(writer: io.Writer, text: string) -> Adapter_Error {
	_, err := io.write_string(writer, text)
	if err != nil {
		return err
	}
	return nil
}

write_json_string :: proc(writer: io.Writer, text: string) -> Adapter_Error {
	_, err := io.write_quoted_string(writer, text, for_json = true)
	if err != nil {
		return err
	}
	return nil
}

write_tagged_text :: proc(
	writer: io.Writer,
	kind: string,
	text: string,
) -> Adapter_Error {
	if err := write_text(writer, `{"type":`); err != nil {
		return err
	}
	if err := write_json_string(writer, kind); err != nil {
		return err
	}
	if err := write_text(writer, `,"value":`); err != nil {
		return err
	}
	if err := write_json_string(writer, text); err != nil {
		return err
	}
	return write_text(writer, "}")
}

write_table :: proc(writer: io.Writer, table: toml.Table) -> Adapter_Error {
	if err := write_text(writer, "{"); err != nil {
		return err
	}
	for entry, index in table {
		if index > 0 {
			if err := write_text(writer, ","); err != nil {
				return err
			}
		}
		if err := write_json_string(writer, entry.key); err != nil {
			return err
		}
		if err := write_text(writer, ":"); err != nil {
			return err
		}
		if err := write_value(writer, entry.value); err != nil {
			return err
		}
	}
	return write_text(writer, "}")
}

write_array :: proc(writer: io.Writer, array: toml.Array) -> Adapter_Error {
	if err := write_text(writer, "["); err != nil {
		return err
	}
	for value, index in array {
		if index > 0 {
			if err := write_text(writer, ","); err != nil {
				return err
			}
		}
		if err := write_value(writer, value); err != nil {
			return err
		}
	}
	return write_text(writer, "]")
}

write_two_digits :: proc(buffer: []byte, index: ^int, value: u32) {
	buffer[index^] = byte(value/10)+'0'
	buffer[index^+1] = byte(value%10)+'0'
	index^ += 2
}

write_four_digits :: proc(buffer: []byte, index: ^int, value: u32) {
	buffer[index^] = byte(value/1000%10)+'0'
	buffer[index^+1] = byte(value/100%10)+'0'
	buffer[index^+2] = byte(value/10%10)+'0'
	buffer[index^+3] = byte(value%10)+'0'
	index^ += 4
}

append_local_date :: proc(value: temporal.Local_Date, buffer: []byte, index: ^int) {
	write_four_digits(buffer, index, u32(value.year))
	buffer[index^] = '-'
	index^ += 1
	write_two_digits(buffer, index, u32(value.month))
	buffer[index^] = '-'
	index^ += 1
	write_two_digits(buffer, index, u32(value.day))
}

format_local_date :: proc(value: temporal.Local_Date, buffer: []byte) -> string {
	index := 0
	append_local_date(value, buffer, &index)
	return string(buffer[:index])
}

append_local_time :: proc(value: temporal.Local_Time, buffer: []byte, index: ^int) {
	write_two_digits(buffer, index, u32(value.hour))
	buffer[index^] = ':'
	index^ += 1
	write_two_digits(buffer, index, u32(value.minute))
	buffer[index^] = ':'
	index^ += 1
	write_two_digits(buffer, index, u32(value.second))
	if value.nanosecond == 0 {
		return
	}
	buffer[index^] = '.'
	index^ += 1
	divisor := u32(100_000_000)
	for _ in 0..<9 {
		buffer[index^] = byte(value.nanosecond/divisor%10)+'0'
		index^ += 1
		divisor /= 10
	}
	for buffer[index^-1] == '0' {
		index^ -= 1
	}
}

format_local_time :: proc(value: temporal.Local_Time, buffer: []byte) -> string {
	index := 0
	append_local_time(value, buffer, &index)
	return string(buffer[:index])
}

format_local_date_time :: proc(value: temporal.Local_Date_Time, buffer: []byte) -> string {
	index := 0
	append_local_date(value.date, buffer, &index)
	buffer[index] = 'T'
	index += 1
	append_local_time(value.time, buffer, &index)
	return string(buffer[:index])
}

format_offset_date_time :: proc(value: temporal.Offset_Date_Time, buffer: []byte) -> string {
	local := format_local_date_time(value.local, buffer)
	index := len(local)
	if value.offset.kind == .Unknown {
		copy(buffer[index:], "-00:00")
		return string(buffer[:index+6])
	}
	if value.offset.minutes == 0 {
		buffer[index] = 'Z'
		return string(buffer[:index+1])
	}
	minutes := int(value.offset.minutes)
	buffer[index] = '+'
	if minutes < 0 {
		buffer[index] = '-'
		minutes = -minutes
	}
	index += 1
	write_two_digits(buffer, &index, u32(minutes/60))
	buffer[index] = ':'
	index += 1
	write_two_digits(buffer, &index, u32(minutes%60))
	return string(buffer[:index])
}

format_float :: proc(value: toml.Float, buffer: []byte) -> string {
	bits := transmute(u64)value
	exponent := bits>>52&0x7ff
	fraction := bits&0x000f_ffff_ffff_ffff
	if exponent == 0x7ff {
		if fraction != 0 {
			return "nan"
		}
		return "-inf" if bits>>63 != 0 else "inf"
	}
	text := strconv.write_float(buffer, f64(value), 'g', -1, 64)
	if len(text) > 0 && text[0] == '+' {
		return text[1:]
	}
	return text
}

write_value :: proc(writer: io.Writer, value: toml.Value) -> Adapter_Error {
	#partial switch item in value {
	case toml.String:
		return write_tagged_text(writer, "string", item)
	case toml.Integer:
		buffer: [32]byte
		return write_tagged_text(writer, "integer", strconv.write_int(buffer[:], i64(item), 10))
	case toml.Float:
		buffer: [64]byte
		return write_tagged_text(writer, "float", format_float(item, buffer[:]))
	case toml.Boolean:
		return write_tagged_text(writer, "bool", "true" if item else "false")
	case temporal.Offset_Date_Time:
		buffer: [64]byte
		return write_tagged_text(writer, "datetime", format_offset_date_time(item, buffer[:]))
	case temporal.Local_Date_Time:
		buffer: [64]byte
		return write_tagged_text(writer, "datetime-local", format_local_date_time(item, buffer[:]))
	case temporal.Local_Date:
		buffer: [16]byte
		return write_tagged_text(writer, "date-local", format_local_date(item, buffer[:]))
	case temporal.Local_Time:
		buffer: [32]byte
		return write_tagged_text(writer, "time-local", format_local_time(item, buffer[:]))
	case toml.Array:
		return write_array(writer, item)
	case toml.Table:
		return write_table(writer, item)
	}
	return Adapter_Error_Kind.Unsupported_Protocol_Value
}

write_document_to_writer :: proc(
	doc: ^toml.Document,
	writer: io.Writer,
) -> Adapter_Error {
	validated, clone_error := toml.clone_document(doc)
	if clone_error != nil {
		return Adapter_Error_Kind.Unsupported_Protocol_Value
	}
	defer toml.destroy_document(&validated)
	return write_table(writer, validated.root)
}

decode_to_writer :: proc(input: []byte, writer: io.Writer) -> Adapter_Error {
	doc, parse_error := toml.parse_bytes(input)
	if parse_error != nil {
		return Adapter_Error_Kind.Malformed_Input
	}
	defer toml.destroy_document(&doc)
	return write_document_to_writer(&doc, writer)
}
