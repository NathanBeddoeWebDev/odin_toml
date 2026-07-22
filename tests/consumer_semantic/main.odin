package consumer_semantic

import toml "../.."
import "external:temporal"

main :: proc() {
	date := temporal.Local_Date{year = 2026, month = 7, day = 1}
	date_err := temporal.validate(date)
	_ = date_err

	doc, parse_err := toml.parse("")
	_ = parse_err
	toml.destroy_document(&doc)

	success: toml.Parse_Error
	assert(success == nil)
}
