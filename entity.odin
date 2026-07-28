package main

// Entity management, jitter-buffered snapshot interpolation, and playback
// control, per SYSTEM CONTEXT & SPECIFICATION section 4.

import "core:encoding/json"
import "core:fmt"
import rl "vendor:raylib"

PLAYER_WIDTH        :: 4.0
PLAYER_HEIGHT       :: 11.0
PLAYER_DEPTH        :: 4.0
TRACER_LIFETIME_MS  :: 150.0
DEFAULT_JITTER_MS   :: 100

Snapshot :: struct {
	t:     i64,
	pos:   rl.Vector3,
	yaw:   f32,
	pitch: f32,
	flags: int,
}

PlayerEntity :: struct {
	sid:          string,
	name:         string,
	health:       int,
	max_health:   int,
	is_spectator: bool,
	snapshots:    [dynamic]Snapshot,

	// interpolated render state, refreshed every frame by interpolate_players
	render_pos:   rl.Vector3,
	render_yaw:   f32,
	render_pitch: f32,
	has_render:   bool,
}

Tracer :: struct {
	start, end: rl.Vector3,
	spawn_t:    i64,
}

World :: struct {
	game_map: GameMap,
	replay:   Replay,

	players: map[string]PlayerEntity,
	tracers: [dynamic]Tracer,

	playback_t: f64, // ms, fractional
	playing:    bool,
	speed:      f32,
	jitter_ms:  i64,

	event_cursor: int,
	last_hit_t:   i64,

	// Distance-based culling radius (world units) for map geometry, and the
	// loaded custom prop meshes (barrel/crate/powercell) keyed by the map's
	// `i` field -- see models.odin.
	render_distance: f32,
	prop_models:     PropModels,
}

DEFAULT_RENDER_DISTANCE :: 300.0

make_world :: proc(m: GameMap, r: Replay) -> World {
	w: World
	w.game_map = m
	w.replay = r
	w.players = make(map[string]PlayerEntity)
	w.speed = 1.0
	w.jitter_ms = DEFAULT_JITTER_MS
	w.render_distance = DEFAULT_RENDER_DISTANCE
	w.prop_models = load_prop_models(&w.game_map)
	return w
}

reset_world_state :: proc(w: ^World) {
	for _, p in w.players {
		pp := p
		delete(pp.snapshots)
	}
	delete(w.players)
	w.players = make(map[string]PlayerEntity)
	clear(&w.tracers)
	w.event_cursor = 0
}

get_or_create_player :: proc(w: ^World, sid: string) -> ^PlayerEntity {
	if _, ok := w.players[sid]; !ok {
		w.players[sid] = PlayerEntity{sid = sid, name = sid, health = 100, max_health = 100}
	}
	return &w.players[sid]
}

// Applies the state-mutating side effects of a single telemetry packet.
// Used both for normal forward playback and for full re-simulation on seek.
apply_event :: proc(w: ^World, ev: RawEvent) {
	switch ev.kind {

	case .Roster:
		// ["0", [SID,X,Y,Z,Username,ClassID,Health,MaxHealth,SkinID,...], seq]
		if len(ev.data) < 2 do return
		inner := get_array(ev.data[1])
		if len(inner) < 8 do return
		sid := get_string(arr_at(inner, 0))
		if sid == "" do return
		p := get_or_create_player(w, sid)
		if name := get_string(arr_at(inner, 4)); name != "" {
			p.name = name
		}
		p.health = int(get_i64(arr_at(inner, 6)))
		p.max_health = int(get_i64(arr_at(inner, 7)))
		snap := Snapshot{
			t   = ev.t,
			pos = rl.Vector3{get_f32(arr_at(inner, 1)), get_f32(arr_at(inner, 2)), get_f32(arr_at(inner, 3))},
		}
		append(&p.snapshots, snap)

	case .ChatJoin:
		// ["chi", SID, null, ["server.message.join","PlayerName"], TypeID]
		// (also seen: ["chi", SID, null, "event.someString", TypeID] -- not a join)
		if len(ev.data) < 4 do return
		sid := get_string(arr_at(ev.data, 1))
		msg_v := arr_at(ev.data, 3)
		if arr, is_arr := msg_v.(json.Array); is_arr {
			if len(arr) >= 2 && get_string(arr_at(arr, 0)) == "server.message.join" {
				p := get_or_create_player(w, sid)
				p.name = get_string(arr_at(arr, 1))
			}
		}

	case .SpawnManifest:
		// ["en", loadout_array_34_items, ...] -- spectator flag at index 6.
		// SID placement inside the loadout array is not standardized across
		// protocol variants; when present at index 0 we use it directly,
		// otherwise this packet only informs HUD/spectator-mode state and
		// entity creation is left to "0"/"k" packets.
		if len(ev.data) < 2 do return
		loadout := get_array(ev.data[1])
		if len(loadout) < 7 do return
		is_spec := get_i64(arr_at(loadout, 6)) == 1
		if sid := get_string(arr_at(loadout, 0)); sid != "" {
			p := get_or_create_player(w, sid)
			p.is_spectator = is_spec
		}

	case .Position:
		// ["k", [SID,X,Y,Z,Yaw,Pitch,SpeedDelta,Flags,AnimID,WeaponID,ADS,Ammo], Health, SnapshotID]
		if len(ev.data) < 2 do return
		inner := get_array(ev.data[1])
		if len(inner) < 8 do return // guards against empty-payload keepalive "k" packets
		sid := get_string(arr_at(inner, 0))
		if sid == "" do return
		p := get_or_create_player(w, sid)
		snap := Snapshot{
			t     = ev.t,
			pos   = rl.Vector3{get_f32(arr_at(inner, 1)), get_f32(arr_at(inner, 2)), get_f32(arr_at(inner, 3))},
			yaw   = get_f32(arr_at(inner, 4)),
			pitch = get_f32(arr_at(inner, 5)),
			flags = int(get_i64(arr_at(inner, 7))),
		}
		append(&p.snapshots, snap)
		if len(ev.data) >= 3 {
			p.health = int(get_i64(ev.data[2]))
		}

	case .Tracer:
		// ["9", [SID,StartX,StartY,StartZ,Pitch,Yaw,EndX,EndY,EndZ,...]]
		if len(ev.data) < 2 do return
		inner := get_array(ev.data[1])
		if len(inner) < 9 do return
		tr := Tracer{
			start   = rl.Vector3{get_f32(arr_at(inner, 1)), get_f32(arr_at(inner, 2)), get_f32(arr_at(inner, 3))},
			end     = rl.Vector3{get_f32(arr_at(inner, 6)), get_f32(arr_at(inner, 7)), get_f32(arr_at(inner, 8))},
			spawn_t = ev.t,
		}
		append(&w.tracers, tr)

	case .Damage:
		// Hit-marker pulse; exact payload layout is not standardized in the
		// spec, so we only record the timestamp for a HUD flash effect.
		w.last_hit_t = ev.t

	case .Unknown:
	// ignored opcodes (chat text, shop data, session bootstrap, etc.)
	}
}

