extends VBoxContainer
class_name QueueDisplay

@export var tile_texture: Texture2D
@export var atlas_columns: int = 12
@export var x_separation: float = 1.0

var slots: Array[Node] = []

func _ready() -> void:
	setup_slots()

func setup_slots() -> void:
	slots = get_children()
	if tile_texture == null:
		tile_texture = preload("res://assets/textures/tiles.png")
	for slot in slots:
		if slot is QueueSlot:
			slot.tile_texture = tile_texture
			slot.atlas_columns = atlas_columns
			slot.x_separation = x_separation

func update_display(next_piece_keys: Array[String], json_forms: Dictionary, piece_indices: Dictionary) -> void:
	if slots.is_empty():
		setup_slots()
	for i in range(slots.size()):
		if i < next_piece_keys.size() and slots[i] is QueueSlot:
			var piece_key = next_piece_keys[i]
			var ascii_grid = json_forms.get(piece_key, [])
			var tile_idx = piece_indices.get(piece_key, 0)
			if slots[i].tile_texture == null:
				slots[i].tile_texture = tile_texture
				slots[i].atlas_columns = atlas_columns
				slots[i].x_separation = x_separation
			slots[i].render_ascii_piece(ascii_grid, tile_idx)
