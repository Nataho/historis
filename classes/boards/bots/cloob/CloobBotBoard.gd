class_name CloobBotBoard extends Board

enum Action { ROTATE_CW, ROTATE_CCW, MOVE_X, DROP_Y, HARD_DROP, LOCK }
@onready var dependency_layer: TileMapLayer = %Dependency

@export var auto_play: bool = true
@export var debug: bool = true

@export_group("Humanized Speed & PPS")
@export_range(0.5, 15.0, 0.1) var target_pps: float = 2.5
@export_range(0.0, 0.5, 0.01) var pps_jitter: float = 0.15

@export_group("AI Settings")
@export_range(1, 4) var lookahead_depth: int = 2
@export_range(1, 10) var beam_width: int = 5

@export_group("Handling Controls")
@export var use_hard_drop: bool = true
@export var das_ms: float = 60.0
@export var arr_ms: float = 0.0
@export var sdf_ms: float = 20.0

@export_group("Visualization")
@export var preview_source_id: int = 0
@export var preview_atlas_coords: Vector2i = Vector2i(11, 0)

var bot := TetrisBot.new()

var target_move: Dictionary = {}
var has_target: bool = false
var action_queue: Array[Dictionary] = []

# --- PONDERING (BACKGROUND LOOKAHEAD) ---
# While the current piece's instruction queue is being executed (which takes
# real wall-clock time thanks to the humanized PPS/DAS/ARR pacing), a
# background thread searches for the move for the piece that will spawn
# next. TetrisBot itself holds no mutable state, so it's safe to call from
# another thread as long as it's only ever given a private, cloned
# TetrisEngine snapshot -- never the live `engine` the main thread is
# simultaneously mutating via move_piece()/rotate_piece().
var think_thread: Thread = null
var think_mutex: Mutex = Mutex.new()
var think_active: bool = false
var think_ready: bool = false
var think_discard: bool = false
var think_result: Dictionary = {}

# The precomputed move, plus the exact state it assumed, so it can be
# validated against reality before being trusted (garbage coming in,
# a mid-path replan, etc. can all invalidate the assumption).
var pending_next_plan: Dictionary = {}
var pending_assumed_piece_type: String = ""
var pending_assumed_hold_type: String = ""
var pending_assumed_grid: Array = []

var move_dir: int = 0
var das_timer: float = 0.0
var arr_timer: float = 0.0
var sdf_timer: float = 0.0
var pps_delay_timer: float = 0.0

func _ready() -> void:
	super._ready()
	# Board._ready() only calls _initialize_engine() itself when autostart is
	# true (via start_sequence()); otherwise it just waits for something to
	# call start(). The bot board has always started immediately on its own,
	# so replicate that here -- unless autostart was explicitly turned on for
	# this board, in which case let the normal countdown flow own it instead
	# of double-initializing.
	if not autostart:
		start()

	await get_tree().create_timer(1.0).timeout
	
	if engine != null:
		# Create a 2-tile high overhang at column 4, rows 16 & 17
		engine.grid[16][4] = 8
		engine.grid[17][4] = 8
		
		# Leave Column 3 completely open as the drop shaft down to Row 18
		_on_board_updated(engine.grid)

