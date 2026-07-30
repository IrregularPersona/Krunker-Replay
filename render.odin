package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

TEAM_COLORS := [3]rl.Color{rl.SKYBLUE, rl.ORANGE, rl.LIME}

deg_to_rad :: proc(d: f32) -> f32 {
	return d * 0.017453292
}

// Projects a world position onto the top-down view: world X stays screen X,
// world Z becomes screen Y. World Y (height) is dropped entirely -- this is
// the one thing the 2D version can't represent that the 3D version could.
// Maps with real verticality (stacked floors, ramps) will draw everything
// at those different heights on top of each other with no depth cue.
world_to_2d :: proc(pos: rl.Vector3) -> rl.Vector2 {
	return rl.Vector2{pos.x, pos.z}
}

// Rotated top-down rectangle, filled + optional outline. `rot_y` is the only
// rotation axis that means anything from directly above, so tilt/roll (the
// object's rot.x/rot.z) are silently dropped, same as height.
draw_top_down_rect :: proc(center: rl.Vector2, width, depth, rot_y: f32, color: rl.Color, wire: bool) {
	rec := rl.Rectangle{center.x, center.y, width, depth}
	origin := rl.Vector2{width / 2, depth / 2}
	// Screen Y mirrors world Z, so flip rotation direction to keep "yaw"
	// meaning the same thing it does in the telemetry data.
	deg := -rot_y * rl.RAD2DEG
	rl.DrawRectanglePro(rec, origin, deg, color)
	if wire {
		draw_rect_outline_rotated(center, width, depth, deg, rl.Color{0, 0, 0, 90})
	}
}

// DrawRectangleLinesEx can't rotate, so for anything with a real rotation
// this rotates the 4 corners by hand and connects them with lines.
draw_rect_outline_rotated :: proc(center: rl.Vector2, width, depth, deg: f32, color: rl.Color) {
	rad := deg * rl.DEG2RAD
	hw, hd := width / 2, depth / 2
	local := [4]rl.Vector2{{-hw, -hd}, {hw, -hd}, {hw, hd}, {-hw, hd}}
	cos_r := math.cos(rad)
	sin_r := math.sin(rad)

	corners: [4]rl.Vector2
	for p, i in local {
		corners[i] = rl.Vector2{
			center.x + p.x * cos_r - p.y * sin_r,
			center.y + p.x * sin_r + p.y * cos_r,
		}
	}
	for i in 0 ..< 4 {
		rl.DrawLineV(corners[i], corners[(i + 1) % 4], color)
	}
}

// Prefab-type indices (KrunkNative's PrefabType enum) that are gameplay
// logic/markers in the real client -- zones, triggers, pickups, spawn/camera
// markers, VFX emitters -- not physical geometry a player would ever see as
// a shape. Mapmakers often additionally (or instead) mark these with "v":1
// (see MapObject.hidden), but plenty rely on the type alone being invisible
// in the stock client, so we skip both. Tune this against the in-game
// minimap: press P over a stray box to read its real `i` value.
LOGICAL_PREFAB_TYPES := map[int]bool{
	5  = true, // spawn point (we draw real spawn markers from `spawns` instead)
	6  = true, // camera position
	10 = true, // score zone
	12 = true, // death zone
	13 = true, // particles
	14 = true, // objective
	23 = true, // flag
	24 = true, // gate
	25 = true, // check point
	26 = true, // weapon pickup
	27 = true, // teleporter
	29 = true, // trigger
	31 = true, // deposit box
	32 = true, // light cone
	33 = true, // spectate cam
	35 = true, // placeholder
	39 = true, // sound emitter
	40 = true, // event
	41 = true, // terminal
	42 = true, // premium zone
	43 = true, // verified zone
	44 = true, // custom asset
	45 = true, // bomb site
	46 = true, // boost pad
	47 = true, // team zone
	52 = true, // showcase
	53 = true, // point light
	55 = true, // bot
	57 = true, // rune
}

should_draw_object :: proc(o: MapObject) -> bool {
	if o.hidden do return false
	if LOGICAL_PREFAB_TYPES[o.prop_i] do return false
	return true
}

