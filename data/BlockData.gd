class_name BlockData
extends RefCounted

## Represents the canonical data for a single block in the construction grid or a debris island.
## Preserves block identity, type, durability, and arbitrary metadata.

var block_type: StringName = &"stone"
var durability: float = 1.0 # 0.0 to 1.0 (or >1.0 for reinforced)
var metadata: Dictionary = {}

func _init(p_type: StringName = &"stone", p_durability: float = 1.0, p_metadata: Dictionary = {}) -> void:
	block_type = p_type
	durability = p_durability
	metadata = p_metadata.duplicate(true)

## Creates a deep copy of this BlockData instance.
func duplicate_data() -> BlockData:
	return BlockData.new(block_type, durability, metadata)

## Serializes this block to a dictionary for JSON/Resource persistence.
func to_dict() -> Dictionary:
	return {
		"block_type": String(block_type),
		"durability": durability,
		"metadata": metadata.duplicate(true)
	}

## Deserializes block data from a dictionary safely.
static func from_dict(dict: Dictionary) -> BlockData:
	var type_str: String = dict.get("block_type", "stone")
	var dur: float = float(dict.get("durability", 1.0))
	var meta: Dictionary = dict.get("metadata", {})
	return BlockData.new(StringName(type_str), dur, meta)
