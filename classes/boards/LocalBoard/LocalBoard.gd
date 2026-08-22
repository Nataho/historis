class_name LocalBoard extends MultiplayerBoard

const SCENE: PackedScene = preload("res://classes/boards/LocalBoard/LocalBoard.tscn")

static func create(id: int, target: int, seed_val: int = -1) -> LocalBoard:
	var inst: LocalBoard = SCENE.instantiate()
	inst.player_id = id
	inst.target_id = target
	inst.randomization_seed = seed_val
	inst.is_local_player = true
	inst.is_battle = true
	return inst

func _ready() -> void:
	super._ready()
	_connect_network_dispatch_signals()

func sync_full_state() -> void:
	if engine == null: return
	_on_local_queue_changed(engine.queue.slice(0, PREVIEW_COUNT))
	if not engine.hold_piece_type.is_empty():
		_on_local_hold_changed(engine.hold_piece_type)
	if not engine.active_piece_type.is_empty():
		var world_cells: Array[Vector2i] = []
		for offset in engine.active_offsets:
			var cell = engine.active_pos + offset
			if cell.y >= -engine.BUFFER_HEIGHT:
				world_cells.append(cell)
		_on_local_piece_moved(world_cells, engine.active_piece_index)

func _connect_network_dispatch_signals() -> void:
	if engine != null:
		_bind_engine_signals()

func _initialize_engine() -> void:
	super._initialize_engine()
	_bind_engine_signals()

func _bind_engine_signals() -> void:
	if engine == null: return
	
	if not engine.active_piece_moved.is_connected(_on_local_piece_moved):
		engine.active_piece_moved.connect(_on_local_piece_moved)
	if not engine.lines_cleared.is_connected(_on_local_lines_cleared):
		engine.lines_cleared.connect(_on_local_lines_cleared)
	if not engine.board_updated.is_connected(_on_local_board_updated):
		engine.board_updated.connect(_on_local_board_updated)
	if not engine.queue_changed.is_connected(_on_local_queue_changed):
		engine.queue_changed.connect(_on_local_queue_changed)
	if not engine.hold_changed.is_connected(_on_local_hold_changed):
		engine.hold_changed.connect(_on_local_hold_changed)
	if not engine.hard_dropped.is_connected(_on_local_hard_dropped):
		engine.hard_dropped.connect(_on_local_hard_dropped)
	if not engine.garbage_received.is_connected(_on_local_garbage_meter_changed):
		engine.garbage_received.connect(_on_local_garbage_meter_changed)
	if not engine.game_over.is_connected(_on_local_game_over):
		engine.game_over.connect(_on_local_game_over)

func _on_local_piece_moved(piece_cells: Array[Vector2i], piece_type: int) -> void:
	var serialized_cells = []
	for c in piece_cells:
		serialized_cells.append({"x": c.x, "y": c.y})
	
	var serialized_ghost = []
	if engine != null:
		var ghost_origin = engine.get_ghost_position()
		for offset in engine.active_offsets:
			var cell = ghost_origin + offset
			if cell.y >= -engine.BUFFER_HEIGHT:
				serialized_ghost.append({"x": cell.x, "y": cell.y})
				
	var packet = {
		"update_type": "piece_update",
		"player_id": player_id,
		"piece_cells": serialized_cells,
		"piece_type": piece_type,
		"ghost_cells": serialized_ghost,
		"active_pos": {"x": engine.active_pos.x, "y": engine.active_pos.y} if engine != null else {"x": 0, "y": 0}
	}
	_dispatch_to_network(packet)

func _on_local_lines_cleared(line_count: int, combo_count_val: int, is_tspin: bool) -> void:
	call_deferred("_send_lock_packet", line_count, combo_count_val, is_tspin)

func _on_local_board_updated(_grid_matrix: Array) -> void:
	# Keep placed tiles synced on piece placement
	call_deferred("_send_lock_packet", 0, -1, false)

func _send_lock_packet(line_count: int = 0, combo_count_val: int = -1, is_tspin: bool = false) -> void:
	var packet = {
		"update_type": "lock",
		"player_id": player_id,
		"placed_tiles": get_placed_tiles_data(),
		"lines_cleared": line_count,
		"combo_count": combo_count_val,
		"is_tspin": is_tspin,
		"b2b_streak": b2b_streak,
		"total_lines_cleared": lines_cleared,
		"pending_garbage": engine.get_pending_garbage_total() if engine != null else 0
	}
	_dispatch_to_network(packet)

func _on_local_queue_changed(next_pieces: Array[String]) -> void:
	var packet = {
		"update_type": "queue",
		"player_id": player_id,
		"next_pieces": next_pieces
	}
	_dispatch_to_network(packet)

func _on_local_hold_changed(piece_key: String) -> void:
	var packet = {
		"update_type": "hold",
		"player_id": player_id,
		"hold_piece": piece_key
	}
	_dispatch_to_network(packet)

func _on_local_hard_dropped() -> void:
	var packet = {
		"update_type": "hard_drop",
		"player_id": player_id
	}
	_dispatch_to_network(packet)

func _on_local_garbage_meter_changed(pending_total: int) -> void:
	var packet = {
		"update_type": "garbage_meter",
		"player_id": player_id,
		"pending_total": pending_total
	}
	_dispatch_to_network(packet)

func _on_garbage_sent(chunks: Array) -> void:
	super._on_garbage_sent(chunks)
	var packet = {
		"update_type": "garbage",
		"player_id": player_id,
		"target_id": target_id,
		"chunks": chunks
	}
	_dispatch_to_network(packet)

func _on_local_game_over() -> void:
	var packet = {
		"update_type": "player_kod",
		"player_id": player_id,
		"attacker_id": last_attacker,
		"knockouts": knockouts
	}
	_dispatch_to_network(packet)

func _dispatch_to_network(data: Dictionary) -> void:
	data["player_id"] = player_id
	NetworkSync.send_board_data(data)
