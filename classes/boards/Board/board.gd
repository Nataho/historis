class_name Board extends Control

signal board_topped_out
signal board_reset

const TARGET_TILE_SIZE: float = 27.0

@export var autostart:bool = false
@export var skipcountdown:bool = false

@export var BOARD_SIZE := Vector2i(10, 20)
var GRID_OFFSET := Vector2i(-BOARD_SIZE.x / 2, -BOARD_SIZE.y / 2)

@export var PREVIEW_COUNT: int = 5
@export var drop_interval: float = 1.0 # Seconds per natural gravity step

@onready var board_pivot: Control = $BoardPivot
@onready var grid_background: TileMapLayer = %GridBackground
@onready var placed_tiles_layer: TileMapLayer = %PlacedTiles
@onready var active_piece_layer: TileMapLayer = %ActivePieceLayer
@onready var ghost_piece_layer: TileMapLayer = %GhostPieceLayer
@onready var bg: Panel = %BG
@onready var meter: Panel = %Meter

@onready var hold_slot: QueueSlot = %HoldSlot
@onready var queue_display: QueueDisplay = %Queue

@onready var tick: Label = $BoardPivot/AnimationPivot/tick
@onready var anim: AnimationPlayer = %anim

@onready var kos_label: Label = %KOs
@onready var spin_label: Label = %spin
@onready var clear_label: Label = %clear
@onready var combo_label: Label = %combo
@onready var b2b_label: Label = %b2b


var engine: TetrisEngine 
var pieces_controller: PiecesController

const GARBAGE_METER_MAX_LINES: int = 20 # matches the ">20" threshold you sketched - beyond this needs the second/overflow meter
var _meter_stylebox: StyleBoxFlat # lazily duplicated so we don't mutate a shared theme resource
var _target_meter_height

#multiplayer variables
@export_group("player_settings")
@export var player_id:int = 0
@export var target_id:int = -1
@export var is_battle:bool = false
@export var instant_garbage: bool = false # false = rise 1 row every 0.1s, true = dump all pending garbage at once
var last_attacker: int = -1
var knockouts:int = 0
# --- Shared AI observation / action-space contract ---
# Lives here (not on OnnxBotBoard) so every board that needs it — the AI
# bots, AND MultiplayerBoard's human-play recorder — reads/encodes it
# identically by construction instead of via two copies that can drift.
@export_group("AI Observation")
@export var opponent_board: Board

const PIECE_ID_MAP: Dictionary = {
	"": 0, "Z": 1, "L": 2, "O": 3, "S": 4, "I": 5, "J": 6, "T": 7
}
const ACTION_SPACE_SIZE: int = 80

var b2b_streak: int = 0

func _ready() -> void:
	_setup_board_scale()
	
	kos_label.text = ""
	b2b_label.text = ""
	spin_label.text = ""
	clear_label.text = ""
	combo_label.text = ""
	tick.text = ""
	
	if autostart: start_sequence()
	_connect_signals()

func _connect_signals() -> void:
	EventBus.player_topped_out.connect(func(victim_id: int, attacker_id: int) -> void:
		print("[DEBUG][BOARD %d] Received TopOut Signal -> Victim: %d | Attacker: %d" % [player_id, victim_id, attacker_id])
		
		# If this board was the attacker who earned the KO:
		if attacker_id == player_id and victim_id != player_id:
			print("[KO!] Board %d knocked out player %d!" % [player_id, victim_id])
			knockouts += 1
			_update_knockouts()
	)

func _process(delta: float) -> void:
	if engine != null:
		engine.process_garbage(delta * 1000.0)
	
	if _meter_stylebox != null:
		_meter_stylebox.border_width_bottom = lerp(_meter_stylebox.border_width_bottom, _target_meter_height, delta *10)
	

func set_instant_garbage(value: bool) -> void:
	instant_garbage = value
	if engine != null:
		engine.instant_garbage = value

