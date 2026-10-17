@tool
extends SceneTree

## Editor-side generation tool for procedural Voronoi fracture assets.
## Fractures cubes, ramps, outer corners, and inner corners using VoronoiShatter.
## Saves reusable ArrayMesh and ConvexPolygonShape3D assets under res://assets/generated/fractures/.

const OUTPUT_DIR: String = "res://assets/generated/fractures/"
const MANIFEST_PATH: String = "res://assets/generated/fractures/manifest.json"

func _init() -> void:
	print("[FractureGenerator] Starting procedural Voronoi fracture asset generation...")
	var success := run_generation()
	if success:
		print("[FractureGenerator] ALL FRACTURE ASSETS GENERATED AND SAVED SUCCESSFULLY!")
		quit(0)
	else:
		printerr("[FractureGenerator] Generation failed!")
		quit(1)

func run_generation() -> bool:
	# Ensure target directory exists
	var da := DirAccess.open("res://")
	if da != null:
		da.make_dir_recursive("assets/generated/fractures")
	else:
		DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)

	var gen := VoronoiGenerator.new()
	var root := Node3D.new()
	root.add_child(gen)

	# Generate canonical watertight manifold geometries in [0, 1]^3
	var geometries: Dictionary = {
		"cube": _build_cube_mesh(),
		"ramp": _build_ramp_mesh(),
		"corner": _build_corner_mesh(),
		"inner_corner": _build_inner_corner_mesh()
	}

	# Configuration per shape: VoronoiShatter requires >= 6 samples to avoid incomplete geometry
	var configs: Dictionary = {
		"cube": {"samples": 8, "seed": 42},
		"ramp": {"samples": 8, "seed": 42},
		"corner": {"samples": 8, "seed": 42},
		"inner_corner": {"samples": 8, "seed": 42}
	}

	var manifest: Dictionary = {}

	for shape_name in geometries.keys():
		print("[FractureGenerator] Generating fractures for shape: ", shape_name)
		var base_mesh: ArrayMesh = geometries[shape_name]
		var mi := MeshInstance3D.new()
		mi.mesh = base_mesh
		root.add_child(mi)

		var cfg_data: Dictionary = configs[shape_name]
		var cfg := VoronoiGeneratorConfig.new()
		cfg.num_samples = cfg_data["samples"]
		cfg.random_seed = cfg_data["seed"]

		var results: Array[VoronoiMesh] = gen.create_from_mesh(mi, cfg)
		mi.queue_free()

		if results.is_empty():
			printerr("[FractureGenerator] ERROR: No fracture pieces generated for ", shape_name)
			root.free()
			return false

		print("[FractureGenerator] -> Generated ", results.size(), " pieces for ", shape_name)

		var pieces_data: Array = []
		for i in range(results.size()):
			var vm: VoronoiMesh = results[i]
			if vm == null or vm.mesh == null or vm.mesh.get_surface_count() == 0:
				continue

			var piece_mesh: ArrayMesh = vm.mesh
			var mesh_filename := "%s_mesh_%d.res" % [shape_name, i]
			var shape_filename := "%s_shape_%d.res" % [shape_name, i]
			var mesh_path := OUTPUT_DIR + mesh_filename
			var shape_path := OUTPUT_DIR + shape_filename

			# Build matching ConvexPolygonShape3D from mesh geometry
			var col_shape := ConvexPolygonShape3D.new()
			var faces: PackedVector3Array = piece_mesh.get_faces()
			col_shape.set_points(faces)

			# Save mesh resource
			var err_mesh := ResourceSaver.save(piece_mesh, mesh_path, ResourceSaver.FLAG_COMPRESS)
			if err_mesh != OK:
				printerr("[FractureGenerator] Failed to save mesh: ", mesh_path, " error: ", err_mesh)
				root.free()
				return false

			# Save shape resource
			var err_shape := ResourceSaver.save(col_shape, shape_path, ResourceSaver.FLAG_COMPRESS)
			if err_shape != OK:
				printerr("[FractureGenerator] Failed to save shape: ", shape_path, " error: ", err_shape)
				root.free()
				return false

			# Piece center relative to voxel center (0.5, 0.5, 0.5)
			# vm.position is -offset, where offset is the center in voxel [0, 1]^3 space
			var piece_center_in_voxel: Vector3 = -vm.position
			var rel_offset: Vector3 = piece_center_in_voxel - Vector3(0.5, 0.5, 0.5)

			pieces_data.append({
				"index": i,
				"mesh_path": mesh_path,
				"shape_path": shape_path,
				"offset": [rel_offset.x, rel_offset.y, rel_offset.z],
				"surface_count": piece_mesh.get_surface_count()
			})

		manifest[shape_name] = pieces_data

	root.free()

	# Save manifest JSON
	var json_str := JSON.stringify(manifest, "\t")
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.WRITE)
	if f == null:
		printerr("[FractureGenerator] Failed to open manifest file for writing: ", FileAccess.get_open_error())
		return false
	f.store_string(json_str)
	f.close()
	print("[FractureGenerator] Saved manifest to: ", MANIFEST_PATH)
	return true