// Draws every block/object flat, from directly above. No distance culling:
// even ~1360 objects + 300 blocks as simple 2D rects is cheap -- unlike the
// 3D version, which had to cull real meshes to hold a frame rate.
draw_map :: proc(m: ^GameMap) {
	block_color := rl.Color{130, 120, 110, 255}
	for b in m.blocks {
		draw_top_down_rect(world_to_2d(b.pos), b.size.x, b.size.z, 0, block_color, true)
	}

	for o in m.objects {
		if !should_draw_object(o) do continue

		// No prop meshes in the 2D version -- barrels/crates/etc just draw
		// as their real map color, same as any other object. See
		// debug_pick below if you want to identify a prop's `i` value.
		col := object_color(m, o.color_i)
		draw_top_down_rect(world_to_2d(o.pos), o.scale.x, o.scale.z, o.rot.y, col, true)
	}

	for s in m.spawns {
		col := TEAM_COLORS[s.team % len(TEAM_COLORS)]
		center := world_to_2d(s.pos)
		rl.DrawCircleV(center, 3, col)
		// Facing tick, same idea as the 3D version's spawn markers.
		dir := rl.Vector2{math.sin(s.rot_y), math.cos(s.rot_y)}
		tip := rl.Vector2{center.x + dir.x * 6, center.y + dir.y * 6}
		rl.DrawLineV(center, tip, col)
	}
}

// Player bodies + facing indicators. Called inside BeginMode2D, so these
// scale/pan with the camera like any other world geometry.
draw_players :: proc(w: ^World) {
	for sid, _ in w.players {
		p := &w.players[sid]
		if !p.has_render || p.is_spectator {
			continue
		}

		center := world_to_2d(p.render_pos)
		body_color := rl.Color{80, 200, 255, 255}
		if p.health <= 0 {
			body_color = rl.Color{90, 90, 90, 160}
		}

		yaw_rad := deg_to_rad(p.render_yaw)
		draw_top_down_rect(center, PLAYER_WIDTH, PLAYER_DEPTH, yaw_rad, body_color, true)

		nose := rl.Vector2{center.x + math.sin(yaw_rad) * 6, center.y + math.cos(yaw_rad) * 6}
		rl.DrawLineV(center, nose, rl.RED)
	}
}

// Name tags, drawn *outside* BeginMode2D (see main.odin) so text stays a
// constant screen size regardless of zoom -- the 2D equivalent of the 3D
// version's manual GetWorldToScreen conversion for the same reason.
draw_player_labels :: proc(w: ^World) {
	for sid, _ in w.players {
		p := &w.players[sid]
		if !p.has_render || p.is_spectator {
			continue
		}
		screen := rl.GetWorldToScreen2D(world_to_2d(p.render_pos), current_camera)
		label := fmt.ctprintf("%s (%d)", p.name, p.health)
		rl.DrawText(label, i32(screen.x) - 40, i32(screen.y) - 22, 16, rl.WHITE)
	}
}

draw_tracers :: proc(w: ^World) {
	now := w.playback_t
	for tr in w.tracers {
		age := now - f64(tr.spawn_t)
		if age < 0 || age > TRACER_LIFETIME_MS {
			continue
		}
		alpha := u8(255.0 * (1.0 - age / TRACER_LIFETIME_MS))
		rl.DrawLineV(world_to_2d(tr.start), world_to_2d(tr.end), rl.Color{255, 230, 120, alpha})
	}
}

draw_hud :: proc(w: ^World, camera: rl.Camera2D) {
	sw := rl.GetScreenWidth()
	sh := rl.GetScreenHeight()

	// Bottom timeline bar.
	bar_x, bar_y := i32(20), sh - 50
	bar_w := sw - 40
	bar_h := i32(14)
	rl.DrawRectangle(bar_x, bar_y, bar_w, bar_h, rl.Color{40, 40, 40, 220})

	progress: f32 = 0
	if w.replay.duration > 0 {
		progress = f32(w.playback_t / f64(w.replay.duration))
	}
	rl.DrawRectangle(bar_x, bar_y, i32(f32(bar_w) * progress), bar_h, rl.Color{80, 200, 255, 230})
	rl.DrawRectangleLines(bar_x, bar_y, bar_w, bar_h, rl.WHITE)

	state := "PAUSED"
	if w.playing {
		state = "PLAYING"
	}
	info := fmt.ctprintf(
		"%s  |  t = %.1fs / %.1fs  |  speed = %.2fx  |  players = %d  |  zoom = %.2fx",
		state,
		w.playback_t / 1000.0,
		f64(w.replay.duration) / 1000.0,
		w.speed,
		len(w.players),
		camera.zoom,
	)
	rl.DrawText(info, bar_x, bar_y - 22, 18, rl.WHITE)

	help: cstring = "SPACE play/pause  LEFT/RIGHT seek 2s  UP/DOWN speed  WASD/right-drag pan  wheel zoom  P inspect nearest object  F11 fullscreen"
	rl.DrawText(help, bar_x, sh - 22, 14, rl.Color{200, 200, 200, 255})

	draw_position_hud(camera)
	draw_overview(w, camera)
}

// Top-left readout of where the 2D camera is looking and how zoomed in it is.
draw_position_hud :: proc(camera: rl.Camera2D) {
	pos_text := fmt.ctprintf(
		"viewing: (%.0f, %.0f)   zoom: %.2fx",
		camera.target.x, camera.target.y, camera.zoom,
	)
	rl.DrawText(pos_text, 20, 20, 18, rl.WHITE)
}