## Read-only snapshot of the current board — grid, active piece, hold,
## queue, garbage. Networking-agnostic on purpose: this class has no
## business knowing whether or how it gets sent anywhere. Whatever
## owns the actual sync (e.g. a future WebSocket/multiplayer class)
## should call this and do the sending itself.
##
## Reads straight from the engine's own public state (no local caching
## here) so there's exactly one source of truth and no window where
## this could return stale/empty data relative to what's live.
##
## `grid` and `next_queue` are duplicated (not the engine's live
## references) since callers may reasonably hold onto this Dictionary
## across frames — e.g. buffering a snapshot to diff or send later —
## and the engine mutates `grid`/`queue` in place every step.
func get_board_state() -> Dictionary:
	if engine == null:
		return {}

	return {
		"player_id": player_id,
		"grid": engine.grid.duplicate(true),
		"active_piece_type": engine.active_piece_type,
		"active_pos": engine.active_pos,
		"rotation_state": engine.rotation_state,
		"ghost_pos": engine.get_ghost_position(),
		"can_hold": engine.can_hold,
		"hold_piece": engine.hold_piece_type,
		"next_queue": engine.queue.slice(0, PREVIEW_COUNT),
		"pending_garbage": engine.get_pending_garbage_total(),
	}

## The exact 413-float encoding the AI bots (and now the human-play
## recorder) both read placement decisions against. Moved here from
## OnnxBotBoard so there's one implementation, not two that can drift
## apart. Relies on `engine`, `opponent_board`, and `b2b_streak` all
## being valid on whatever board calls this.
func get_observation_vector() -> PackedFloat32Array:
	var obs := PackedFloat32Array()
	var piece_types = ["I", "J", "L", "O", "S", "T", "Z"]
	
	# 1. Grid Cells: Binary 0.0 or 1.0 (200 floats: idx 0..199)
	for y in range(engine.height):
		for x in range(engine.width):
			obs.append(1.0 if engine.grid[y][x] != -1 else 0.0)
			
	# 2. Board Metrics: Normalized [0.0 - 1.0] (3 floats: idx 200..202)
	var metrics: Dictionary = _get_board_metrics()
	obs.append(float(metrics["max_height"]) / 20.0)
	obs.append(float(metrics["holes"]) / 20.0)
	obs.append(float(metrics["bumpiness"]) / 40.0)

	# 3. Active Piece One-Hot Encoding (7 floats: idx 203..209)
	for p in piece_types:
		obs.append(1.0 if engine.active_piece_type == p else 0.0)

	# 4. Preview Queue One-Hot Encoding: 5 pieces x 7 types (35 floats: idx 210..244)
	for q_idx in range(5):
		var q_piece = engine.queue[q_idx] if q_idx < engine.queue.size() else ""
		for p in piece_types:
			obs.append(1.0 if q_piece == p else 0.0)

	# 5. Hold Piece One-Hot Encoding (7 floats: idx 245..251)
	for p in piece_types:
		obs.append(1.0 if engine.hold_piece_type == p else 0.0)

	# 6. Status Scalars (4 floats: idx 252..255)
	obs.append(1.0 if engine.can_hold else 0.0)
	obs.append(float(engine.get_pending_garbage_total()) / 20.0)
	obs.append(float(b2b_streak) / 10.0)
	obs.append(float(max(0, engine.combo_count)) / 10.0)

	# 7. Opponent Board & Combat State (157 floats: idx 256..412)
	if opponent_board != null and opponent_board.engine != null:
		# Opponent Grid bottom 14 rows: 14 x 10 (140 floats: idx 256..395)
		var opp_grid = opponent_board.engine.grid
		for y in range(6, 20):
			for x in range(10):
				obs.append(1.0 if (y < opp_grid.size() and opp_grid[y][x] != -1) else 0.0)
		
		# Opponent Metrics (4 floats: idx 396..399)
		var opp_metrics = opponent_board._get_board_metrics()
		obs.append(float(opp_metrics["max_height"]) / 20.0)
		obs.append(float(opp_metrics["holes"]) / 20.0)
		obs.append(float(opp_metrics["bumpiness"]) / 40.0)
		obs.append(float(opponent_board.engine.get_pending_garbage_total()) / 20.0)
		
		# Opponent Active Piece (7 floats: idx 400..406)
		for p in piece_types:
			obs.append(1.0 if opponent_board.engine.active_piece_type == p else 0.0)
		
		# Opponent B2B & KOs (2 floats: idx 407..408)
		obs.append(float(opponent_board.b2b_streak) / 10.0)
		obs.append(float(opponent_board.knockouts) / 10.0)

	# Pad any remaining slots up to exact total OBS_SIZE (413)
	while obs.size() < 413:
		obs.append(0.0)

	return obs