func _process(delta: float) -> void:
	# Board._process() ticks the gradual-garbage drain (engine.process_garbage).
	# Overriding _process() here shadows that entirely unless we call it
	# ourselves, so garbage sent to a bot board would queue up but never
	# actually rise into its grid. Call it unconditionally, same as the base
	# class does, regardless of auto_play/engine state below.
	super._process(delta)

	if engine == null or not auto_play: return
	if engine.active_piece_type == "" or engine.active_piece_type == null: return

	if pps_delay_timer > 0.0:
		pps_delay_timer -= delta
		return

	var delta_ms: float = delta * 1000.0

	if engine.is_grounded():
		engine.process_lock_delay(delta_ms)

	_poll_pondering()

	# 1. Fetch Move & Build Instruction Queue
	if not has_target:
		if _pending_plan_matches_current_state():
			target_move = pending_next_plan
		else:
			target_move = bot.find_best_move(engine, lookahead_depth, beam_width)
		pending_next_plan = {}
		if target_move.is_empty(): return

		has_target = true
		if target_move.get("use_hold", false):
			engine.hold_active_piece()
			target_move = bot.find_best_move(engine, lookahead_depth, beam_width)

		_build_instruction_queue()
		_draw_target_preview()
		_start_pondering()

	# 2. Execute Queue Frame-by-Frame
	if action_queue.is_empty():
		_finish_move("Instruction queue completed")
		return

	var current_action: Dictionary = action_queue[0]
	var action_done: bool = false

	match current_action["type"]:
		Action.ROTATE_CW:
			var kick_table = engine.pieces_controller.get_kick_table(engine.active_piece_type)
			if not engine.rotate_piece(true, kick_table):
				# The plan assumed this rotation would succeed (and land at a
				# specific kicked position) but the engine couldn't fit it.
				# Continuing would move/drop the WRONG shape toward
				# coordinates that were only valid for the rotated piece.
				# Replan from where we actually are instead of faking success.
				_replan("Rotation (CW) failed mid-path")
				return
			action_done = true

		Action.ROTATE_CCW:
			var kick_table = engine.pieces_controller.get_kick_table(engine.active_piece_type)
			if not engine.rotate_piece(false, kick_table):
				_replan("Rotation (CCW) failed mid-path")
				return
			action_done = true

		Action.MOVE_X:
			var target_x: int = current_action["target"]
			action_done = _handle_horizontal_movement(delta_ms, target_x)
			if action_done and engine.active_pos.x != target_x:
				# _handle_horizontal_movement gives up and reports "done" as
				# soon as a move is blocked, even if it never reached
				# target_x. That used to be silently accepted as success,
				# leaving the piece short of the planned column. Treat it as
				# a desync and replan instead.
				_replan("Horizontal movement blocked before reaching target_x=%d" % target_x)
				return

		Action.DROP_Y:
			var target_y: int = current_action["target"]
			action_done = _handle_soft_drop(delta_ms, target_y)
			if action_done and engine.active_pos.y != target_y:
				# Same issue as above but for soft drop: landing on the
				# stack early used to be reported as "done" even though the
				# piece never reached target_y. This is the exact failure
				# mode reported ("can't soft drop to the desired
				# destination") -- catch it here and replan.
				_replan("Soft drop blocked before reaching target_y=%d" % target_y)
				return

		Action.HARD_DROP:
			engine.hard_drop()
			action_done = true
			_finish_move("Hard Drop Executed")
			return

		Action.LOCK:
			engine.lock_piece()
			action_done = true
			_finish_move("Piece Locked")
			return

	if action_done:
		action_queue.pop_front()
		move_dir = 0
		das_timer = 0.0
		arr_timer = 0.0
		sdf_timer = 0.0


func _handle_horizontal_movement(delta_ms: float, target_x: int) -> bool:
	var current_x = engine.active_pos.x
	if current_x == target_x:
		return true

	var req_dir = 1 if target_x > current_x else -1

	# Instant DAS/ARR override
	if das_ms <= 0.0:
		while engine.active_pos.x != target_x:
			if not engine.move_piece(Vector2i(req_dir, 0)): break
		return true

	# Initial Tap & Direction Change
	if move_dir != req_dir:
		move_dir = req_dir
		das_timer = 0.0
		arr_timer = 0.0
		if not engine.move_piece(Vector2i(move_dir, 0)):
			return true # Blocked horizontally
		return engine.active_pos.x == target_x

	# DAS Charge Phase
	das_timer += delta_ms
	if das_timer >= das_ms:
		if arr_ms <= 0.0: # Instant ARR
			while engine.active_pos.x != target_x:
				if not engine.move_piece(Vector2i(req_dir, 0)): break
			return true
		else: # Timed ARR
			arr_timer += delta_ms
			while arr_timer >= arr_ms and engine.active_pos.x != target_x:
				if not engine.move_piece(Vector2i(req_dir, 0)):
					return true # Blocked during ARR
				arr_timer -= arr_ms

	return engine.active_pos.x == target_x


