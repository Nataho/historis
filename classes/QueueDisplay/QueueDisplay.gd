extends VBoxContainer
class_name QueueDisplay

@export var tile_texture: Texture2D
@export var atlas_columns: int = 12
@export var x_separation: float = 1.0

# Grabs child slot nodes automatically
@onready var slots: Array[Node] = get_children()

func setup_slots() -> void:
	for slot in slots:
		if slot is QueueSlot:
			slot.tile_texture = tile_texture
			slot.atlas_columns = atlas_columns
			slot.x_separation = x_separation

func update_display(next_piece_keys: Array[String], json_forms: Dictionary, piece_indices: Dictionary) -> void:
	for i in range(slots.size()):
		if i < next_piece_keys.size() and slots[i] is QueueSlot:
			var piece_key = next_piece_keys[i]
			var ascii_grid = json_forms.get(piece_key, [])
			var tile_idx = piece_indices.get(piece_key, 0)
			
			slots[i].render_ascii_piece(ascii_grid, tile_idx)
