class_name PiecesController extends Node

const MODERN_GUIDELINE_FORMS = "res://resource/json/piece_forms/modern_guideline.json"

var piece_forms: Dictionary = {}

# Pre-defined SRS Piece Shape States (0: 0°, 1: 90°, 2: 180°, 3: 270°)
const PIECE_STATES: Dictionary = {
	"I": [
		[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		[Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)],
		[Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)],
		[Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)]
	],
	"J": [
		[Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)],
		[Vector2i(1, -1), Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, 0), Vector2i(-1, 0)],
		[Vector2i(-1, 1), Vector2i(0, 1), Vector2i(0, 0), Vector2i(0, -1)]
	],
	"L": [
		[Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)],
		[Vector2i(1, 1), Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(-1, 1), Vector2i(1, 0), Vector2i(0, 0), Vector2i(-1, 0)],
		[Vector2i(-1, -1), Vector2i(0, 1), Vector2i(0, 0), Vector2i(0, -1)]
	],
	"S": [
		[Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0)],
		[Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -1), Vector2i(0, 0)],
		[Vector2i(0, 1), Vector2i(-1, 1), Vector2i(1, 0), Vector2i(0, 0)],
		[Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 1), Vector2i(0, 0)]
	],
	"Z": [
		[Vector2i(-1, -1), Vector2i(0, -1), Vector2i(0, 0), Vector2i(1, 0)],
		[Vector2i(1, -1), Vector2i(1, 0), Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(1, 1), Vector2i(0, 1), Vector2i(0, 0), Vector2i(-1, 0)],
		[Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, -1)]
	],
	"T": [
		[Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)],
		[Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, 0), Vector2i(-1, 0)],
		[Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, 0), Vector2i(0, -1)]
	],
	"O": [
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	]
}

const KICKS_JLSTZ: Dictionary = {
	"0->1": [Vector2i(0,0), Vector2i(-1,0), Vector2i(-1,-1), Vector2i(0,2), Vector2i(-1,2)],
	"1->0": [Vector2i(0,0), Vector2i(1,0),  Vector2i(1,1),   Vector2i(0,-2), Vector2i(1,-2)],
	"1->2": [Vector2i(0,0), Vector2i(1,0),  Vector2i(1,1),   Vector2i(0,-2), Vector2i(1,-2)],
	"2->1": [Vector2i(0,0), Vector2i(-1,0), Vector2i(-1,-1), Vector2i(0,2), Vector2i(-1,2)],
	"2->3": [Vector2i(0,0), Vector2i(1,0),  Vector2i(1,-1),  Vector2i(0,2), Vector2i(1,2)],
	"3->2": [Vector2i(0,0), Vector2i(-1,0), Vector2i(-1,1),  Vector2i(0,-2), Vector2i(-1,-2)],
	"3->0": [Vector2i(0,0), Vector2i(-1,0), Vector2i(-1,1),  Vector2i(0,-2), Vector2i(-1,-2)],
	"0->3": [Vector2i(0,0), Vector2i(1,0),  Vector2i(1,-1),  Vector2i(0,2), Vector2i(1,2)]
}

const KICKS_I: Dictionary = {
	"0->1": [Vector2i(0,0), Vector2i(-2,0), Vector2i(1,0),  Vector2i(-2,1), Vector2i(1,-2)],
	"1->0": [Vector2i(0,0), Vector2i(2,0),  Vector2i(-1,0), Vector2i(2,-1), Vector2i(-1,2)],
	"1->2": [Vector2i(0,0), Vector2i(-1,0), Vector2i(2,0),  Vector2i(-1,-2),Vector2i(2,1)],
	"2->1": [Vector2i(0,0), Vector2i(1,0),  Vector2i(-2,0), Vector2i(1,2),  Vector2i(-2,-1)],
	"2->3": [Vector2i(0,0), Vector2i(2,0),  Vector2i(-1,0), Vector2i(2,-1), Vector2i(-1,2)],
	"3->2": [Vector2i(0,0), Vector2i(-2,0), Vector2i(1,0),  Vector2i(-2,1), Vector2i(1,-2)],
	"3->0": [Vector2i(0,0), Vector2i(1,0),  Vector2i(-2,0), Vector2i(1,2),  Vector2i(-2,-1)],
	"0->3": [Vector2i(0,0), Vector2i(-1,0), Vector2i(2,0),  Vector2i(-1,-2),Vector2i(2,1)]
}

const KICKS_180_JLSTZ: Dictionary = {
	"0->2": [Vector2i(0,0), Vector2i(0,-1), Vector2i(1,-1), Vector2i(-1,-1), Vector2i(1,0), Vector2i(-1,0)],
	"2->0": [Vector2i(0,0), Vector2i(0,1), Vector2i(-1,1), Vector2i(1,1), Vector2i(-1,0), Vector2i(1,0)],
	"1->3": [Vector2i(0,0), Vector2i(1,0), Vector2i(1,-2), Vector2i(1,-1), Vector2i(0,-2), Vector2i(0,-1)],
	"3->1": [Vector2i(0,0), Vector2i(-1,0), Vector2i(-1,-2), Vector2i(-1,-1), Vector2i(0,-2), Vector2i(0,-1)]
}

const KICKS_180_I: Dictionary = {
	"0->2": [Vector2i(0,0), Vector2i(-1,0), Vector2i(2,0), Vector2i(-1,-1), Vector2i(2,2)],
	"2->0": [Vector2i(0,0), Vector2i(1,0), Vector2i(-2,0), Vector2i(1,1), Vector2i(-2,-2)],
	"1->3": [Vector2i(0,0), Vector2i(0,-1), Vector2i(0,2), Vector2i(-1,-1), Vector2i(2,-1)],
	"3->1": [Vector2i(0,0), Vector2i(0,1), Vector2i(0,-2), Vector2i(1,1), Vector2i(-2,1)]
}

func get_180_kick_table(piece_type: String) -> Dictionary:
	match piece_type.to_upper():
		"I": return KICKS_180_I
		"O": return {}
		_: return KICKS_180_JLSTZ

func _ready() -> void:
	get_piece_forms()

func get_piece_forms() -> Dictionary:
	if piece_forms.is_empty():
		var raw_data: Dictionary = Tools.read_json(MODERN_GUIDELINE_FORMS)
		for key in raw_data:
			piece_forms[str(key).to_upper()] = raw_data[key]
	return piece_forms

func get_kick_table(piece_type: String) -> Dictionary:
	match piece_type.to_upper():
		"I": return KICKS_I
		"O": return {}
		_: return KICKS_JLSTZ

func get_state_offsets(piece_type: String, state: int) -> Array[Vector2i]:
	var key = piece_type.to_upper()
	if PIECE_STATES.has(key):
		var state_list: Array = PIECE_STATES[key]
		var result: Array[Vector2i] = []
		for vec in state_list[state % 4]:
			result.append(vec)
		return result
	return []