func _handle_soft_drop(delta_ms: float, target_y: int) -> bool:
	if engine.active_pos.y >= target_y:
		return true

	# Instant Soft Drop override
	if sdf_ms <= 0.0:
		while engine.active_pos.y < target_y:
			if not engine.move_piece(Vector2i(0, 1)): break
		return true

	# Timed Soft Drop
	sdf_timer += delta_ms
	while sdf_timer >= sdf_ms and engine.active_pos.y < target_y:
		sdf_timer -= sdf_ms
		if not engine.move_piece(Vector2i(0, 1)):
			return true # Piece landed on stack early

	return engine.active_pos.y >= target_y

func _action_type_to_string(type: Action) -> String:
	match type:
		Action.ROTATE_CW: return "ROTATE_CW"
		Action.ROTATE_CCW: return "ROTATE_CCW"
		Action.MOVE_X: return "MOVE_X"
		Action.DROP_Y: return "DROP_Y"
		Action.HARD_DROP: return "HARD_DROP"
		Action.LOCK: return "LOCK"
	return "UNKNOWN"



func _build_instruction_queue() -> void:
	action_queue.clear()

	var path: Array = target_move.get("path", [])
	if path.is_empty():
		return

	var curr_rot: int = engine.rotation_state
	var curr_x: int = engine.active_pos.x
	var curr_y: int = engine.active_pos.y

	# Walk the raw BFS path and convert state transitions into input commands
	for node: Vector3i in path:
		var target_x: int = node.x
		var target_y: int = node.y
		var target_rot: int = node.z

		# 1. Rotate (only when the path explicitly requires a rotation step)
		if curr_rot != target_rot:
			_queue_rotation(curr_rot, target_rot)
			curr_rot = target_rot

		# 2. Horizontal Movement (Merge consecutive X steps into one target)
		if curr_x != target_x:
			if not action_queue.is_empty() and action_queue[-1]["type"] == Action.MOVE_X:
				action_queue[-1]["target"] = target_x
			else:
				action_queue.append({"type": Action.MOVE_X, "target": target_x})
			curr_x = target_x

		# 3. Soft Drop (Merge consecutive Y steps into one target)
		if curr_y != target_y:
			if not action_queue.is_empty() and action_queue[-1]["type"] == Action.DROP_Y:
				action_queue[-1]["target"] = target_y
			else:
				action_queue.append({"type": Action.DROP_Y, "target": target_y})
			curr_y = target_y

	# 4. Final Lock / Drop
	var req_soft_drop: bool = target_move.get("requires_soft_drop", false)
	if use_hard_drop and not req_soft_drop:
		action_queue.append({"type": Action.HARD_DROP})
	else:
		action_queue.append({"type": Action.LOCK})

	_print_action_queue()

func _queue_rotation(from_rot: int, to_rot: int) -> void:
	if engine.active_piece_type == "O" or from_rot == to_rot:
		return
	var r = from_rot
	while r != to_rot:
		var diff: int = posmod(to_rot - r, 4)
		if diff == 1 or diff == 2:
			action_queue.append({"type": Action.ROTATE_CW})
			r = posmod(r + 1, 4)
		else:
			action_queue.append({"type": Action.ROTATE_CCW})
			r = posmod(r - 1, 4)

