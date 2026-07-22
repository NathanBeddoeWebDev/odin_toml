package toml

import "core:mem"
import temporal "vendor/temporal"

Integer :: i64
Float   :: f64
Boolean :: bool
String  :: string

Array :: distinct [dynamic]Value
Table :: distinct [dynamic]Entry

Entry :: struct {
	key:   String,
	value: Value,
}

Value :: union #no_nil {
	String,
	Integer,
	Float,
	Boolean,
	temporal.Offset_Date_Time,
	temporal.Local_Date_Time,
	temporal.Local_Date,
	temporal.Local_Time,
	Array,
	Table,
}

Value_Kind :: enum u8 {
	String,
	Integer,
	Float,
	Boolean,
	Offset_Date_Time,
	Local_Date_Time,
	Local_Date,
	Local_Time,
	Array,
	Table,
}

Document :: struct {
	root:      Table,
	allocator: mem.Allocator,
}

Path_Index :: distinct int

Path_Segment :: union #no_nil {
	String,
	Path_Index,
}

Path :: distinct []Path_Segment
