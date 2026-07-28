package main

// Map loading, per SYSTEM CONTEXT & SPECIFICATION section 2, extended with
// two things the spec didn't cover but real exports (data/sandstorm_v3.json)
// actually carry:
//
//   - a `colors` palette (hex strings) that objects reference by index (`ci`)
//   - an `i` field on some objects, which is a *prop category* index (custom
//     imported meshes like barrels/crates/powercells), not a scale/size value
//
// World coordinate system: Three.js / OpenGL style, right-handed, Y-up.
// This matches raylib's default coordinate convention, so positions are
// used verbatim -- no axis remapping, and (0,0,0) is never re-centered.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// `objects` entries (props / complex shapes). Position is a *center* pivot.
// Scale defaults to (10,10,10) and rotation to (0,0,0) when omitted, since
// real map exports frequently leave both out.
MapObject :: struct {
	pos:      rl.Vector3, // center
	scale:    rl.Vector3, // width, height, depth (only meaningful for the box fallback)
	rot:      rl.Vector3, // euler radians, XYZ order
	obj_type: int,        // the spec's "t" field
	color_i:  int,        // index into GameMap.colors ("ci"), -1 if absent
	prop_i:   int,        // imported-model category ("i"), -1 if absent -- see models.odin
	model_size: f32,      // per-instance model scale override ("ms"), -1 if absent
}

// One stride of the flat `xyz` terrain array: also a *center* pivot box.
XYZBlock :: struct {
	pos:  rl.Vector3,
	size: rl.Vector3,
}

// `spawns` entries. Position marks *floor level*, not center -- unlike
// objects/xyz -- per spec section 2C.
Spawn :: struct {
	pos:   rl.Vector3,
	rot_y: f32,
	team:  int,
	mode:  int,
}

GameMap :: struct {
	name:    string,
	objects: [dynamic]MapObject,
	blocks:  [dynamic]XYZBlock,
	spawns:  [dynamic]Spawn,
	colors:  [dynamic]rl.Color,

	// World-space bounding box, computed from every block/object/spawn we
	// loaded. Used for the minimap and for sane default culling distances.
	bounds_min: rl.Vector3,
	bounds_max: rl.Vector3,
}

// Parses a "#RRGGBB" (or "#RGB") string into an opaque raylib Color.
// Falls back to a neutral gray on anything malformed.
hex_to_color :: proc(hex: string) -> rl.Color {
	h := strings.trim_prefix(hex, "#")
	fallback := rl.Color{140, 140, 140, 255}

	parse_channel :: proc(s: string) -> (u8, bool) {
		v, ok := strconv.parse_int(s, 16)
		if !ok do return 0, false
		return u8(v), true
	}

	switch len(h) {
	case 6:
		r, ok1 := parse_channel(h[0:2])
		g, ok2 := parse_channel(h[2:4])
		b, ok3 := parse_channel(h[4:6])
		if ok1 && ok2 && ok3 {
			return rl.Color{r, g, b, 255}
		}
	case 3:
		r, ok1 := parse_channel(strings.repeat(h[0:1], 2))
		g, ok2 := parse_channel(strings.repeat(h[1:2], 2))
		b, ok3 := parse_channel(strings.repeat(h[2:3], 2))
		if ok1 && ok2 && ok3 {
			return rl.Color{r, g, b, 255}
		}
	}
	return fallback
}

expand_bounds :: proc(m: ^GameMap, p: rl.Vector3) {
	m.bounds_min.x = min(m.bounds_min.x, p.x)
	m.bounds_min.y = min(m.bounds_min.y, p.y)
	m.bounds_min.z = min(m.bounds_min.z, p.z)
	m.bounds_max.x = max(m.bounds_max.x, p.x)
	m.bounds_max.y = max(m.bounds_max.y, p.y)
	m.bounds_max.z = max(m.bounds_max.z, p.z)
}

