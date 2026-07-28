package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

deg_to_rad :: proc(d: f32) -> f32 {
	return d * 0.017453292
}

TEAM_COLORS := [3]rl.Color{rl.SKYBLUE, rl.ORANGE, rl.LIME}

dist_sq_xz :: proc(a, b: rl.Vector3) -> f32 {
	dx := a.x - b.x
	dz := a.z - b.z
	return dx * dx + dz * dz
}

// Draws a box centered at `pos`, rotated by euler `rot` (radians, XYZ order)
// using raylib's immediate-mode matrix stack, since DrawCube itself has no
// rotation parameter.
draw_rotated_box :: proc(pos: rl.Vector3, size: rl.Vector3, rot: rl.Vector3, color: rl.Color, wire: bool) {
	rlgl.PushMatrix()
	rlgl.Translatef(pos.x, pos.y, pos.z)
	rlgl.Rotatef(rot.z * rl.RAD2DEG, 0, 0, 1)
	rlgl.Rotatef(rot.y * rl.RAD2DEG, 0, 1, 0)
	rlgl.Rotatef(rot.x * rl.RAD2DEG, 1, 0, 0)
	rl.DrawCube(rl.Vector3{0, 0, 0}, size.x, size.y, size.z, color)
	if wire {
		rl.DrawCubeWires(rl.Vector3{0, 0, 0}, size.x, size.y, size.z, rl.Color{0, 0, 0, 90})
	}
	rlgl.PopMatrix()
}

// Draws the map, culling anything farther than `render_distance` (XZ plane
// distance -- height differences shouldn't hide/show geometry) from
// `camera_pos`. This is the fix for "too many objects": with ~1360 objects
// and 300 terrain blocks, drawing everything regardless of distance both
// tanks performance and makes the view unreadable.
draw_map :: proc(m: ^GameMap, camera_pos: rl.Vector3, render_distance: f32, prop_models: ^PropModels) {
	max_d_sq := render_distance * render_distance

	block_color := rl.Color{130, 120, 110, 255}
	for b in m.blocks {
		if dist_sq_xz(b.pos, camera_pos) > max_d_sq do continue
		rl.DrawCube(b.pos, b.size.x, b.size.y, b.size.z, block_color)
		rl.DrawCubeWires(b.pos, b.size.x, b.size.y, b.size.z, rl.Color{0, 0, 0, 60})
	}

	for o in m.objects {
		if dist_sq_xz(o.pos, camera_pos) > max_d_sq do continue

		// A real imported prop mesh (barrel/crate) takes priority over the
		// generic colored-box fallback when we have one loaded. Krunker
		// scales these by a fixed per-prefab constant (crate=6.0,
		// barrel=4.0), not the object's "s" field -- overridden per
		// instance only if the map sets "ms" (model_size). Position is the
		// mesh's *base*, not its center, so we shift it up by the mesh's
		// own bounding-box offset (computed once at load time).
		if o.prop_i >= 0 {
			if asset, has_model := prop_models[o.prop_i]; has_model {
				s := asset.scale
				if o.model_size > 0 do s = o.model_size

				// NOTE: matrix multiplication order for raylib's row-vector
				// convention -- if props render rotated/offset incorrectly,
				// this is the first thing to flip (try MatrixMultiply args
				// reversed, or swap which transform the scale factor lands on).
				base_lift := rl.MatrixTranslate(0, asset.base_offset_y * s, 0)
				rot := rl.MatrixRotateXYZ(o.rot)
				scale_m := rl.MatrixScale(s, s, s)
				asset.model.transform = rl.MatrixMultiply(rl.MatrixMultiply(scale_m, rot), base_lift)

				rl.DrawModel(asset.model, o.pos, 1.0, rl.WHITE)
				continue
			}
		}

		col := object_color(m, o.color_i)
		draw_rotated_box(o.pos, o.scale, o.rot, col, true)
	}

	for s in m.spawns {
		col := TEAM_COLORS[s.team % len(TEAM_COLORS)]
		rl.DrawCylinder(s.pos, 3, 3, 0.2, 12, col)
	}
}

draw_players :: proc(w: ^World) {
	for sid, _ in w.players {
		p := &w.players[sid]
		if !p.has_render || p.is_spectator {
			continue
		}

		// Render offset per spec 1: packet Y is feet level, box origin is center.
		center := rl.Vector3{p.render_pos.x, p.render_pos.y + PLAYER_HEIGHT / 2, p.render_pos.z}

		body_color := rl.Color{80, 200, 255, 255}
		if p.health <= 0 {
			body_color = rl.Color{90, 90, 90, 160}
		}

		draw_rotated_box(center, rl.Vector3{PLAYER_WIDTH, PLAYER_HEIGHT, PLAYER_DEPTH}, rl.Vector3{0, deg_to_rad(p.render_yaw), 0}, body_color, true)

		// Facing indicator: small nose poking out in view direction.
		yaw_rad := deg_to_rad(p.render_yaw)
		nose := rl.Vector3{center.x + math.sin(yaw_rad) * 3, center.y, center.z + math.cos(yaw_rad) * 3}
		rl.DrawLine3D(center, nose, rl.RED)

		label := fmt.ctprintf("%s (%d)", p.name, p.health)
		screen := rl.GetWorldToScreen(rl.Vector3{center.x, center.y + PLAYER_HEIGHT / 2 + 2, center.z}, current_camera)
		rl.DrawText(label, i32(screen.x) - 40, i32(screen.y), 16, rl.WHITE)
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
		rl.DrawLine3D(tr.start, tr.end, rl.Color{255, 230, 120, alpha})
	}
}

