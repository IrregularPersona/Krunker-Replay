package main

// Small helpers around core:encoding/json.
//
// The map and replay files are heterogeneous JSON: arrays mix numbers,
// strings, nulls and nested arrays. Odin's json.Value is a tagged union,
// so these helpers just do the "give me a number/string/array, or a safe
// zero value if it isn't one" boilerplate in one place.
//
// NOTE: `switch x in v` over a union requires every variant to be handled
// (or a trailing default `case:`) -- we always fall through to a zero
// value for variants we don't care about in a given helper.

import "core:encoding/json"

get_f32 :: proc(v: json.Value) -> f32 {
	#partial switch x in v {
	case json.Integer:
		return f32(x)
	case json.Float:
		return f32(x)
	case:
		return 0
	}
}

get_i64 :: proc(v: json.Value) -> i64 {
	#partial switch x in v {
	case json.Integer:
		return x
	case json.Float:
		return i64(x)
	case:
		return 0
	}
}

get_bool :: proc(v: json.Value) -> bool {
	#partial switch x in v {
	case json.Boolean:
		return bool(x)
	case:
		return false
	}
}

get_string :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String:
		return string(x)
	case:
		return ""
	}
}

get_array :: proc(v: json.Value) -> json.Array {
	#partial switch x in v {
	case json.Array:
		return x
	case:
		return json.Array{}
	}
}

get_object :: proc(v: json.Value) -> json.Object {
	#partial switch x in v {
	case json.Object:
		return x
	case:
		return json.Object{}
	}
}

// Safe bounds-checked array access -- returns a nil Value (which every
// get_* helper above treats as a zero value) if the index is out of range.
// This matters a lot here: real telemetry lines routinely have shorter
// payloads than the "full" schema (e.g. "k" packets with an empty [] body).
arr_at :: proc(a: json.Array, i: int) -> json.Value {
	if i < 0 || i >= len(a) {
		return nil
	}
	return a[i]
}

