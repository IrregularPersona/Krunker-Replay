package main

// Standalone 2D top-down replay engine: loads a map file (spec section 2) and
// plays back a WebSocket telemetry log (spec section 3) with jitter-buffered
// snapshot interpolation (spec section 4).
//
// This is the 2D sibling of the 3D replay engine: instead of a free-fly 3D
// camera walking an extruded world, everything is projected straight down
// onto the XZ ground plane and viewed through a pannable/zoomable 2D camera.
// That sidesteps every "getting the 3D right" problem the 3D version had
// (prop mesh loading/asset paths, matrix rotation order, camera-in-geometry
// weirdness) at the cost of losing true verticality: overlapping floors at
// different world Y will draw on top of each other rather than being
// properly layered. See world_to_2d in render.odin.
//
// Usage:
//   odin run replay_engine -- data/sandstorm_v3.json data/replay_log.2026-07-26
//
// Defaults to the two files below if no arguments are given.

import "core:fmt"
import "core:os"
import rl "vendor:raylib"

DEFAULT_MAP_PATH    :: "data/sandstorm_v3.json"
DEFAULT_REPLAY_PATH :: "data/replay_log.2026-07-26"

CAMERA_PAN_SPEED :: 400.0 // world units/sec at zoom = 1x, scaled by 1/zoom so WASD panning feels constant on screen
ZOOM_SPEED       :: 0.12  // fraction of current zoom applied per mouse-wheel notch
MIN_ZOOM         :: 0.02
MAX_ZOOM         :: 12.0

// Referenced by render.odin (draw_player_labels, draw_overview) to project
// world -> screen space for name tags and the viewport-overview box. Kept as
// a package-level global for the same reason the 3D version kept one:
// raylib only has a single active camera per frame anyway.
current_camera: rl.Camera2D

main :: proc() {
	map_path := DEFAULT_MAP_PATH
	replay_path := DEFAULT_REPLAY_PATH
	if len(os.args) >= 3 {
		map_path = os.args[1]
		replay_path = os.args[2]
	}

	game_map, map_ok := load_map(map_path)
	if !map_ok {
		fmt.eprintln("fatal: could not load map:", map_path)
		os.exit(1)
	}
	replay, replay_ok := load_replay(replay_path)
	if !replay_ok {
		fmt.eprintln("fatal: could not load replay:", replay_path)
		os.exit(1)
	}

	rl.SetConfigFlags({.MSAA_4X_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(1280, 800, "2D Replay Engine")
	rl.SetTargetFPS(144)
	defer rl.CloseWindow()

	world := make_world(game_map, replay)
	seek_to(&world, 0)
	world.playing = true

	// Start maximized to the current monitor's resolution (e.g. a 2K/4K
	// display) instead of the small fixed 1280x800 default. F11 toggles
	// true fullscreen at any point (see the main loop below).
	monitor := rl.GetCurrentMonitor()
	rl.SetWindowSize(rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor))
	rl.SetWindowPosition(0, 0)

	// Frame the whole map on startup rather than starting zoomed into an
	// arbitrary corner -- computed after the window resize above so it uses
	// the real screen size, not the 1280x800 default.
	camera := make_initial_camera(&game_map)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()

		if rl.IsKeyPressed(.F11) {
			rl.ToggleFullscreen()
		}

		handle_input(&world, &camera, dt)

		current_camera = camera
		update_playback(&world, dt)

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{18, 20, 26, 255})

		rl.BeginMode2D(camera)
		draw_map(&game_map)
		draw_players(&world)
		draw_tracers(&world)
		rl.EndMode2D()

		// Name tags are drawn after EndMode2D so text stays a constant
		// screen size regardless of zoom (see draw_player_labels).
		draw_player_labels(&world)
		draw_hud(&world, camera)

		rl.EndDrawing()
	}

	destroy_map(&game_map)
	destroy_replay(&replay)
}