func _print_action_queue() -> void:
	if not debug: return
	var formatted: Array[String] = []
	for act in action_queue:
		match act["type"]:
			Action.ROTATE_CW: formatted.append("ROTATE_CW")
			Action.ROTATE_CCW: formatted.append("ROTATE_CCW")
			Action.MOVE_X: formatted.append("MOVE_X(target_x=%d)" % act["target"])
			Action.DROP_Y: formatted.append("DROP_Y(target_y=%d)" % act["target"])
			Action.HARD_DROP: formatted.append("HARD_DROP")
			Action.LOCK: formatted.append("LOCK")
	
	print("[BOT QUEUE] ", " -> ".join(formatted))

func _draw_target_preview() -> void:
	if not is_instance_valid(dependency_layer): return
	dependency_layer.clear()

	if target_move.is_empty(): return

	var target_x: int = target_move.get("x", engine.active_pos.x)
	var target_y: int = target_move.get("y", engine.active_pos.y)
	var target_rot: int = target_move.get("rot", 0)
	var piece_type: String = engine.active_piece_type
	#print("piece_type: ", piece_type)
	var offsets = engine.pieces_controller.get_state_offsets(piece_type, target_rot)
	for off: Vector2i in offsets:
		var cell: Vector2i = Vector2i(target_x, target_y) + off + GRID_OFFSET
		#if piece_type == "O":
			#cell + Vector2i(0,1)
			#print("it's O!")
		dependency_layer.set_cell(cell if piece_type != "O" else cell + Vector2i(0,-1), preview_source_id, preview_atlas_coords)

func _execute_soft_drop(delta_ms: float, target_y: int) -> void:
	if sdf_ms <= 0.0:
		while engine.active_pos.y < target_y:
			if not engine.move_piece(Vector2i.DOWN): break
	else:
		sdf_timer += delta_ms
		if sdf_timer >= sdf_ms:
			sdf_timer -= sdf_ms
			engine.move_piece(Vector2i.DOWN)

func _replan(reason: String) -> void:
	# Called whenever a queued action couldn't actually be carried out the
	# way the plan expected (rotation rejected by the kick table, or
	# horizontal/vertical movement blocked before reaching its target).
	# Rather than let execution silently drift away from the intended
	# placement, throw away the stale plan and let _process() call
	# bot.find_best_move() again next frame using the piece's real,
	# current position/rotation. This makes the bot self-correcting instead
	# of ending up stuck away from wherever the pathfinder originally aimed.
	if debug:
		print("[CloobBot] Plan desynced -> ", reason, " | Recomputing move...")

	has_target = false
	target_move = {}
	action_queue.clear()
	move_dir = 0
	das_timer = 0.0
	arr_timer = 0.0
	sdf_timer = 0.0

	# The board no longer matches whatever the pondering thread assumed it
	# would be, so any cached/in-flight prediction is now worthless. If a
	# thread is still running we can't kill it, so just mark it to be
	# dropped once it finishes instead of applied.
	pending_next_plan = {}
	if think_active:
		think_discard = true

func _exit_tree() -> void:
	# A Thread must be joined before it (or the node holding it) goes away,
	# or Godot complains about a leaked/still-running thread.
	if think_thread != null:
		think_thread.wait_to_finish()
		think_thread = null

func _poll_pondering() -> void:
	if not think_active: return

	think_mutex.lock()
	var is_ready: bool = think_ready
	var result: Dictionary = think_result
	think_mutex.unlock()

	if not is_ready: return

	think_thread.wait_to_finish()
	think_thread = null
	think_active = false

	if think_discard or result.is_empty():
		pending_next_plan = {}
	else:
		pending_next_plan = result

	think_discard = false
	think_result = {}
	think_ready = false

func _pending_plan_matches_current_state() -> bool:
	if pending_next_plan.is_empty(): return false
	if engine == null: return false
	if engine.active_piece_type != pending_assumed_piece_type: return false
	if engine.hold_piece_type != pending_assumed_hold_type: return false
	if engine.rotation_state != 0: return false
	if not engine.can_hold: return false
	# Deep-compares row by row -- Godot's Array `==` recurses into nested
	# Arrays, so this is a real content comparison, not a reference check.
	if engine.grid != pending_assumed_grid: return false
	return true

