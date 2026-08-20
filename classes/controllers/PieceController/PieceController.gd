class_name PieceController extends Node

const PIECE_CONTROLLER = preload("uid://cfog3el6s1t8e")

static func create() -> PieceController:
	var obj = PIECE_CONTROLLER.instantiate()
	return obj
