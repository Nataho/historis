class_name NetworkBoard extends Board

const SCENE: PackedScene = preload("res://classes/boards/NetworkBoard/NetworkBoard.tscn")

var _is_spectator: bool = false

static func create(id: int, target: int, spectator: bool = false) -> NetworkBoard:
	var inst: NetworkBoard = SCENE.instantiate()
	inst.player_id = id
	inst.target_id = target
	inst._is_spectator = spectator
	inst.is_battle = true
	return inst

func _ready() -> void:
	_initialize_engine()
	super._ready()
	EventBus.received_board_data.connect(_on_network_data_received)

# WE OVERRIDE ENGINE INITIALIZATION ENTIRELY!
# A puppet board DOES NOT run an engine. It just sets up the 
# UI elements (PieceController & Queue slots) so it can draw network packets.
func _initialize_engine() -> void:
	if pieces_controller == null:
		pieces_controller = PiecesController.new()
		add_child(pieces_controller)
	
	if queue_display != null:
		if hold_slot != null and hold_slot.tile_texture == null:
			hold_slot.tile_texture = queue_display.tile_texture
		queue_display.setup_slots()

func start(countdown: int = 3) -> void:
	# NetworkBoard is just a screen, it just plays the visual countdown
	if countdown > 0:
		for i in range(countdown, 0, -1):
			tick.text = str(i)
			Audio.play_sound("tick_" + str(i))
			if anim != null: anim.play("popup")
			await get_tree().create_timer(1).timeout
	
	tick.text = "GO!"
	Audio.play_sound("tick_go")
	if anim != null: anim.play("popup")
	
	await get_tree().create_timer(1.2).timeout
	tick.text = ""

# We OVERRIDE reset because we have no engine to restart.
# We just wipe the visuals clean for the next round.
func reset(new_seed: int = -1) -> void:
	if placed_tiles_layer != null: placed_tiles_layer.clear()
	if active_piece_layer != null: active_piece_layer.clear()
	if ghost_piece_layer != null: ghost_piece_layer.clear()
	if hold_slot != null: hold_slot.clear()
	b2b_streak = 0
	lines_cleared = 0
	_update_clear_message(0, 0, false)
	_set_meter_height(0)
	if tick != null: tick.text = ""

func _on_network_garbage_received(_chunks: Array, _sender_id: int, _receiver_id: int) -> void:
	# Ignore local EventBus garbage! The puppet meter is synced exclusively via network.
	pass

func _on_network_data_received(payload: Dictionary) -> void:
	if payload.is_empty(): return
	
	var type = payload.get("update_type", "")
	var sender_id = int(payload.get("player_id", -1))
	
	if type == "garbage":
		if sender_id == player_id:
			var chunks = payload.get("chunks", [])
			var target = int(payload.get("target_id", -1))
			EventBus.send_garbage.emit(chunks, sender_id, target)
		return
	
	if sender_id != player_id: return
		
	match type:
		"piece_update": _apply_piece_update(payload)
		"lock": _apply_lock_update(payload)
		"queue": _apply_queue_update(payload)
		"hold": _apply_hold_update(payload)
		"hard_drop": Audio.play_sound("hard_drop")
		"spin": Audio.play_sound("clear1")
		"garbage_meter": _set_meter_height(int(payload.get("pending_total", 0)))
		"player_kod": _apply_ko_update(payload)

func _apply_piece_update(payload: Dictionary) -> void:
	if active_piece_layer == null or ghost_piece_layer == null: return
	active_piece_layer.clear()
	ghost_piece_layer.clear()
	
	var piece_type = int(payload.get("piece_type", 0))
	for c in payload.get("piece_cells", []):
		var pos = Vector2i(int(c.get("x", 0)), int(c.get("y", 0)))
		active_piece_layer.set_cell(pos + GRID_OFFSET, 0, Vector2i(piece_type, 0))
		
	for c in payload.get("ghost_cells", []):
		var pos = Vector2i(int(c.get("x", 0)), int(c.get("y", 0)))
		ghost_piece_layer.set_cell(pos + GRID_OFFSET, 0, Vector2i(piece_type, 0))

func _apply_lock_update(payload: Dictionary) -> void:
	if placed_tiles_layer == null: return
	set_placed_tiles_data(payload.get("placed_tiles", []))
	
	if active_piece_layer != null: active_piece_layer.clear()
	if ghost_piece_layer != null: ghost_piece_layer.clear()
	
	var lines_cleared_val = int(payload.get("lines_cleared", 0))
	var combo_val = int(payload.get("combo_count", -1))
	var is_tspin_val = bool(payload.get("is_tspin", false))
	b2b_streak = int(payload.get("b2b_streak", b2b_streak))
	lines_cleared = int(payload.get("total_lines_cleared", lines_cleared))
	
	if lines_cleared_val > 0 or is_tspin_val:
		Audio.play_sound("clear" + str(lines_cleared_val) if lines_cleared_val < 5 and lines_cleared_val > 0 else "clear4")
		if combo_val > 0:
			Audio.play_sound("combo" + str(combo_val) if combo_val < 7 else "combo7")
		_update_clear_message(lines_cleared_val, combo_val, is_tspin_val)
		
	if payload.has("pending_garbage"):
		_set_meter_height(int(payload.get("pending_garbage", 0)))

func _apply_queue_update(payload: Dictionary) -> void:
	if queue_display == null or pieces_controller == null: return
	var next_pieces = payload.get("next_pieces", [])
	var typed_pieces: Array[String] = []
	for p in next_pieces: typed_pieces.append(str(p))
	queue_display.update_display(typed_pieces, pieces_controller.get_piece_forms(), PIECE_ID_MAP)

func _apply_hold_update(payload: Dictionary) -> void:
	if hold_slot == null or pieces_controller == null: return
	var piece_key = str(payload.get("hold_piece", ""))
	if piece_key.is_empty():
		hold_slot.clear()
	else:
		var ascii_grid = pieces_controller.get_piece_forms().get(piece_key, [])
		var tile_idx = PIECE_ID_MAP.get(piece_key, 0)
		hold_slot.render_ascii_piece(ascii_grid, tile_idx)
		Audio.play_sound("hold")

func _apply_ko_update(payload: Dictionary) -> void:
	last_attacker = int(payload.get("attacker_id", -1))
	Audio.play_sound("KO")
	tick.text = "KO!"
	board_topped_out.emit()
	EventBus.player_topped_out.emit(player_id, last_attacker)
	placed_tiles_layer.modulate = Color(0.3,0.3,0.3)
	shake(16.0, 0.3)
	if anim != null: anim.play("popup")

func _set_meter_height(pending_lines: int) -> void:
	if meter == null: return
	var capped = min(pending_lines, GARBAGE_METER_MAX_LINES)
	if _meter_stylebox == null:
		var base_stylebox: StyleBox = meter.get_theme_stylebox("panel")
		_meter_stylebox = base_stylebox.duplicate() as StyleBoxFlat if base_stylebox is StyleBoxFlat else StyleBoxFlat.new()
		meter.add_theme_stylebox_override("panel", _meter_stylebox)
	var fill_ratio: float = float(capped) / float(GARBAGE_METER_MAX_LINES)
	_target_meter_height = int(meter.size.y * fill_ratio)
