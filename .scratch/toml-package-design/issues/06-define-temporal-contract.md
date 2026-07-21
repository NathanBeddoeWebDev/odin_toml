# Define the four-kind temporal contract

Type: grilling
Status: resolved
Blocked by: 02, 03, 05

## Question

What exact public representations, validation invariants, precision rules, comparison/conversion operations, typed-binding rules, and encoding forms should represent TOML offset date-time, local date-time, local date, and local time without inventing absent date or timezone information?

## Answer

Put the reusable value and temporal-operation contract in a sibling repository package named `temporal`; `toml` depends on `temporal`, never the reverse. The temporal package owns allocation-free public value types, validation, comparison, and explicit `core:time` interoperability. TOML owns TOML syntax recognition, excess-precision truncation, typed binding, and deterministic TOML formatting. `temporal` initially exposes no textual parser/formatter, constructors, timezone database behavior, or general calendar arithmetic.

### Public representations

```odin
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
```

The types are transparent value structs. They never contain an optional date, optional time, timezone-region pointer, system-local marker, allocator-owned fraction, or inferred timezone. `Unknown` preserves RFC 3339 `-00:00`; it is not collapsed into known UTC.

### Invariants and errors

`temporal.validate` is an overload group over all five structs. Package-produced values are valid, while every public operation that consumes caller-constructed values validates them. Invalid input is rejected rather than clamped, normalized, or rolled into adjacent components. No redundant constructors or `is_valid` procedures are initially exposed.

- Year is `0000..9999`; Gregorian leap-year and month-length rules determine valid days.
- Month is `1..12`; hour is `0..23`; minute is `0..59`.
- Second is `0..60`. A value of `60` is preserved without maintaining an IERS announcement table; the package does not claim that a particular civil date was historically an announced leap second.
- Nanosecond is `0..<1_000_000_000`; the package must guard the Reference Odin validator edge that accepts exactly `1_000_000_000`.
- A known offset is an integral number of minutes in `-1439..1439`.
- An unknown offset requires `minutes == 0`; invalid enum representations are rejected.

Use one allocation-free `temporal.Error` enum:

```odin
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
```

TOML parse/marshal errors wrap the relevant temporal error while retaining their own source position or value path.

### Precision and decode normalization

The supported precision is exactly nanoseconds. A TOML fraction with one through nine digits is scaled to nanoseconds; digits after the ninth are discarded, never rounded. Fraction digit count is syntax rather than value state, so `.1` and `.100` produce the same value.

The strict TOML parser accepts all TOML 1.1 temporal forms and normalizes only syntax:

- `T`, `t`, and ASCII space date-time separators are equivalent.
- `Z`, `z`, and `+00:00` become a known zero offset.
- `-00:00` becomes an unknown offset.
- Omitted seconds become zero; a fraction remains invalid when seconds are omitted.
- Original separator, case, offset spelling, omitted-second spelling, and fractional digit count are not retained.
- Local values never acquire a date, offset, timezone, or machine-local interpretation.

### Comparison and conversion

`temporal.compare` overloads validated `Local_Date`, `Local_Time`, and `Local_Date_Time` operands and returns lexicographic civil ordering as `-1`, `0`, or `+1` plus `Error`. `temporal.compare_instant` compares validated `Offset_Date_Time` operands after applying their numeric UTC displacement; unknown offset has zero numeric displacement without losing its distinct stored state. If a leap second is present and the offsets differ, instant comparison returns `.Leap_Second_Not_Comparable`, because correct normalization would require leap-second history. Structural Odin `==` remains distinct from instant equivalence. There is no cross-kind comparison or implicit timezone conversion.

The only initial conversions are explicit `core:time` interoperability owned by `temporal`:

- `Local_Date` to/from `datetime.Date`;
- `Local_Time` to/from `datetime.Time`;
- `Local_Date_Time` to/from a `datetime.DateTime` whose `tz` is nil;
- `Offset_Date_Time` to `time.Time`;
- `time.Time` to `Offset_Date_Time` through an explicitly named UTC conversion or an explicitly supplied `UTC_Offset`.

Conversions reject invalid values, destination-inexpressible leap seconds, `time.Time` range overflow, non-local `datetime.DateTime` values, and any loss of required state. They never consult the machine timezone. Converting an unknown-offset value to its represented instant uses zero displacement but does not mutate or reclassify the source value. No conversion supplies a missing date, time, or offset.

### TOML typed binding

Typed unmarshal binds each TOML temporal kind only to the exact corresponding `temporal` type. It does not bind temporal values implicitly to `string`, `time.Time`, `datetime` types, another temporal kind, or named/distinct application wrappers. Those representations require an explicit custom codec. Typed marshal selects the TOML temporal kind from the exact `temporal` type after validation. Codec lookup still precedes any generic named-type handling.

### Deterministic TOML encoding

After validation, TOML encoding uses these canonical forms:

- local date: `YYYY-MM-DD`;
- local time: `HH:MM:SS[.fraction]`;
- local date-time: date, uppercase `T`, then local time;
- offset date-time: local date-time followed by uppercase `Z` for known zero, `±HH:MM` for another known offset, or `-00:00` for unknown offset.

Seconds are always emitted. A nonzero nanosecond field is emitted as one through nine decimal digits with trailing zeros removed; a zero field has no fraction. All numeric fields are fixed-width ASCII decimal except the variable-length fraction. Encoding never invents a timezone, converts a local value to an instant, or canonicalizes an unknown offset as UTC.