// Centers the camera on the map's bounds and picks a zoom level that fits
// the whole map on screen, with a little padding.
make_initial_camera :: proc(m: ^GameMap) -> rl.Camera2D {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	if sw <= 0 do sw = 1280
	if sh <= 0 do sh = 800

	width := m.bounds_max.x - m.bounds_min.x
	depth := m.bounds_max.z - m.bounds_min.z
	if width <= 0 do width = 1
	if depth <= 0 do depth = 1

	zoom := min(sw / width, sh / depth) * 0.9
	zoom = clamp_f32(zoom, MIN_ZOOM, MAX_ZOOM)

	center_x := (m.bounds_min.x + m.bounds_max.x) / 2
	center_z := (m.bounds_min.z + m.bounds_max.z) / 2

	return rl.Camera2D{
		target   = rl.Vector2{center_x, center_z},
		offset   = rl.Vector2{sw / 2, sh / 2},
		rotation = 0,
		zoom     = zoom,
	}
}

handle_input :: proc(w: ^World, camera: ^rl.Camera2D, dt: f32) {
	if rl.IsKeyPressed(.SPACE) {
		w.playing = !w.playing
	}
	if rl.IsKeyPressed(.LEFT) {
		seek_to(w, w.playback_t - 2000)
	}
	if rl.IsKeyPressed(.RIGHT) {
		seek_to(w, w.playback_t + 2000)
	}
	if rl.IsKeyPressed(.HOME) {
		seek_to(w, 0)
	}
	if rl.IsKeyPressed(.UP) {
		w.speed = clamp_f32(w.speed + 0.25, 0.25, 4.0)
	}
	if rl.IsKeyPressed(.DOWN) {
		w.speed = clamp_f32(w.speed - 0.25, 0.25, 4.0)
	}
	if rl.IsKeyPressed(.P) {
		debug_pick(&w.game_map, camera^)
	}

	handle_camera_pan(camera, dt)
	handle_camera_zoom(camera)
	handle_timeline_click(w)
}

// WASD and right-mouse-drag both pan the camera. Pan speed (both the WASD
// constant-speed case and the mouse-drag case) is divided by zoom so a
// screen-space drag tracks the cursor 1:1 and WASD feels the same speed
// regardless of how zoomed in you are.
handle_camera_pan :: proc(camera: ^rl.Camera2D, dt: f32) {
	move := rl.Vector2{0, 0}
	if rl.IsKeyDown(.W) do move.y -= 1
	if rl.IsKeyDown(.S) do move.y += 1
	if rl.IsKeyDown(.A) do move.x -= 1
	if rl.IsKeyDown(.D) do move.x += 1
	if move.x != 0 || move.y != 0 {
		move = rl.Vector2Normalize(move)
		delta := rl.Vector2Scale(move, (CAMERA_PAN_SPEED / camera.zoom) * dt)
		camera.target = rl.Vector2Add(camera.target, delta)
	}

	if rl.IsMouseButtonDown(.RIGHT) {
		mouse_delta := rl.GetMouseDelta()
		camera.target.x -= mouse_delta.x / camera.zoom
		camera.target.y -= mouse_delta.y / camera.zoom
	}
}

// Mouse-wheel zoom, pinned to whatever world point is under the cursor
// (rather than always zooming toward screen center) so you don't drift
// away from what you're looking at while zooming in.
handle_camera_zoom :: proc(camera: ^rl.Camera2D) {
	wheel := rl.GetMouseWheelMove()
	if wheel == 0 do return

	mouse_world_before := rl.GetScreenToWorld2D(rl.GetMousePosition(), camera^)
	new_zoom := camera.zoom * (1.0 + wheel * ZOOM_SPEED)
	camera.zoom = clamp_f32(new_zoom, MIN_ZOOM, MAX_ZOOM)
	mouse_world_after := rl.GetScreenToWorld2D(rl.GetMousePosition(), camera^)

	camera.target.x += mouse_world_before.x - mouse_world_after.x
	camera.target.y += mouse_world_before.y - mouse_world_after.y
}

clamp_f32 :: proc(v, lo, hi: f32) -> f32 {
	if v < lo do return lo
	if v > hi do return hi
	return v
}
