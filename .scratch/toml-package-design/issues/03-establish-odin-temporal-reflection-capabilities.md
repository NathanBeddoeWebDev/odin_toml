# Establish Odin temporal and reflection capabilities

Type: research
Status: resolved
Blocked by: none

## Question

Which APIs and language capabilities available in the installed Odin version can represent and validate TOML's four temporal kinds, inspect and assign reflected values, read struct tags, detect nil/unsupported values, and support custom typed conversion without violating allocator ownership?

## Answer

Installed `core:time/datetime` provides useful civil date/time components and Gregorian validation, but `time.Time` is a range-limited instant and no built-in type faithfully carries TOML's fixed numeric offset, unknown negative-zero offset, leap second, or arbitrary fractional precision. TOML-specific public temporal types are therefore required; nanoseconds can use Odin components, while precision beyond nine digits needs an explicit truncation or owned-digit policy. TOML must parse and format these forms itself and guard a local validation edge where Odin accepts nanosecond `1_000_000_000`. Reflection exposes type kinds, fields, tags, destination-backed `any`, and exact `typeid` maps, but no general ownership-safe setter. Typed assignment needs exact-kind logic, codec lookup before named-type unwrapping, and explicit allocation transfer. `reflect.is_nil` checks all-zero storage rather than semantic nil and must not drive nil or omit behavior.

Research asset: [Odin temporal and reflection capabilities](../research/odin-temporal-reflection.md)
