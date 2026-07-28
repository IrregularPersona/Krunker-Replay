# 3D Replay Engine (Odin + raylib)

A standalone playback tool for a Krunker-style map file + WebSocket telemetry
log, implementing the coordinate system, map schema, and packet protocol.

## Layout

```
krunker-replay/
  main.odin      window/camera setup, input, main loop
  gamemap.odin   map_v3.json loader (objects / xyz / spawns)
  replay.odin    telemetry log parser (line-delimited [t, [op, ...]] JSON)
  entity.odin    player state, jitter-buffered LERP/angle interpolation, playback control
  render.odin    3D map/player/tracer drawing + HUD/timeline
  json_util.odin small helpers over core:encoding/json's tagged-union Value
  data/          the sample map + replay log
  mod/           extracted Krunker model/texture assets used by the map (from the old Krunker Modding Wiki. Extract yourself.)
```

## Build & run

Requires the [Odin compiler](https://odin-lang.org) (ships `vendor:raylib`
and `vendor:raylib/rlgl` with static raylib libs for Linux/macOS/Windows —
no separate raylib install needed on most, if not all setups as long as you can run Odin).

```bash
cd krunker-replay
odin run . -- data/sandstorm_v3.json data/replay_log.2026-07-26
```

With no arguments it defaults to those same two paths. Any other map/log
pair works the same way as long as it matches the schema in the spec.

## Controls

- `SPACE` — play/pause
- `LEFT` / `RIGHT` — seek ±2s
- `UP` / `DOWN` — playback speed (0.25x–4x)
- `HOME` — jump to start
- `[` / `]` — shrink/grow the render distance (see "Filtering objects" below)
- `P` — debug-inspect whatever prop is closest to the crosshair (prints its raw `t`/`ci`/`i` fields to the console)
- `TAB` — release the mouse cursor (needed to click the timeline bar; mouse
  look otherwise captures the cursor for WASD fly-cam navigation)
- `F11` — toggle fullscreen (window also starts sized to your current monitor)
- `WASD` + mouse — free camera, while cursor is captured

## Filtering objects outside the center / knowing where you are

Two features address this directly:

- **Distance culling.** `draw_map` only draws terrain blocks and objects
  within `World.render_distance` (XZ-plane distance) of the camera —
  default 300 units. Adjust live with `[`/`]`; the current value shows in
  the bottom HUD. With ~1360 objects and 300 terrain blocks in
  `sandstorm_v3.json`, this is what keeps the view from turning into an
  unreadable wall of boxes.
- **Position HUD + minimap.** Top-left shows your exact world coordinates
  and distance to the origin. Top-right shows a top-down minimap of the
  whole map's bounding box, with spawn points (colored by team) and your
  camera position + facing direction as a red dot with a yellow heading line.

## Real prop models and Krunker mod assets

The map's `objects` array carries an `i` field (a prop-category index) that
the original spec didn't document. `models.odin` follows KrunkNative's asset
layout and loads matching files from `./mod/models/` and `./mod/textures/`.
The JSON supplies the prefab index; the OBJ supplies geometry/UVs, and the PNG
is bound as the material texture at runtime. OBJ `.mtl` files are not needed.

The current `sandstorm_v3.json` needs these model/texture pairs:

```text
mod/models/crate_0.obj      mod/textures/crate_0.png
mod/models/barrel_0.obj     mod/textures/barrel_0.png
mod/models/tree_0_1.obj     mod/textures/tree_0_1.png
mod/models/grass_0.obj      mod/textures/grass_0.png
mod/models/window_0.obj     mod/textures/window_0.png
```

The `tree_0_1` variant is used because the original `tree_0.obj` contains
face lines that raylib's bundled TinyObj parser cannot handle. KrunkNative's
`fast_obj` loader is more permissive.

The relevant prefab mappings are:

| `i` value | Asset | Confidence |
|---|---|---|
| 1 | `crate_0.obj` | KrunkNative prefab table |
| 2 | `barrel_0.obj` | KrunkNative prefab table |
| 15 | `tree_0_1.obj` | Compatible variant of KrunkNative's `tree_0` |
| 18 | `grass_0.obj` | KrunkNative prefab table |
| 22 | `window_0.obj` | KrunkNative prefab table |

Only prefab IDs used by the loaded map are parsed. This avoids loading the
entire mod dump and avoids unrelated OBJ files that raylib cannot parse.
Anything with an unavailable or unsupported `i`, or no `i` at all, falls back
to a colored box using the map's `colors` palette via the object's `ci` index.

