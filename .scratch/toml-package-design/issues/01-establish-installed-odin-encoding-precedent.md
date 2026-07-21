# Establish the installed Odin encoding API and memory precedent

Type: research
Status: resolved
Blocked by: none

## Question

Which public API shapes, reflection/tag behavior, error conventions, custom-codec mechanisms, allocator flows, ownership transfers, destruction procedures, writer APIs, and tests in the locally installed `core:encoding/json` and `core:encoding/ini` should the standalone `toml` design mirror, and which observed quirks should it deliberately avoid?

## Answer

Use JSON's layered precedent: owned generic values with deep clone/destruction, separate reflection-based marshal/unmarshal, explicit allocators defaulting to `context.allocator`, and writer-first encoding wrapped by allocated-return helpers. Use conventional `toml` tags and value-based error unions that distinguish syntax/data, allocation, and I/O failures. INI's borrowed iterator demonstrates useful explicit borrowing, but its permissive parsing, unordered output, dropped writer errors, and mixed-allocator destructor are precedents to avoid. Also avoid JSON's accidentally broad public helper surface, surprising permissive default, package-global caller-owned codec state, incomplete duplicate checks, and fragile partial-allocation paths. Every final API needs a complete owner/allocator/lifetime/invalidation/release contract and allocator-failure tests.

Research asset: [Installed Odin encoding precedent](../research/odin-encoding-precedent.md)
