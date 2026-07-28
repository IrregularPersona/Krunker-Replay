package main

// Replay telemetry log parsing, per SYSTEM CONTEXT & SPECIFICATION section 3.
//
// Each line of the log is one JSON array: [Timestamp_MS, [OpCode, ...Payload]].
// Real logs (see data/replay_log.2026-07-26) carry a lot of opcodes the
// engine doesn't care about (chat, shop data, "ready", etc) -- those are
// parsed once, tagged .Unknown, and simply skipped during playback.
//
// IMPORTANT MEMORY NOTE: RawEvent.data borrows directly from the json.Value
// tree produced by json.parse_string for that line. We deliberately never
// call json.destroy_value on successfully-parsed lines, since the whole
// replay (a few thousand short-lived lines, loaded once at startup) is kept
// alive for the life of the program -- freeing it would invalidate every
// RawEvent.data slice still in use.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

PacketKind :: enum {
	Unknown,
	Roster,        // "0"   -- roster sync
	ChatJoin,      // "chi" -- chat / join notification
	SpawnManifest, // "en"  -- player spawn manifest
	Position,      // "k"   -- 40Hz positional telemetry
	Tracer,        // "9"   -- bullet tracer
	Damage,        // "4"   -- damage / hit marker
}

RawEvent :: struct {
	t:    i64,
	kind: PacketKind,
	data: json.Array, // data[0] is the opcode string, data[1..] is payload
}

Replay :: struct {
	events:   [dynamic]RawEvent,
	duration: i64,
}

classify_opcode :: proc(op: string) -> PacketKind {
	switch op {
	case "0":
		return .Roster
	case "chi":
		return .ChatJoin
	case "en":
		return .SpawnManifest
	case "k":
		return .Position
	case "9":
		return .Tracer
	case "4":
		return .Damage
	}
	return .Unknown
}

load_replay :: proc(path: string) -> (Replay, bool) {
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if data == nil {
		fmt.eprintln("replay: failed to read", path, read_err)
		return Replay{}, false
	}
	defer delete(data)

	text := string(data)
	lines := strings.split_lines(text)
	defer delete(lines)

	replay: Replay
	parsed_lines, skipped := 0, 0

	for raw_line in lines {
		line := strings.trim_space(raw_line)
		if len(line) == 0 {
			continue
		}

		value, err := json.parse_string(line)
		if err != .None {
			skipped += 1
			continue
		}

		top := get_array(value)
		if len(top) < 2 {
			skipped += 1
			continue
		}

		t := get_i64(top[0])
		inner := get_array(top[1])
		if len(inner) < 1 {
			skipped += 1
			continue
		}

		op := get_string(inner[0])

		ev: RawEvent
		ev.t = t
		ev.kind = classify_opcode(op)
		ev.data = inner

		append(&replay.events, ev)
		if t > replay.duration {
			replay.duration = t
		}
		parsed_lines += 1
	}

	fmt.println("replay:", parsed_lines, "events parsed,", skipped, "lines skipped, duration =", replay.duration, "ms")
	return replay, true
}

destroy_replay :: proc(r: ^Replay) {
	delete(r.events)
}