func _start_pondering() -> void:
	if think_active: return
	if engine == null: return
	if target_move.is_empty(): return
	if engine.queue.is_empty(): return

	var result_grid: Array = target_move.get("result_grid", [])
	if result_grid.is_empty(): return

	var next_piece_type: String = engine.queue[0]
	var future_queue: Array[String] = []
	for i in range(1, engine.queue.size()):
		future_queue.append(engine.queue[i])
	var future_hold: String = engine.hold_piece_type

	var offsets: Array[Vector2i] = engine.pieces_controller.get_state_offsets(next_piece_type, 0)
	if offsets.is_empty(): return

	pending_assumed_piece_type = next_piece_type
	pending_assumed_hold_type = future_hold
	pending_assumed_grid = []
	for row in result_grid:
		pending_assumed_grid.append((row as Array).duplicate())

	var spawn_pos := Vector2i(engine.width / 2 - 1, 1)
	var snapshot: TetrisEngine = engine.duplicate_snapshot()
	# duplicate_snapshot() mirrors the engine's state *right now* -- the
	# piece that's still mid-flight. We want a snapshot of the state right
	# after that piece locks instead, so overwrite exactly the fields that
	# change at that moment: the resulting grid, the piece that spawns
	# next, its default spawn pos/rotation, and the queue/hold minus that
	# piece. pieces_controller/loaded_shapes/piece_indices came along for
	# free from duplicate_snapshot() and don't need touching.
	snapshot.grid.clear()
	for row in result_grid:
		snapshot.grid.append((row as Array).duplicate())
	snapshot.active_piece_type = next_piece_type
	snapshot.active_piece_index = engine.piece_indices.get(next_piece_type, 0)
	snapshot.active_offsets = offsets.duplicate()
	snapshot.active_pos = spawn_pos
	snapshot.rotation_state = 0
	snapshot.last_move_was_rotate = false
	snapshot.queue = future_queue.duplicate()
	snapshot.hold_piece_type = future_hold
	# Hold always resets to available the instant a piece locks and the
	# next one spawns, regardless of whether it was used this turn.
	snapshot.can_hold = true

	think_active = true
	think_ready = false
	think_discard = false
	var depth_copy: int = lookahead_depth
	var beam_copy: int = beam_width

	think_thread = Thread.new()
	think_thread.start(_thread_worker.bind(snapshot, depth_copy, beam_copy))

func _thread_worker(snapshot: TetrisEngine, depth: int, beam: int) -> void:
	# Runs on the background thread. `snapshot` is a private TetrisEngine
	# clone that nothing else touches, and `bot` carries no mutable state
	# of its own, so this is safe to run concurrently with the main
	# thread's real-time execution of the current piece.
	var result: Dictionary = bot.find_best_move(snapshot, depth, beam)

	think_mutex.lock()
	think_result = result
	think_ready = true
	think_mutex.unlock()

func _finish_move(reason: String = "") -> void:
	if debug and not reason.is_empty():
		print("[CloobBot] Placement complete -> ", reason)

	# DO NOT clear dependency_layer here; keep target visible until the next move is calculated!

	has_target = false
	action_queue.clear()
	move_dir = 0
	das_timer = 0.0
	arr_timer = 0.0
	sdf_timer = 0.0
	
	if target_pps > 0.0:
		var base_delay = 1.0 / target_pps
		var is_complex: bool = target_move.get("is_complex", false)
		var complexity_factor = 1.35 if is_complex else 0.90
		var jitter = randf_range(-pps_jitter, pps_jitter) * base_delay
		pps_delay_timer = max(0.02, (base_delay * complexity_factor) + jitter)
