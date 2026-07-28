#+feature dynamic-literals
package main

// Loads Krunker's real prop meshes/textures and maps them to the map's `i`
// field, per the actual prefab table used by rebel10n/KrunkNative (a native
// C reimplementation of the Krunker client -- github.com/rebel10n/KrunkNative,
// see client/src/prefab.c + shared/include/shared.h's `PrefabType` enum).
// `object->prefab` there is read straight from the map's `i` field (`id` as
// fallback) in shared/src/map.c -- exactly what we call `prop_i` here.
//
// IMPORTANT: this now auto-discovers assets instead of requiring you to
// hand-place files. Krunker's own client builds prop paths as:
//
//     <assets_root>/models/<name>.obj
//     <assets_root>/textures/<name>.png
//
// (see prefab.c's prefab_init, which literally snprintf's "models/%s.obj"
// and "textures/%s.png"). So if you extract the full asset dump keeping its
// own internal folder layout -- a top-level `models/` and `textures/`
// folder full of flat, flatly-named files -- and point ASSETS_ROOT at that
// extracted folder, PREFAB_TABLE below (every named prop KrunkNative knows
// about, with the *real* per-prefab scale baked into their client) gets
// wired up automatically. No manual copying/renaming needed.
//
// If your extracted dump has a different top-level layout (e.g. everything
// under an extra `assets/` folder, or nested differently), just change
// ASSETS_ROOT below to point at whichever folder directly contains
// `models/` and `textures/` as immediate children.
ASSETS_ROOT :: "./mod"

import "core:fmt"
import "core:os"
import rl "vendor:raylib"

PrefabEntry :: struct {
	index: int,
	name:  string,
	scale: f32,
}

// Every named (i.e. mesh-backed) prefab from prefab.c's `prefab_models[]`,
// in the same order as the real `PrefabType` enum -- entries left out here
// (cube, ladder, plane, spawnpoint, ramp, billboard, flag, trigger, sphere,
// cylinder, etc.) are software-generated or invisible in the real client
// too, so they correctly stay as our colored-box fallback.
PREFAB_TABLE := []PrefabEntry {
	{1, "crate_0", 6.0},
	{2, "barrel_0", 4.0},
	{7, "vehicle_0", 20.0},
	{8, "stack_0", 6.0},
	// tree_0.obj contains 8-vertex face lines that raylib's bundled TinyObj
	// parser aborts on.  This compatible mod variant is triangulatable by it.
	{15, "tree_0_1", 10.0},
	{16, "cone_0", 4.0},
	{17, "container_0", 7.0},
	{18, "grass_0", 32.0}, // transparent + 4-frame animated in the real client; we render it static
	{19, "containerr_0", 7.0},
	{20, "acidbarrel_0", 4.0},
	{21, "door_0", 5.0},
	{22, "window_0", 6.0}, // transparent
	{28, "teddy_0", 6.0},
	{36, "cardb_0", 5.0},
	{37, "pallet_0", 6.0},
	{49, "police_0", 4.0},
	{50, "cage_0", 6.0},
	{51, "ebarrel_0", 4.0},
	{54, "ghost_0", 4.0},
	{56, "pumpkin_0", 4.0},
	{58, "skeleton_0", 4.0},
	{59, "knight_0", 4.0},
}

// Manual overrides for anything that doesn't follow Krunker's own
// models/<name>.obj + textures/<name>.png naming convention -- e.g. the
// standalone model.obj you had before, if you ever pin down which `i` it
// actually belongs to (see the long comment in a previous version of this
// file re: the i=29/PREFAB_TRIGGER mismatch -- still unresolved).
EXTRA_PROP_FILES := map[int]struct {
	obj:   string,
	tex:   string,
	scale: f32,
}{}

PropAsset :: struct {
	model:         rl.Model,
	scale:         f32,
	base_offset_y: f32, // -bounds_min.y of the raw mesh, so it can be planted at its base rather than its geometric center
}

PropModels :: map[int]PropAsset

load_one :: proc(models: ^PropModels, index: int, obj_path, tex_path: string, scale: f32) -> bool {
	if !os.exists(obj_path) {
		return false
	}

	model := rl.LoadModel(cstring_from(obj_path))
	if model.meshCount == 0 {
		fmt.eprintln("props: found but failed to load model for i =", index, "(", obj_path, ")")
		return false
	}

	// Real Krunker prop meshes are exported sitting on their base, but we
	// can't assume that -- compute it so a mesh authored around its center
	// still gets planted on the ground at the map's `p` position instead of
	// floating or half-buried.
	bbox := rl.GetModelBoundingBox(model)

	if os.exists(tex_path) {
		tex := rl.LoadTexture(cstring_from(tex_path))
		if tex.id != 0 && model.materialCount > 0 {
			rl.SetMaterialTexture(&model.materials[0], .ALBEDO, tex)
		}
	}

	models[index] = PropAsset {
		model         = model,
		scale         = scale,
		base_offset_y = -bbox.min.y,
	}
	return true
}

load_prop_models :: proc(m: ^GameMap) -> PropModels {
	models := make(PropModels)
	found, total := 0, 0

	// Only parse prefabs that this map actually uses.  A full mod dump can
	// contain OBJ files with geometry that raylib's TinyObj parser cannot
	// represent (for example, high-sided n-gons).  KrunkNative's fast_obj
	// loader tolerates those files, but raylib may assert while parsing them.
	used_indices := make(map[int]struct{})
	defer delete(used_indices)
	for object in m.objects {
		if object.prop_i >= 0 {
			used_indices[object.prop_i] = {}
		}
	}

	for entry in PREFAB_TABLE {
		if _, used := used_indices[entry.index]; !used do continue
		total += 1
		obj_path := fmt.aprintf("%s/models/%s.obj", ASSETS_ROOT, entry.name)
		tex_path := fmt.aprintf("%s/textures/%s.png", ASSETS_ROOT, entry.name)
		if load_one(&models, entry.index, obj_path, tex_path, entry.scale) {
			found += 1
		}
	}

	for index, files in EXTRA_PROP_FILES {
		if load_one(&models, index, files.obj, files.tex, files.scale) {
			found += 1
			total += 1
		}
	}

	if found == 0 {
		fmt.println(
			"props: none found under",
			ASSETS_ROOT,
			"-- check ASSETS_ROOT in models.odin points at the folder containing models/ and textures/. Falling back to colored boxes for every prop.",
		)
	} else {
		fmt.println("props: loaded", found, "/", total, "known prefabs from", ASSETS_ROOT)
	}

	return models
}

destroy_prop_models :: proc(models: ^PropModels) {
	for _, asset in models {
		rl.UnloadModel(asset.model)
	}
	delete(models^)
}

// Odin string -> cstring needs a null-terminated copy; fine to do this a
// couple dozen times at startup only.
cstring_from :: proc(s: string) -> cstring {
	return fmt.ctprint(s)
}