# ── Geometry Builders: Watertight Manifold Polyhedra in [0, 1]^3 ───────────────

## Watertight unit cube [0, 1]^3
func _build_cube_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var v000 := Vector3(0, 0, 0)
	var v100 := Vector3(1, 0, 0)
	var v101 := Vector3(1, 0, 1)
	var v001 := Vector3(0, 0, 1)
	var v010 := Vector3(0, 1, 0)
	var v110 := Vector3(1, 1, 0)
	var v111 := Vector3(1, 1, 1)
	var v011 := Vector3(0, 1, 1)

	# Bottom y=0 (DOWN)
	_add_tri(st, v000, v001, v101); _add_tri(st, v000, v101, v100)
	# Top y=1 (UP)
	_add_tri(st, v010, v110, v111); _add_tri(st, v010, v111, v011)
	# Back z=0 (FORWARD)
	_add_tri(st, v000, v100, v110); _add_tri(st, v000, v110, v010)
	# Front z=1 (BACK)
	_add_tri(st, v001, v011, v111); _add_tri(st, v001, v111, v101)
	# Left x=0 (LEFT)
	_add_tri(st, v000, v010, v011); _add_tri(st, v000, v011, v001)
	# Right x=1 (RIGHT)
	_add_tri(st, v100, v101, v111); _add_tri(st, v100, v111, v110)

	st.generate_normals()
	st.index()
	return st.commit()

## Watertight canonical ramp: slope descending toward +X
func _build_ramp_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var v0 := Vector3(0, 0, 0) # bottom back-left
	var v1 := Vector3(1, 0, 0) # bottom back-right
	var v2 := Vector3(1, 0, 1) # bottom front-right
	var v3 := Vector3(0, 0, 1) # bottom front-left
	var t0 := Vector3(0, 1, 0) # top back-left
	var t3 := Vector3(0, 1, 1) # top front-left

	# Bottom face (y=0, DOWN)
	_add_tri(st, v0, v3, v2); _add_tri(st, v0, v2, v1)
	# Back wall (x=0, LEFT)
	_add_tri(st, v0, t0, t3); _add_tri(st, v0, t3, v3)
	# Side wedge z=0 (FORWARD)
	_add_tri(st, v0, v1, t0)
	# Side wedge z=1 (BACK)
	_add_tri(st, v3, t3, v2)
	# Top slope (descending toward +X)
	_add_tri(st, t0, v1, v2); _add_tri(st, t0, v2, t3)

	st.generate_normals()
	st.index()
	return st.commit()

## Watertight canonical outer corner: low corner toward (+1, +1)
func _build_corner_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var b0 := Vector3(0, 0, 0)
	var b1 := Vector3(1, 0, 0)
	var b2 := Vector3(1, 0, 1)
	var b3 := Vector3(0, 0, 1)
	var h  := Vector3(0, 1, 0) # single high peak at (0, 1, 0)

	# Bottom (y=0, DOWN)
	_add_tri(st, b0, b3, b2); _add_tri(st, b0, b2, b1)
	# Back wall z=0 (FORWARD)
	_add_tri(st, b0, b1, h)
	# Left wall x=0 (LEFT)
	_add_tri(st, b0, h, b3)
	# Sloped surfaces meeting at low corner b2
	_add_tri(st, h, b1, b2); _add_tri(st, h, b2, b3)

	st.generate_normals()
	st.index()
	return st.commit()

## Watertight canonical inner corner: single low corner at (+1, +1)
func _build_inner_corner_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var b0 := Vector3(0, 0, 0)
	var b1 := Vector3(1, 0, 0)
	var b2 := Vector3(1, 0, 1) # Low corner
	var b3 := Vector3(0, 0, 1)
	var t0 := Vector3(0, 1, 0)
	var t1 := Vector3(1, 1, 0)
	var t3 := Vector3(0, 1, 1)

	# Bottom y=0 (DOWN)
	_add_tri(st, b0, b3, b2); _add_tri(st, b0, b2, b1)
	# Left wall x=0 (LEFT)
	_add_tri(st, b0, t0, t3); _add_tri(st, b0, t3, b3)
	# Back wall z=0 (FORWARD)
	_add_tri(st, b0, b1, t1); _add_tri(st, b0, t1, t0)
	# Right wall x=1 (RIGHT)
	_add_tri(st, b1, b2, t1)
	# Front wall z=1 (BACK)
	_add_tri(st, b3, t3, b2)
	# Top slopes descending to Low (b2)
	_add_tri(st, t0, t1, b2); _add_tri(st, t0, b2, t3)

	st.generate_normals()
	st.index()
	return st.commit()

func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