draw_hud :: proc(w: ^World, camera: rl.Camera3D) {
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
		"%s  |  t = %.1fs / %.1fs  |  speed = %.2fx  |  players = %d  |  render dist = %.0f ([ / ] to adjust)",
		state,
		w.playback_t / 1000.0,
		f64(w.replay.duration) / 1000.0,
		w.speed,
		len(w.players),
		w.render_distance,
	)
	rl.DrawText(info, bar_x, bar_y - 22, 18, rl.WHITE)

	help: cstring = "SPACE play/pause  LEFT/RIGHT seek 2s  UP/DOWN speed  [ ] render distance  P inspect nearest prop  TAB release mouse  F11 fullscreen  WASD+Mouse fly"
	rl.DrawText(help, bar_x, sh - 22, 14, rl.Color{200, 200, 200, 255})

	draw_position_hud(camera)
	draw_minimap(w, camera)
}

// Top-left readout of where the camera actually is in world space -- the
// spec's world origin (0,0,0) is fixed and never re-centered, so these
// numbers line up directly with map/spawn coordinates.
draw_position_hud :: proc(camera: rl.Camera3D) {
	pos_text := fmt.ctprintf(
		"pos: (%.0f, %.0f, %.0f)   dist to origin: %.0f",
		camera.position.x, camera.position.y, camera.position.z,
		math.sqrt(camera.position.x * camera.position.x + camera.position.z * camera.position.z),
	)
	rl.DrawText(pos_text, 20, 20, 18, rl.WHITE)
}

MINIMAP_SIZE   :: 220
MINIMAP_MARGIN :: 20

world_to_minimap :: proc(m: ^GameMap, origin_x, origin_y: i32, wx, wz: f32) -> (i32, i32) {
	width := m.bounds_max.x - m.bounds_min.x
	depth := m.bounds_max.z - m.bounds_min.z
	if width <= 0 do width = 1
	if depth <= 0 do depth = 1
	fx := (wx - m.bounds_min.x) / width
	fz := (wz - m.bounds_min.z) / depth
	return origin_x + i32(fx * MINIMAP_SIZE), origin_y + i32(fz * MINIMAP_SIZE)
}

// Top-down overview: map bounds, spawn points (colored by team), and the
// camera's position + facing -- the fix for "no idea where I am".
draw_minimap :: proc(w: ^World, camera: rl.Camera3D) {
	m := &w.game_map
	sw := rl.GetScreenWidth()
	x0 := sw - MINIMAP_SIZE - MINIMAP_MARGIN
	y0 := i32(MINIMAP_MARGIN)

	rl.DrawRectangle(x0, y0, MINIMAP_SIZE, MINIMAP_SIZE, rl.Color{20, 20, 25, 210})
	rl.DrawRectangleLines(x0, y0, MINIMAP_SIZE, MINIMAP_SIZE, rl.WHITE)

	for s in m.spawns {
		sx, sy := world_to_minimap(m, x0, y0, s.pos.x, s.pos.z)
		rl.DrawCircle(sx, sy, 3, TEAM_COLORS[s.team % len(TEAM_COLORS)])
	}

	cx, cy := world_to_minimap(m, x0, y0, camera.position.x, camera.position.z)

	fwd_x := camera.target.x - camera.position.x
	fwd_z := camera.target.z - camera.position.z
	flen := math.sqrt(fwd_x * fwd_x + fwd_z * fwd_z)
	if flen > 0.001 {
		fwd_x /= flen
		fwd_z /= flen
		rl.DrawLine(cx, cy, cx + i32(fwd_x * 14), cy + i32(fwd_z * 14), rl.YELLOW)
	}
	rl.DrawCircle(cx, cy, 4, rl.RED)

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

// Debug tool for figuring out the map's real "i" prop IDs: finds whichever
// object/block projects closest to the center of the screen (i.e. roughly
// what you're looking at) within a reasonable radius, and prints its raw
// fields to the console. Use this to confirm or correct the barrel/crate
// guess in models.odin -- look at a prop, press P, compare what prints to
// what you see.
debug_pick :: proc(m: ^GameMap, camera: rl.Camera3D, prop_models: ^PropModels) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	center := rl.Vector2{sw / 2, sh / 2}

	best_px_dist := f32(80) // ignore anything not roughly under the crosshair
	best_idx := -1
	best_world_dist := max(f32)

	for o, idx in m.objects {
		dx := o.pos.x - camera.position.x
		dy := o.pos.y - camera.position.y
		dz := o.pos.z - camera.position.z
		world_dist := math.sqrt(dx * dx + dy * dy + dz * dz)
		if world_dist > 400 do continue

		screen := rl.GetWorldToScreen(o.pos, camera)
		px_dist := math.sqrt((screen.x - center.x) * (screen.x - center.x) + (screen.y - center.y) * (screen.y - center.y))
		if px_dist < best_px_dist || (px_dist < best_px_dist + 5 && world_dist < best_world_dist) {
			best_px_dist = px_dist
			best_world_dist = world_dist
			best_idx = idx
		}
	}

	if best_idx == -1 {
		fmt.println("debug_pick: nothing under the crosshair within range")
		return
	}

	o := m.objects[best_idx]
	fmt.printf(
		"debug_pick: object[%d]  pos=(%.1f, %.1f, %.1f)  t=%d  ci=%d  i=%d  world_dist=%.1f\n",
		best_idx, o.pos.x, o.pos.y, o.pos.z, o.obj_type, o.color_i, o.prop_i, best_world_dist,
	)
	if o.prop_i >= 0 {
		if _, has := prop_models[o.prop_i]; has {
			fmt.println("  -> currently rendered with a real model loaded from the Krunker asset tree")
		} else {
			fmt.println("  -> no model mapped for this i value yet, rendered as a colored box")
		}
	}
}
