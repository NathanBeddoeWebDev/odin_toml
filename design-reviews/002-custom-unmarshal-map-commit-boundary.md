# Design review 002 — custom unmarshal ownership refines the map commit boundary

Status: resolved by approved contract clarification

## Resolution

Generic map installation keeps its complete-key/value-pair commit rule until a custom unmarshaler nested in the staged value succeeds. The first successful custom unmarshaler commits the containing map entry to the application because its opaque installed ownership transfers immediately and the package has no codec-specific destructor with which to roll it back.

Implementation preallocates enough map capacity for the complete source table, installs an owned key with an exact-zero final value slot, and recursively populates that stable slot. If installation fails before any custom unmarshaler in the value succeeds, the package cleans and removes the staged entry as before. If a custom unmarshaler has succeeded, a later allocation or callback failure leaves the entry caller-owned and recursively cleanable; the currently failing callback must still clean and restore its complete supplied slot to exact zero.

This is a narrow exception to complete-pair map atomicity, not permission for a failing callback to leave partial state. Successful callback slots are independent ownership commits. Map keys still never consult codecs, traversal remains in semantic insertion order, and no custom destructor is added to the public interface.

## Conflict resolved

The earlier contracts could not all hold for a custom unmarshaler nested inside an uninstalled map value:

1. issue 11 staged the complete key/value pair under package ownership until complete;
2. issue 12 transferred opaque callback ownership immediately on success;
3. callbacks run exactly once; and
4. the package intentionally has no generic or codec-specific destructor.

If one nested callback succeeded and a later sibling failed, the package could neither destroy the successful opaque value nor transfer it from unreachable temporary storage while retaining complete-pair atomicity.

## Alternatives rejected

- **Codec-specific destructor callback:** enlarges the frozen interface, couples rollback to application code and user-data lifetime, and makes TOML responsible for invoking opaque destruction correctly.
- **Two-phase prepare/commit callback:** materially complicates every codec and still needs rollback ownership for prepared values.
- **Forbid codecs below map values:** narrows exact-type lookup at every typed node and violates the approved codec contract.
- **Always retain incomplete map entries:** unnecessarily weakens generic map atomicity before any opaque ownership has committed.

## Acceptance consequences

Focused tests must prove:

- direct callback failure restores its final map value slot and removes the otherwise uncommitted entry;
- generic failures before callback success preserve complete-pair rollback;
- a successful nested callback followed by a later failure retains one caller-owned, recursively cleanable entry with the failing slot exact zero;
- fail-at-N cleanup, semantic insertion order, selected allocator provenance, and stable no-growth map slots hold on the pinned Reference Odin runtime.
