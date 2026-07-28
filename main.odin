package main

// Standalone 3D replay engine: loads a map file (spec section 2) and plays
// back a WebSocket telemetry log (spec section 3) with jitter-buffered
// snapshot interpolation (spec section 4).
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

// raylib's built-in FREE camera has no movement-speed parameter. Updating it
// three times per frame gives the replay camera roughly 3x its normal WASD
// and mouse-look speed while preserving raylib's camera behavior.
CAMERA_SPEED_MULTIPLIER :: 10

// Referenced by render.odin (draw_players) to project world -> screen space
// for name tags. Kept as a package-level global since raylib's own camera
// is likewise a single active camera per frame.
current_camera: rl.Camera3D

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
	rl.InitWindow(1280, 800, "3D Replay Engine")
	rl.SetTargetFPS(144)
	defer rl.CloseWindow()

	// Model/texture loading must happen after InitWindow.  make_world loads
	// the prop assets, and raylib needs the OpenGL context created above for
	// those GPU resources.  Loading it earlier produces "GPU is not ready"
	// warnings and can segfault in the platform GL driver.
	world := make_world(game_map, replay)
	seek_to(&world, 0)
	world.playing = true

	// Start maximized to the current monitor's resolution (e.g. a 2K/4K
	// display) instead of the small fixed 1280x800 default. F11 toggles
	// true fullscreen at any point (see the main loop below).
	monitor := rl.GetCurrentMonitor()
	rl.SetWindowSize(rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor))
	rl.SetWindowPosition(0, 0)

	// Start the free-fly camera above the first spawn, looking at the map center.
	start_pos := rl.Vector3{0, 60, 60}
	if len(game_map.spawns) > 0 {
		s := game_map.spawns[0]
		start_pos = rl.Vector3{s.pos.x, s.pos.y + 40, s.pos.z + 40}
	}
	camera := rl.Camera3D{
		position   = start_pos,
		target     = rl.Vector3{0, 0, 0},
		up         = rl.Vector3{0, 1, 0},
		fovy       = 70,
		projection = .PERSPECTIVE,
	}
	cursor_locked := true
	rl.DisableCursor()

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()

		if rl.IsKeyPressed(.F11) {
			rl.ToggleFullscreen()
		}

		if rl.IsKeyPressed(.TAB) {
			cursor_locked = !cursor_locked
			if cursor_locked {
				rl.DisableCursor()
			} else {
				rl.EnableCursor()
			}
		}

		handle_input(&world, &camera)

		current_camera = camera
		if cursor_locked {
			for _ in 0..<CAMERA_SPEED_MULTIPLIER {
				rl.UpdateCamera(&camera, .FREE)
			}
		}

		update_playback(&world, dt)

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{18, 20, 26, 255})

		rl.BeginMode3D(camera)
		rl.DrawGrid(200, 10)
		draw_map(&game_map, camera.position, world.render_distance, &world.prop_models)
		draw_players(&world)
		draw_tracers(&world)
		rl.EndMode3D()

		draw_hud(&world, camera)

		rl.EndDrawing()
	}

	destroy_map(&game_map)
	destroy_replay(&replay)
	destroy_prop_models(&world.prop_models)
}

handle_input :: proc(w: ^World, camera: ^rl.Camera3D) {
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
	if rl.IsKeyDown(.LEFT_BRACKET) {
		w.render_distance = clamp_f32(w.render_distance - 200 * rl.GetFrameTime(), 30, 2000)
	}
	if rl.IsKeyDown(.RIGHT_BRACKET) {
		w.render_distance = clamp_f32(w.render_distance + 200 * rl.GetFrameTime(), 30, 2000)
	}
	if rl.IsKeyPressed(.P) {
		debug_pick(&w.game_map, camera^, &w.prop_models)
	}
	handle_timeline_click(w)
}

clamp_f32 :: proc(v, lo, hi: f32) -> f32 {
	if v < lo do return lo
	if v > hi do return hi
	return v
}
