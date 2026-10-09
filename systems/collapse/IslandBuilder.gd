class_name IslandBuilder
extends RefCounted

## Groups unsupported grid cells into connected component islands.
## Disconnected unsupported structures are partitioned into separate independent islands.

const NEIGHBORS_6: Array[Vector3i] = [
	Vector3i(0, 1, 0),  # Up
	Vector3i(0, -1, 0), # Down
	Vector3i(1, 0, 0),  # Right (+X)
	Vector3i(-1, 0, 0), # Left (-X)
	Vector3i(0, 0, 1),  # Forward (+Z)
	Vector3i(0, 0, -1)  # Backward (-Z)
]

## Partitions an array of cells into connected component groups (islands) based on 6-connectivity.
## Returns an Array of Array[Vector3i].
static func group_islands(unsupported_cells: Array[Vector3i]) -> Array:
	if unsupported_cells.is_empty():
		return []

	# Populate set for O(1) membership checks and removals
	var cell_set: Dictionary = {}
	for c in unsupported_cells:
		cell_set[c] = true

	var islands: Array = []

	for c in unsupported_cells:
		if not cell_set.has(c):
			continue # Already processed in a previous island

		# Seed a new connected island
		var island: Array[Vector3i] = []
		var queue: Array[Vector3i] = [c]
		cell_set.erase(c)

		var head: int = 0
		while head < queue.size():
			var curr: Vector3i = queue[head]
			head += 1
			island.append(curr)

			for offset in NEIGHBORS_6:
				var neighbor: Vector3i = curr + offset
				if cell_set.has(neighbor):
					cell_set.erase(neighbor)
					queue.append(neighbor)

		islands.append(island)

	return islands