func _get_board_metrics() -> Dictionary:
	if engine == null:
		return {"holes": 0, "bumpiness": 0, "max_height": 0}

	var col_heights: Array[int] = []
	col_heights.resize(engine.width)
	col_heights.fill(0)
	var holes: int = 0

	for x in range(engine.width):
		var found_top: bool = false
		for y in range(engine.height):
			if engine.grid[y][x] != -1:
				if not found_top:
					col_heights[x] = engine.height - y
					found_top = true
			elif found_top:
				holes += 1

	var max_h: int = 0
	for h in col_heights:
		if h > max_h:
			max_h = h

	var bumpiness: int = 0
	for x in range(engine.width - 1):
		bumpiness += abs(col_heights[x] - col_heights[x + 1])

	return {
		"holes": holes,
		"bumpiness": bumpiness,
		"max_height": max_h,
		"col_heights": col_heights
	}

## action_idx (0-79) -> {target_rot, target_x, use_hold}. See
## encode_action() for the inverse, used by the human-play recorder.
func decode_action(action_idx: int) -> Dictionary:
	var use_hold: bool = action_idx >= 40
	var local_idx: int = action_idx % 40
	var target_x: int = local_idx % 10
	var target_rot: int = int(local_idx / 10)

	return {
		"target_x": target_x,
		"target_rot": target_rot,
		"use_hold": use_hold
	}

## Inverse of decode_action() — turns a final placement (the rotation
## state and x position a piece actually locked at, plus whether hold
## was used to get there) back into the same 0-79 action_idx scheme.
## This is what lets recorded human placements train against the exact
## action space the AI bots decode against.
func encode_action(target_rot: int, target_x: int, use_hold: bool) -> int:
	var local_idx: int = target_rot * 10 + target_x
	return local_idx + (40 if use_hold else 0)

func start_sequence():
	if skipcountdown:
		start()
		return
		
	await get_tree().create_timer(1).timeout
	tick.text = "3"
	Audio.play_sound("tick_3")
	anim.play("popup")
	await get_tree().create_timer(1).timeout
	tick.text = "2"
	Audio.play_sound("tick_2")
	anim.play("popup")
	
	await get_tree().create_timer(1).timeout
	tick.text = "1"
	Audio.play_sound("tick_1")
	anim.play("popup")
	
	await get_tree().create_timer(1).timeout
	tick.text = "go!"
	Audio.play_sound("tick_go")
	anim.play("popup")
	
	await get_tree().create_timer(1.5).timeout
	tick.text = ""
	start()
	

func start():
	_initialize_engine()

func get_rand_id():
	randomize()
	player_id = randi()
	var message:String = ""
	if self is MultiplayerBoard:
		message += "Multiplayer board ID: "
	elif self is CloobBotBoard:
		message += "Bot Board ID: "
	print(message, " ", player_id)

func _setup_board_scale() -> void:
	if placed_tiles_layer == null or board_pivot == null: return
	var base_tile_size: float = placed_tiles_layer.tile_set.tile_size.x
	var dynamic_scale: float = TARGET_TILE_SIZE / base_tile_size
	board_pivot.scale = Vector2(dynamic_scale, dynamic_scale)
	
	if bg != null:
		bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
		if bg.get_parent() == board_pivot:
			bg.size = Vector2(BOARD_SIZE.x * base_tile_size, BOARD_SIZE.y * base_tile_size)
			bg.position = Vector2(GRID_OFFSET.x * base_tile_size, GRID_OFFSET.y * base_tile_size)
		else:
			bg.size = Vector2(BOARD_SIZE.x * TARGET_TILE_SIZE, BOARD_SIZE.y * TARGET_TILE_SIZE)
			bg.position = board_pivot.position + Vector2(GRID_OFFSET.x * TARGET_TILE_SIZE, GRID_OFFSET.y * TARGET_TILE_SIZE)
		bg.show_behind_parent = true