load_map :: proc(path: string) -> (GameMap, bool) {
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if data == nil {
		fmt.eprintln("map: failed to read", path, read_err)
		return GameMap{}, false
	}
	defer delete(data)

	value, err := json.parse(data)
	if err != .None {
		fmt.eprintln("map: failed to parse JSON:", err)
		return GameMap{}, false
	}
	defer json.destroy_value(value)

	root := get_object(value)
	m: GameMap
	m.name = get_string(root["name"])
	m.bounds_min = rl.Vector3{max(f32), max(f32), max(f32)}
	m.bounds_max = rl.Vector3{min(f32), min(f32), min(f32)}

	// --- palette: `colors` is a flat array of "#RRGGBB" strings ---
	if cv, has := root["colors"]; has {
		for c in get_array(cv) {
			append(&m.colors, hex_to_color(get_string(c)))
		}
	}

	// --- B. `xyz` flat array: stride of 6 -> [X,Y,Z,SizeX,SizeY,SizeZ] ---
	if xyz_v, has := root["xyz"]; has {
		xyz := get_array(xyz_v)
		i := 0
		for i + 5 < len(xyz) {
			block: XYZBlock
			block.pos = rl.Vector3{get_f32(xyz[i + 0]), get_f32(xyz[i + 1]), get_f32(xyz[i + 2])}
			block.size = rl.Vector3{get_f32(xyz[i + 3]), get_f32(xyz[i + 4]), get_f32(xyz[i + 5])}
			append(&m.blocks, block)
			expand_bounds(&m, block.pos)
			i += 6
		}
	}

	// --- A. `objects` array: explicit p / s / r / t, plus real-world ci / i ---
	if objs_v, has := root["objects"]; has {
		objs := get_array(objs_v)
		for ov in objs {
			oo := get_object(ov)
			obj: MapObject
			obj.scale = rl.Vector3{10, 10, 10} // spec default
			obj.rot = rl.Vector3{0, 0, 0}      // spec default
			obj.color_i = -1
			obj.prop_i = -1
			obj.model_size = -1

			if pv, has_p := oo["p"]; has_p {
				pa := get_array(pv)
				obj.pos = rl.Vector3{get_f32(arr_at(pa, 0)), get_f32(arr_at(pa, 1)), get_f32(arr_at(pa, 2))}
			}
			if sv, has_s := oo["s"]; has_s {
				sa := get_array(sv)
				obj.scale = rl.Vector3{get_f32(arr_at(sa, 0)), get_f32(arr_at(sa, 1)), get_f32(arr_at(sa, 2))}
			}
			if rv, has_r := oo["r"]; has_r {
				ra := get_array(rv)
				obj.rot = rl.Vector3{get_f32(arr_at(ra, 0)), get_f32(arr_at(ra, 1)), get_f32(arr_at(ra, 2))}
			}
			if tv, has_t := oo["t"]; has_t {
				obj.obj_type = int(get_i64(tv))
			}
			if civ, has_ci := oo["ci"]; has_ci {
				obj.color_i = int(get_i64(civ))
			}
			if iv, has_i := oo["i"]; has_i {
				obj.prop_i = int(get_i64(iv))
			}
			if msv, has_ms := oo["ms"]; has_ms {
				obj.model_size = get_f32(msv)
			}
			append(&m.objects, obj)
			expand_bounds(&m, obj.pos)
		}
	}

	// --- C. `spawns` array ---
	if sv, has := root["spawns"]; has {
		spawns := get_array(sv)
		for spv in spawns {
			sa := get_array(spv)
			sp: Spawn
			sp.pos = rl.Vector3{get_f32(arr_at(sa, 0)), get_f32(arr_at(sa, 1)), get_f32(arr_at(sa, 2))}
			sp.rot_y = get_f32(arr_at(sa, 3))
			sp.team = int(get_i64(arr_at(sa, 4)))
			sp.mode = int(get_i64(arr_at(sa, 5)))
			append(&m.spawns, sp)
			expand_bounds(&m, sp.pos)
		}
	}

	fmt.println("map:", m.name, "-", len(m.blocks), "xyz blocks,", len(m.objects), "objects,", len(m.spawns), "spawns,", len(m.colors), "colors")
	fmt.println("map bounds: x[", m.bounds_min.x, ",", m.bounds_max.x, "] z[", m.bounds_min.z, ",", m.bounds_max.z, "]")
	return m, true
}

// Looks up an object's real map color, falling back to a neutral gray if it
// has no `ci` or the index is out of range for the palette.
object_color :: proc(m: ^GameMap, ci: int) -> rl.Color {
	if ci >= 0 && ci < len(m.colors) {
		return m.colors[ci]
	}
	return rl.Color{140, 140, 140, 255}
}

destroy_map :: proc(m: ^GameMap) {
	delete(m.objects)
	delete(m.blocks)
	delete(m.spawns)
	delete(m.colors)
}