OVERVIEW_SIZE   :: 220
OVERVIEW_MARGIN :: 20

world_to_overview :: proc(m: ^GameMap, origin_x, origin_y: i32, wx, wz: f32) -> (i32, i32) {
	width := m.bounds_max.x - m.bounds_min.x
	depth := m.bounds_max.z - m.bounds_min.z
	if width <= 0 do width = 1
	if depth <= 0 do depth = 1
	fx := (wx - m.bounds_min.x) / width
	fz := (wz - m.bounds_min.z) / depth
	return origin_x + i32(fx * OVERVIEW_SIZE), origin_y + i32(fz * OVERVIEW_SIZE)
}

// Whole-map overview with spawn points and a rectangle showing what part of
// the map the main view currently covers. The 3D version's minimap existed
// to answer "where am I"; here the main view *is* the map, so this instead
// answers "how much of the map am I currently zoomed into".
draw_overview :: proc(w: ^World, camera: rl.Camera2D) {
	m := &w.game_map
	sw := rl.GetScreenWidth()
	sh := rl.GetScreenHeight()
	x0 := sw - OVERVIEW_SIZE - OVERVIEW_MARGIN
	y0 := i32(OVERVIEW_MARGIN)

	rl.DrawRectangle(x0, y0, OVERVIEW_SIZE, OVERVIEW_SIZE, rl.Color{20, 20, 25, 210})
	rl.DrawRectangleLines(x0, y0, OVERVIEW_SIZE, OVERVIEW_SIZE, rl.WHITE)

	for s in m.spawns {
		sx, sy := world_to_overview(m, x0, y0, s.pos.x, s.pos.z)
		rl.DrawCircle(sx, sy, 3, TEAM_COLORS[s.team % len(TEAM_COLORS)])
	}

	top_left := rl.GetScreenToWorld2D(rl.Vector2{0, 0}, camera)
	bot_right := rl.GetScreenToWorld2D(rl.Vector2{f32(sw), f32(sh)}, camera)

	vx0, vy0 := world_to_overview(m, x0, y0, top_left.x, top_left.y)
	vx1, vy1 := world_to_overview(m, x0, y0, bot_right.x, bot_right.y)
	rl.DrawRectangleLines(vx0, vy0, vx1 - vx0, vy1 - vy0, rl.YELLOW)

	label: cstring = "map"
	rl.DrawText(label, x0 + 4, y0 - 20, 14, rl.Color{200, 200, 200, 255})
}

// Handles clicks on the timeline bar; returns true if a seek happened.
handle_timeline_click :: proc(w: ^World) -> bool {
	if !rl.IsMouseButtonPressed(.LEFT) {
		return false
	}
	sh := rl.GetScreenHeight()
	sw := rl.GetScreenWidth()
	bar_x, bar_y := i32(20), sh - 50
	bar_w := sw - 40
	bar_h := i32(14)

	mp := rl.GetMousePosition()
	if mp.x < f32(bar_x) || mp.x > f32(bar_x + bar_w) || mp.y < f32(bar_y) || mp.y > f32(bar_y + bar_h) {
		return false
	}
	frac := (mp.x - f32(bar_x)) / f32(bar_w)
	seek_to(w, f64(frac) * f64(w.replay.duration))
	return true
}

// Debug tool for figuring out the map's real "i" prop IDs (or just
// inspecting any object): finds whichever object is closest to the mouse
// cursor in world space, within a reasonable radius, and prints its raw
// fields to the console.
debug_pick :: proc(m: ^GameMap, camera: rl.Camera2D) {
	mouse_world := rl.GetScreenToWorld2D(rl.GetMousePosition(), camera)

	best_dist := f32(40) // world units; ignore anything not roughly under the cursor
	best_idx := -1

	for o, idx in m.objects {
		dx := o.pos.x - mouse_world.x
		dz := o.pos.z - mouse_world.y
		dist := math.sqrt(dx * dx + dz * dz)
		if dist < best_dist {
			best_dist = dist
			best_idx = idx
		}
	}

	if best_idx == -1 {
		fmt.println("debug_pick: nothing near the cursor within range")
		return
	}

	o := m.objects[best_idx]
	fmt.printf(
		"debug_pick: object[%d]  pos=(%.1f, %.1f, %.1f)  t=%d  ci=%d  i=%d  v(hidden)=%v  drawn=%v  dist=%.1f\n",
		best_idx, o.pos.x, o.pos.y, o.pos.z, o.obj_type, o.color_i, o.prop_i, o.hidden, should_draw_object(o), best_dist,
	)
}