func _initialize_engine() -> void:
	engine = TetrisEngine.new(BOARD_SIZE.x, BOARD_SIZE.y, PREVIEW_COUNT)
	engine.instant_garbage = instant_garbage
	#print(player_id)
	engine.player_id = int(player_id)
	
	pieces_controller = PiecesController.new()
	add_child(pieces_controller)
	engine.pieces_controller = pieces_controller
	
	var json_data = pieces_controller.get_piece_forms()
	engine.load_piece_definitions(json_data)
	
	if hold_slot.tile_texture == null and queue_display.tile_texture != null:
		hold_slot.tile_texture = queue_display.tile_texture
	
	engine.board_updated.connect(_on_board_updated)
	engine.active_piece_moved.connect(_on_active_piece_moved)
	engine.lines_cleared.connect(_on_lines_cleared)
	engine.garbage_sent.connect(_on_garbage_sent)
	engine.garbage_applied.connect(_on_garbage_applied)
	engine.garbage_received.connect(func(_pending_total: int): _update_garbage_display())
	engine.garbage_applied.connect(func(_rows_added: int): _update_garbage_display())
	engine.game_over.connect(_on_topout)
	
	if is_battle and not EventBus.send_garbage.is_connected(_on_network_garbage_received):
		EventBus.send_garbage.connect(_on_network_garbage_received)
		print("[GARBAGE][BOARD ", player_id, "] listening for incoming garbage (is_battle=true, target_id=", target_id, ")")
	elif not is_battle:
		print("[GARBAGE][BOARD ", player_id, "] is_battle is FALSE - this board will never send or receive garbage")
	
	queue_display.setup_slots()
	
	engine.queue_changed.connect(func(next_pieces: Array[String]):
		queue_display.update_display(
			next_pieces, 
			pieces_controller.get_piece_forms(), 
			engine.piece_indices
		)
	)
	
	engine.hold_changed.connect(func(piece_key: String):
		var ascii_grid = pieces_controller.get_piece_forms().get(piece_key, [])
		var tile_idx = engine.piece_indices.get(piece_key, 0)
		hold_slot.render_ascii_piece(ascii_grid, tile_idx)
		Audio.play_sound("hold")
	)
	
	engine.hard_dropped.connect(func(): Audio.play_sound("hard_drop"))
	
	engine.start_game()
	_update_garbage_display()

# --- View Rendering Callbacks ---

func _on_board_updated(grid_matrix: Array) -> void:
	placed_tiles_layer.clear()
	
	# 1. Render visible grid (y >= 0)
	for y in range(grid_matrix.size()):
		for x in range(grid_matrix[y].size()):
			var cell_type = grid_matrix[y][x]
			if cell_type != -1:
				placed_tiles_layer.set_cell(Vector2i(x, y) + GRID_OFFSET, 0, Vector2i(cell_type, 0))

	# 2. Render buffer grid (y < 0)
	if engine != null:
		var buffer_grid = engine.get_buffer_grid()
		var buf_size = buffer_grid.size()
		for buf_idx in range(buf_size):
			var y = buf_idx - buf_size # Maps indices 0..19 to -20..-1
			for x in range(buffer_grid[buf_idx].size()):
				var cell_type = buffer_grid[buf_idx][x]
				if cell_type != -1:
					placed_tiles_layer.set_cell(Vector2i(x, y) + GRID_OFFSET, 0, Vector2i(cell_type, 0))

func _on_active_piece_moved(piece_cells: Array[Vector2i], piece_type: int) -> void:
	active_piece_layer.clear()
	ghost_piece_layer.clear()
	
	for cell in piece_cells:
		active_piece_layer.set_cell(cell + GRID_OFFSET, 0, Vector2i(piece_type, 0))
		
	var ghost_origin = engine.get_ghost_position()
	for offset in engine.active_offsets:
		var cell = ghost_origin + offset
		if cell.y >= -engine.BUFFER_HEIGHT: # Allow ghost cells in the buffer zone to render
			ghost_piece_layer.set_cell(cell + GRID_OFFSET, 0, Vector2i(piece_type, 0))

func _on_lines_cleared(line_count: int, combo_count: int, is_tspin:bool) -> void:
	EventBus.lines_cleared.emit(line_count, combo_count)
	Audio.play_sound("clear"+str(line_count) if line_count < 5 else "clear4")
	if combo_count > 0:
		Audio.play_sound("combo"+str(combo_count) if combo_count < 7 else "combo7")
	if line_count == 4:
		b2b_streak += 1
	elif is_tspin:
		b2b_streak += 1
	elif line_count > 0:
		b2b_streak = 0
	_update_clear_message(line_count, combo_count, is_tspin)

func _update_clear_message(line_count:int, combo_count:int, is_tspin:bool):
	var combo_message = str(combo_count) + " Combo" if combo_count > 0 else ""
	var spin_message = "t-spin" if is_tspin else ""
	var b2b_message = "back-to-back" if b2b_streak>1 else ""
	var clear_message:String
	match line_count:
		1: clear_message = "single"
		2: clear_message = "double"
		3: clear_message = "triple"
		4: clear_message = "quad"
	
	b2b_label.text = b2b_message
	spin_label.text = spin_message
	clear_label.text = clear_message
	combo_label.text = combo_message
	
