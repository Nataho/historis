class_name TileController

enum PIECE_TYPE { Z, L, O, S, I, J, T }

const cw_matrix: Array[Vector2i] = [
	Vector2i(0, -1), 
	Vector2i(1, 0)
]

const ccw_matrix: Array[Vector2i] = [
	Vector2i(0, 1),
	Vector2i(-1, 0)
]

var coordinates: Vector2i = Vector2i.ZERO
var relative_coordinates: Vector2i = Vector2i.ZERO
var piece_type: PIECE_TYPE
var is_center: bool = false

func _init(initial_coords: Vector2i, type_idx: int = 0) -> void:
	self.coordinates = initial_coords
	self.piece_type = type_idx as PIECE_TYPE

# Uses your exact relative matrix transformation math
func rotate_tile(origin_pos: Vector2i, clockwise: bool) -> Vector2i:
	relative_coordinates = coordinates - origin_pos
	var rot_matrix: Array[Vector2i] = cw_matrix if clockwise else ccw_matrix
	
	var new_x_pos: int = (rot_matrix[0].x * relative_coordinates.x) + (rot_matrix[0].y * relative_coordinates.y)
	var new_y_pos: int = (rot_matrix[1].x * relative_coordinates.x) + (rot_matrix[1].y * relative_coordinates.y)
	
	coordinates = Vector2i(new_x_pos, new_y_pos) + origin_pos
	return coordinates

func get_tile_data() -> Dictionary:
	return {
		"pos_x": coordinates.x,
		"pos_y": coordinates.y,
		"type": piece_type
	}
