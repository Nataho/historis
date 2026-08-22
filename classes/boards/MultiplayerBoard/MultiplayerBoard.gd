class_name MultiplayerBoard extends Board

# Inherits signal knocked_out(victim_id: int) and signal board_topped_out from Board

# --- HARDCODED HANDLING SETTINGS (in milliseconds) ---
@export var DAS_MS: float = 167.0
@export var ARR_MS: float = 33.0
@export var SDF_MS: float = 100.0
@export var DCD_MS: float = 50.0

@export var is_local_player: bool = true
var player_ready: bool = false

# --- HUMAN PLAY RECORDING (for behavior-cloning pretraining) ---
# Off by default on purpose — recording writes a file every time a piece
# locks, so this should only ever be true on a board you deliberately
# turned it on for, never as an ambient default.
@export_group("Recording")
@export var record_player: bool = false
# Where session .bin files get written. Must end up pointing at the same
# `demos/` folder train_bc.py reads from — that script currently resolves
# it relative to wherever you run `python train_bc.py` from, so this will
# likely need to be an absolute path rather than the user:// default below
# once your Godot project and Python scripts don't share a working directory.
@export var demo_output_dir: String = "user://demos/"

# Recorder internal state
var _record_file: FileAccess = null
var _pending_obs: PackedFloat32Array = PackedFloat32Array()
var _pending_used_hold: bool = false
var _has_prior_turn: bool = false          # false only before the session's first placement
var _expect_midturn_hold_spawn: bool = false
var _last_committed_rot: int = 0
var _last_committed_x: int = 0

# Timers
var drop_timer: float = 0.0
var das_timer: float = 0.0
var arr_timer: float = 0.0
var soft_drop_timer: float = 0.0

# Input States
var move_dir: int = 0
var is_soft_dropping: bool = false

func _initialize_engine() -> void:
	super._initialize_engine()
	if record_player:
		_start_recording_session()
		if not engine.queue_changed.is_connected(_on_recorder_turn_boundary):
			engine.queue_changed.connect(_on_recorder_turn_boundary)
		if not engine.active_piece_moved.is_connected(_on_recorder_piece_moved):
			engine.active_piece_moved.connect(_on_recorder_piece_moved)
		if not engine.hold_changed.is_connected(_on_recorder_hold_used):
			engine.hold_changed.connect(_on_recorder_hold_used)
		if not engine.game_over.is_connected(_on_recorder_game_over):
			engine.game_over.connect(_on_recorder_game_over)

func _exit_tree() -> void:
	# Every completed placement is already flushed to disk as it's
	# recorded, so this is just tidiness, not a durability requirement —
	# a crash or force-quit mid-game loses nothing already written.
	if _record_file != null:
		_record_file.close()
		_record_file = null

# --- Human play recording -------------------------------------------
# Mirrors what the AI bots do: sample the observation once at the start
# of a piece's turn (before any movement), then encode wherever it
# actually ends up locking (final rotation, final x, whether hold was
# used) into the same action_idx scheme decode_action() reads.
#
# The tricky part: a lock (however triggered — hard drop, soft-drop-to-
# bottom, or the lock-delay timer just expiring) calls spawn_piece(),
# which immediately resets active_pos/rotation_state for the NEW piece
# before this script gets a chance to read them. So the just-locked
# piece's final rotation/x is tracked continuously via every
# active_piece_moved signal throughout its lifetime — its last firing
# before lock IS its final resting spot — and read from that cache, not
# live from the engine, when finalizing a sample. Verified against
# TetrisEngine.gd: spawn_piece() emits queue_changed BEFORE resetting
# active_pos further and firing its own active_piece_moved, so the
# cache is still correct at exactly the moment this reads it.

func _start_recording_session() -> void:
	if _record_file != null:
		_record_file.close()
		_record_file = null
	DirAccess.make_dir_recursive_absolute(demo_output_dir)
	var timestamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = demo_output_dir.path_join("session_%s_p%d_%d.bin" % [timestamp, player_id, randi() % 100000])
	_record_file = FileAccess.open(path, FileAccess.WRITE)
	if _record_file == null:
		push_warning("[RECORD] Could not open '%s' for writing (error %s) — recording disabled for this session." % [path, FileAccess.get_open_error()])
	else:
		print("[RECORD][BOARD %d] Recording human play to: %s" % [player_id, path])
	_has_prior_turn = false

func _on_recorder_piece_moved(_piece_cells: Array[Vector2i], _piece_type: int) -> void:
	_last_committed_rot = engine.rotation_state
	_last_committed_x = engine.active_pos.x

func _on_recorder_hold_used(_piece_key: String) -> void:
	_pending_used_hold = true

func _on_recorder_turn_boundary(_next_pieces: Array[String]) -> void:
	if _expect_midturn_hold_spawn:
		# Holding from an empty hold slot also calls spawn_piece() (and
		# therefore fires this same signal) mid-turn, with nothing having
		# locked. Consume the flag and skip — the real turn is still in
		# progress, its obs snapshot already captured.
		_expect_midturn_hold_spawn = false
		return

	if _record_file != null and _has_prior_turn:
		var action_idx: int = encode_action(_last_committed_rot, _last_committed_x, _pending_used_hold)
		_write_demo_sample(_pending_obs, action_idx)

	_pending_obs = get_observation_vector()
	_pending_used_hold = false
	_has_prior_turn = true