func _update_knockouts():
	kos_label.text = str(knockouts) + " KOs" if knockouts > 0 else ""

func _on_garbage_sent(chunks: Array) -> void:
	print("[GARBAGE][BOARD ", player_id, "] engine wants to send ", chunks, " to ", target_id, " | is_battle=", is_battle)
	if not is_battle or target_id < 0:
		print("[GARBAGE][BOARD ", player_id, "] DROPPED - is_battle is false or target_id < 0, nothing will be sent")
		return
	_send_garbage_delayed(chunks)

func _send_garbage_delayed(chunks: Array) -> void:
	await get_tree().create_timer(0.5).timeout
	print("[GARBAGE][BOARD ", player_id, "] 0.5s delay elapsed, broadcasting ", chunks, " -> target ", target_id)
	EventBus.send_garbage.emit(chunks, player_id, target_id)

func _on_network_garbage_received(chunks: Array, sender_id: int, receiver_id: int) -> void:
	print("[GARBAGE][BOARD ", player_id, "] heard EventBus.send_garbage(", chunks, ", sender=", sender_id, ", receiver=", receiver_id, ")")
	if receiver_id != player_id or engine == null:
		return
		
	print("[GARBAGE][BOARD ", player_id, "] this attack is mine, queuing into engine")
	
	# Update last_attacker and tag each chunk with the attacker's ID
	last_attacker = sender_id
	for chunk in chunks:
		chunk["attacker_id"] = sender_id
		
	engine.queue_garbage(chunks)

func _on_garbage_applied(rows_added: int) -> void:
	if rows_added <= 0 or placed_tiles_layer == null:
		return
		
func receive_garbage(chunks: Array, attacker_id: int) -> void:
	last_attacker = attacker_id
	
	# Pass the attacker ID into each garbage chunk for engine tracking
	for chunk in chunks:
		chunk["attacker_id"] = attacker_id
		
	if engine != null:
		engine.queue_garbage(chunks)
## True once this board's engine has topped out. The engine itself is the
## actual enforcement point (every mutating call - move/rotate/hold/drop/lock
## delay/garbage draining - checks this and no-ops), so any child that reads
## input or plans moves (PiecesController, a bot board, network-applied
## moves) automatically stops affecting the game the instant this flips true.
## This getter is just for UI/other systems that want to know the state too
## (e.g. showing a "topped out" banner) without reaching into engine directly.
func is_topped_out() -> bool:
	return engine != null and engine.is_topped_out

func _on_topout() -> void:
	print("[TOPOUT][BOARD %d] topped out - board frozen until reset() is called" % player_id)
	Audio.play_sound("KO")
	tick.text = "KO!"
	active_piece_layer.clear()
	ghost_piece_layer.clear()
	board_topped_out.emit()

## Fully resets this board back to a fresh game state after a topout (or any
## time a clean restart is wanted). engine.start_game() wipes the grid, queue,
## hold, and pending garbage AND clears engine.is_topped_out - that flag is
## what's been silently blocking every mutating engine call, so clearing it
## is what actually lets input/bot/network control the board again. Board-
## side visuals (meter, b2b streak) are reset here to match, since the engine
## has no notion of those.
func reset() -> void:
	if engine == null:
		return
	
	b2b_streak = 0
	engine.start_game()
	
	_target_meter_height = 0
	if _meter_stylebox != null:
		_meter_stylebox.border_width_bottom = 0
	_update_garbage_display()
	tick.text = ""
	board_reset.emit()
	hold_slot.clear()

func _update_garbage_display() -> void:
	if engine == null or meter == null:
		return

	var total_garbage: int = engine.get_pending_garbage_total()

	if total_garbage > GARBAGE_METER_MAX_LINES:
		# TODO: will add another meter soon here in a different color to show
		# the overflow beyond GARBAGE_METER_MAX_LINES.
		total_garbage = GARBAGE_METER_MAX_LINES

	if _meter_stylebox == null:
		var base_stylebox: StyleBox = meter.get_theme_stylebox("panel")
		_meter_stylebox = base_stylebox.duplicate() as StyleBoxFlat if base_stylebox is StyleBoxFlat else StyleBoxFlat.new()
		meter.add_theme_stylebox_override("panel", _meter_stylebox) 

	var fill_ratio: float = float(total_garbage) / float(GARBAGE_METER_MAX_LINES)
	#_meter_stylebox.border_width_bottom = int(meter.size.y * fill_ratio)
	_target_meter_height = int(meter.size.y * fill_ratio)
