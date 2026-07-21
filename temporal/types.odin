package temporal

Local_Date :: struct {
	year:  u16,
	month: u8,
	day:   u8,
}

Local_Time :: struct {
	hour:       u8,
	minute:     u8,
	second:     u8,
	nanosecond: u32,
}

Local_Date_Time :: struct {
	date: Local_Date,
	time: Local_Time,
}

Offset_Kind :: enum u8 {
	Known,
	Unknown,
}

UTC_Offset :: struct {
	kind:    Offset_Kind,
	minutes: i16,
}

Offset_Date_Time :: struct {
	local:  Local_Date_Time,
	offset: UTC_Offset,
}

Error :: enum {
	None,
	Invalid_Year,
	Invalid_Month,
	Invalid_Day,
	Invalid_Hour,
	Invalid_Minute,
	Invalid_Second,
	Invalid_Nanosecond,
	Invalid_Offset_Kind,
	Invalid_Offset_Minutes,
	Invalid_Unknown_Offset,
	Unsupported_Leap_Second,
	Out_Of_Range,
	Timezone_Not_Local,
	Leap_Second_Not_Comparable,
}