(Note: Implementation is not yet complete) - To inspect a prop, stand near it, look at it, and press `P`. The console prints its raw `i`/`ci`/`t` fields and whether a model was loaded for that ID.
To change mappings, edit `PREFAB_TABLE` in `models.odin`. - (Note: The mapping itself is not yet complete. Missing mappings for certain floors, and ramps are some of the most glaring ones. This is a long-term project, so expect bugs and issues.)

The full Krunker mod dump is not required. For this map, the `mod/` directory
can be reduced to the five OBJ/PNG pairs listed above; map colors and the
software-generated geometry do not require additional mod assets.

## How the spec maps to code

- **Coordinates (§1):** raylib is right-handed, Y-up by default, so no axis
  remapping is done anywhere — world positions from the JSON are used as-is,
  and `(0,0,0)` is never re-centered.
- **Player pivot (§1):** telemetry `Y` is feet-level; `draw_players` in
  `render.odin` adds `PLAYER_HEIGHT / 2` before drawing the bounding box,
  matching the render-offset formula in the spec.
- **Map schema (§2):** `gamemap.odin` parses `objects` (center pivot, with
  the spec's documented defaults of scale `(10,10,10)` and rotation `(0,0,0)`
  when a real object omits `s`/`r` — which the uploaded `sandstorm_v3.json`
  does for every single object), the flat `xyz` stride-6 array, and `spawns`.
- **Telemetry protocol (§3):** `replay.odin` parses every log line as
  `[t, [opcode, ...]]` and classifies the six opcodes the spec documents
  (`"0"`, `"chi"`, `"en"`, `"k"`, `"9"`, `"4"`); everything else (chat text,
  shop/session bootstrap packets, etc. — plenty of which show up in the
  `replay_log.2026-07-26`) is parsed once and simply ignored during
  playback. (Note: in the current implementation, most packets are ignored)
- **Interpolation (§4.3):** `entity.odin`'s `interpolate_players` holds a
  ~100ms jitter buffer (`DEFAULT_JITTER_MS`) and LERPs position / does
  shortest-path angle interpolation between the two 40Hz `"k"` snapshots
  bracketing the delayed render time.
- **Combat visualization (§4.4):** bullet tracers (`"9"`) are kept for
  `TRACER_LIFETIME_MS` and drawn as fading 3D line segments; `"4"` packets
  set a timestamp (`World.last_hit_t`) intended for a HUD hit-marker flash.

## Known assumptions / things to double check against your exact protocol build

The uploaded log is real, messy telemetry with a lot of vendor-specific
fields the spec doesn't fully pin down. A few judgment calls were made —
flagged in code comments at each spot:

1. **Yaw/Pitch units.** The spec calls these "scaled integer or degrees."
   Sample values (e.g. yaw ∈ roughly [-180, 180]) look degree-like, so
   `lerp_angle_deg` assumes degrees with wraparound at ±180. If your actual
   client uses a different scale (e.g. 0–255 byte-angles), rescale in
   `apply_event`'s `.Position` case before interpolation.
2. **`"en"` spawn manifest SID placement.** The spec's 34-item loadout array
   doesn't document exactly where `SID` lives (only that index 6 is the
   spectator flag). The uploaded replay log has zero `"en"` packets to check
   against, so `apply_event`'s `.SpawnManifest` case conservatively reads
   `loadout[0]` and no-ops if that isn't a real SID — entity creation in
   practice comes from `"0"`/`"k"` packets either way.
3. **`"4"` damage payload.** Not documented beyond "damage packets"; no
   sample exists in the uploaded log, so only the timestamp is recorded for
   now (`World.last_hit_t`) rather than parsing specific fields like damage
   amount or attacker/victim SIDs.

## A few notes

1. This is an unfinished project. The replay system itself still hasn't been fully implemented, and the map and replay log are just samples.

2. The provided sample log is purely just a user running around Sandstorm. No special mechanics or gameplay is demonstrated. Not even damage, kills, or deaths.

3. This project is NOT intended to be run as a game - it is intended to be used as a tool to study player movement and map design.

4. The project is checked with the local Odin toolchain using `odin check .`.
The remaining compiler output may include deprecation warnings from the
vendored raylib API, but those do not prevent the project from building.


## Credits

- [The KrunkNative project](https://github.com/rebel10n/KrunkNative) for providing the Protocol Spec, tools, and insight.
- [The Krunker Wiki](https://krunkerio.fandom.com/wiki) for the public modding asset files (maps, textures, models, etc.).