// Jumps playback to an arbitrary point in time by resetting all entity
// state and re-simulating every event up to that point. The log here is a
// few thousand lines, so a full re-simulation on every scrub is cheap and
// much simpler (and more correct) than trying to diff state backwards.
seek_to :: proc(w: ^World, target_ms: f64) {
	reset_world_state(w)
	clamped := target_ms
	if clamped < 0 do clamped = 0
	if clamped > f64(w.replay.duration) do clamped = f64(w.replay.duration)
	w.playback_t = clamped

	for ev, i in w.replay.events {
		if f64(ev.t) > w.playback_t {
			w.event_cursor = i
			return
		}
		apply_event(w, ev)
	}
	w.event_cursor = len(w.replay.events)
}

update_playback :: proc(w: ^World, dt: f32) {
	if w.playing {
		w.playback_t += f64(dt) * 1000.0 * f64(w.speed)
		if w.playback_t >= f64(w.replay.duration) {
			w.playback_t = f64(w.replay.duration)
			w.playing = false
		}
	}

	for w.event_cursor < len(w.replay.events) {
		ev := w.replay.events[w.event_cursor]
		if f64(ev.t) > w.playback_t do break
		apply_event(w, ev)
		w.event_cursor += 1
	}

	interpolate_players(w)
}

lerp_f32 :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

lerp_vec3 :: proc(a, b: rl.Vector3, t: f32) -> rl.Vector3 {
	return rl.Vector3{lerp_f32(a.x, b.x, t), lerp_f32(a.y, b.y, t), lerp_f32(a.z, b.z, t)}
}

// Shortest-path angle interpolation (handles the wrap at +/-180).
// NOTE: the spec leaves Yaw/Pitch units ambiguous ("scaled integer or
// degrees"); sample telemetry looks degree-like, so this assumes degrees.
lerp_angle_deg :: proc(a, b, t: f32) -> f32 {
	diff := b - a
	for diff > 180 do diff -= 360
	for diff < -180 do diff += 360
	return a + diff * t
}

// Implements spec section 4.3: a ~100ms jitter buffer, LERP for position,
// and shortest-path interpolation ("SLERP" in spirit) for yaw/pitch,
// between the two 40Hz snapshots bracketing the delayed render time.
interpolate_players :: proc(w: ^World) {
	render_t := w.playback_t - f64(w.jitter_ms)

	for sid, _ in w.players {
		p := &w.players[sid]
		n := len(p.snapshots)
		if n == 0 {
			p.has_render = false
			continue
		}

		// Find prev = last snapshot with t <= render_t, next = first with t > render_t.
		prev_i := -1
		next_i := -1
		for i := 0; i < n; i += 1 {
			if f64(p.snapshots[i].t) <= render_t {
				prev_i = i
			} else {
				next_i = i
				break
			}
		}

		switch {
		case prev_i == -1:
			// Still inside the jitter buffer / before first snapshot: hold at the earliest known sample.
			s := p.snapshots[0]
			p.render_pos, p.render_yaw, p.render_pitch = s.pos, s.yaw, s.pitch
		case next_i == -1:
			// No newer snapshot yet: hold at the latest known sample.
			s := p.snapshots[prev_i]
			p.render_pos, p.render_yaw, p.render_pitch = s.pos, s.yaw, s.pitch
		case:
			a := p.snapshots[prev_i]
			b := p.snapshots[next_i]
			span := f64(b.t - a.t)
			frac: f32 = 0
			if span > 0 {
				frac = f32((render_t - f64(a.t)) / span)
				if frac < 0 do frac = 0
				if frac > 1 do frac = 1
			}
			p.render_pos = lerp_vec3(a.pos, b.pos, frac)
			p.render_yaw = lerp_angle_deg(a.yaw, b.yaw, frac)
			p.render_pitch = lerp_angle_deg(a.pitch, b.pitch, frac)
		}
		p.has_render = true
	}
}
