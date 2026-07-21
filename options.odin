package toml

Parse_Options :: struct {
	max_depth: int,
}

Marshal_Options :: struct {
	max_depth: int,
	codecs:    ^Codec_Registry,
}

Unmarshal_Options :: struct {
	max_depth:             int,
	reject_unknown_fields: bool,
	codecs:                ^Codec_Registry,
}