func _on_recorder_game_over() -> void:
	# Whatever placement was mid-flight topped out instead of locking —
	# don't write a sample for it.
	_has_prior_turn = false

func _write_demo_sample(obs: PackedFloat32Array, action_idx: int) -> void:
	for v in obs:
		_record_file.store_float(v)
	_record_file.store_32(action_idx)
	_record_file.flush()

func _process(delta: float) -> void:
	# Let the parent Board handle the garbage ticks and meter animations automatically!
	super._process(delta)

	# The base board handled the visuals, now early-return if we shouldn't process local physics
	if engine == null or not is_local_player: return
	
	var delta_ms: float = delta * 1000.0
	
	# 1. Update ground lock delay timer
	engine.process_lock_delay(delta_ms)

	# 2. Soft Drop Handling (SDF) - Primary Tick
	if is_soft_dropping:
		drop_timer = 0.0
		if SDF_MS <= 0.0:
			while engine.move_piece(Vector2i.DOWN):
				pass
		else:
			soft_drop_timer += delta_ms
			while soft_drop_timer >= SDF_MS:
				engine.soft_drop()
				soft_drop_timer -= SDF_MS
	else:
		drop_timer += delta
		if drop_timer >= drop_interval:
			drop_timer = 0.0
			engine.soft_drop()

	# 3. Horizontal Movement Handling (DAS / ARR) with Interleaved Soft Drop
	if move_dir != 0:
		das_timer += delta_ms
		if das_timer >= DAS_MS:
			if ARR_MS <= 0.0:
				while _step_horizontal_with_drop_priority(move_dir):
					pass
			else:
				arr_timer += delta_ms
				while arr_timer >= ARR_MS:
					_step_horizontal_with_drop_priority(move_dir)
					arr_timer -= ARR_MS

func _step_horizontal_with_drop_priority(dir: int) -> bool:
	if is_soft_dropping:
		engine.move_piece(Vector2i.DOWN)

	var moved: bool = engine.move_piece(Vector2i(dir, 0))

	if moved and is_soft_dropping:
		engine.move_piece(Vector2i.DOWN)

	return moved

func _input(event: InputEvent) -> void:
	if engine == null or not is_local_player: return

	# Single-Tap Actions
	if event.is_action_pressed("rotate_cw"):
		engine.rotate_piece(true, pieces_controller.get_kick_table(engine.active_piece_type))
	elif event.is_action_pressed("rotate_ccw"):
		engine.rotate_piece(false, pieces_controller.get_kick_table(engine.active_piece_type))
	elif event.is_action_pressed("rotate_180"):
		engine.rotate_180(pieces_controller.get_180_kick_table(engine.active_piece_type))
	elif event.is_action_pressed("hard_drop") or event.is_action_pressed("ui_accept"):
		engine.hard_drop()
		soft_drop_timer = 0.0
	elif event.is_action_pressed("hold_piece"):
		if record_player and engine.can_hold and engine.hold_piece_type.is_empty():
			# This specific case is the only one where hold_active_piece()
			# calls spawn_piece() (first hold of the piece cycle, nothing
			# in the hold slot yet) — flagged so the recorder's turn-
			# boundary handler knows not to treat it as a real lock.
			_expect_midturn_hold_spawn = true
		engine.hold_active_piece()
		_apply_dcd()

	# Pressing Horizontal Direction (Last-Input Priority)
	if event.is_action_pressed("move_left") or event.is_action_pressed("ui_left"):
		_start_horizontal_move(-1)
	elif event.is_action_pressed("move_right") or event.is_action_pressed("ui_right"):
		_start_horizontal_move(1)

	# Releasing Horizontal Direction
	if event.is_action_released("move_left") or event.is_action_released("ui_left"):
		_stop_horizontal_move(-1)
	elif event.is_action_released("move_right") or event.is_action_released("ui_right"):
		_stop_horizontal_move(1)

	# Soft Drop Press / Release
	if event.is_action_pressed("soft_drop") or event.is_action_pressed("ui_down"):
		is_soft_dropping = true
		soft_drop_timer = 0.0
		engine.soft_drop()
	elif event.is_action_released("soft_drop") or event.is_action_released("ui_down"):
		is_soft_dropping = false

func _start_horizontal_move(dir: int) -> void:
	move_dir = dir
	das_timer = 0.0
	arr_timer = 0.0
	engine.move_piece(Vector2i(move_dir, 0))

func _stop_horizontal_move(dir: int) -> void:
	if move_dir == dir:
		if Input.is_action_pressed("move_left") or Input.is_action_pressed("ui_left"):
			_start_horizontal_move(-1)
		elif Input.is_action_pressed("move_right") or Input.is_action_pressed("ui_right"):
			_start_horizontal_move(1)
		else:
			move_dir = 0
			das_timer = 0.0
			arr_timer = 0.0

func _apply_dcd() -> void:
	if DCD_MS > 0.0 and move_dir != 0:
		das_timer = maxf(0.0, das_timer - DCD_MS)

func setup_multiplayer(my_id: int, enemy_id: int) -> void:
	player_id = my_id
	target_id = enemy_id
	is_battle = true

func toggle_ready() -> bool:
	player_ready = not player_ready
	return player_ready

func stop() -> void:
	is_local_player = false
	if engine != null:
		engine.is_topped_out = true

func handle_death_sequence() -> void:
	Audio.play_sound("KO")
	board_topped_out.emit()
	shake(12.0, 0.3)
	await shake_finished
	if anim != null:
		anim.play("popup")
