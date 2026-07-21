package semantic_lifecycle

import toml "../.."

empty_document_owner :: proc() {
	doc, err := toml.parse_string("")
	assert(err == nil)
	assert(doc.root.allocator.procedure != nil)

	// doc is the owner. An ordinary assignment would only be a borrowed alias.
	toml.destroy_document(&doc)
	assert(doc.allocator.procedure == nil)
}

borrowed_lookup_and_owned_clone :: proc() {
	allocator := context.allocator
	root, allocation_error := make(toml.Table, 1, allocator)
	assert(allocation_error == nil)
	root[0] = {key = "", value = toml.Value(toml.Integer(42))}
	doc := toml.Document{root = root, allocator = allocator}

	borrowed, found := toml.get(&doc.root, "")
	assert(found)
	// borrowed belongs to doc and must never be passed to destroy_value.
	owned, clone_error := toml.clone_value(borrowed, allocator)
	assert(clone_error == nil)

	// The deep clone is a standalone owner and uses its selected allocator.
	toml.destroy_value(&owned, allocator)
	// The document still owns the value returned by get.
	toml.destroy_document(&doc)
}

main :: proc() {
	empty_document_owner()
	borrowed_lookup_and_owned_clone()
}
