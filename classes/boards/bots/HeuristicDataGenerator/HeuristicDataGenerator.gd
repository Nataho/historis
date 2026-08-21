extends Board
class_name HeuristicDataGenerator

@export var target_games: int = 500
@export var lookahead_depth: int = 2
@export var beam_width: int = 8
@export var demo_output_dir: String = "res://demos/"

@export_group("Speed & Visuals")
@export var slow_down: bool = false:
	set(val):
		slow_down = val
		_apply_speed_settings()
@export var fast_time_scale: float = 20.0

@export_group("Handling in Slow Mode")
@export var move_delay_ms: float = 25.0
@export var rotate_delay_ms: float = 35.0
@export var drop_delay_sec: float = 0.05

var bot := TetrisBot.new()
var games_played: int = 0
var total_samples: int = 0
var _record_file: FileAccess = null
var is_stepping: bool = false

func _ready() -> void:
	super._ready()
	_apply_speed_settings()
	_start_new_demo_file()
	start()

func set_slow_down(enabled: bool) -> void:
	slow_down = enabled

func _apply_speed_settings() -> void:
	Engine.time_scale = 1.0 if slow_down else fast_time_scale
	print("[GENERATOR][BOARD %d] Speed set -> slow_down=%s (Engine.time_scale=%.1f)" % [player_id, slow_down, Engine.time_scale])

func _physics_process(_delta: float) -> void:
	if games_played >= target_games:
		set_physics_process(false)
		if _record_file != null:
			_record_file.close()
			_record_file = null
		print("[GENERATOR][BOARD %d] Done! Finished %d games (%d total samples)." % [player_id, games_played, total_samples])
		return

	if is_topped_out():
		# When NOT slowing down, this generator is solely responsible for instant reset
		if not slow_down:
			games_played += 1
			print("[GENERATOR][BOARD %d] Fast TopOut -> Resetting game %d / %d | Total Samples: %d" % [player_id, games_played, target_games, total_samples])
			reset()
		return

	if is_stepping:
		return

	if engine != null and not engine.active_piece_type.is_empty():
		_step_generator()

func _step_generator() -> void:
	is_stepping = true

	# 1. Capture exact 413-float observation vector BEFORE making the move
	var current_obs: PackedFloat32Array = get_observation_vector()

	# 2. Find best move using TetrisBot heuristic search
	var best_move: Dictionary = bot.find_best_move(engine, lookahead_depth, beam_width)
	if best_move.is_empty():
		engine.hard_drop()
		is_stepping = false
		return

	var target_rot: int = best_move.get("rot", 0)
	var target_x: int = best_move.get("x", engine.active_pos.x)
	var use_hold: bool = best_move.get("use_hold", false)

	# 3. Encode action to integer 0..79
	var action_idx: int = encode_action(target_rot, target_x, use_hold)

	# 4. Record sample into binary .bin dataset
	_write_sample(current_obs, action_idx)

	# 5. Apply move to engine (Handling applies ONLY when slow_down is active)
	if slow_down:
		await _apply_move_with_handling(target_rot, target_x, use_hold, best_move)
	else:
		_apply_move_instant(target_rot, target_x, use_hold)

	is_stepping = false

func _execute_srs_rotation(target_rot: int, kick_table: Dictionary, p_type: String, apply_delay: bool) -> bool:
	if engine == null or engine.rotation_state == target_rot or p_type == "O":
		return true

	var attempts: int = 0
	while engine.rotation_state != target_rot and attempts < 4:
		attempts += 1
		var diff: int = posmod(target_rot - engine.rotation_state, 4)
		var rotated: bool = false

		if diff == 1:
			# Clockwise SRS turn
			rotated = engine.rotate_piece(true, kick_table)
		elif diff == 3:
			# Counter-Clockwise SRS turn
			rotated = engine.rotate_piece(false, kick_table)
		elif diff == 2:
			# 180-degree flip
			var kick_180: Dictionary = pieces_controller.get_180_kick_table(p_type) if pieces_controller != null else {}
			if not kick_180.is_empty():
				rotated = engine.rotate_180(kick_180)
			if not rotated:
				rotated = engine.rotate_piece(true, kick_table)
				if not rotated:
					rotated = engine.rotate_piece(false, kick_table)

		# Fallback to reverse turn if primary was blocked
		if not rotated:
			rotated = engine.rotate_piece(false, kick_table) if diff == 1 else engine.rotate_piece(true, kick_table)

		if not rotated:
			return false

		if apply_delay and rotate_delay_ms > 0:
			await get_tree().create_timer(rotate_delay_ms / 1000.0).timeout

	return engine.rotation_state == target_rot

func _apply_move_instant(target_rot: int, target_x: int, use_hold: bool) -> void:
	if use_hold and engine.can_hold:
		engine.hold_active_piece()
		if engine.active_piece_type.is_empty():
			return

	var p_type: String = engine.active_piece_type
	var kick_table: Dictionary = pieces_controller.get_kick_table(p_type) if pieces_controller != null else {}
	if not kick_table.is_empty():
		_execute_srs_rotation(target_rot, kick_table, p_type, false)

	var current_x: int = engine.active_pos.x
	var diff_x: int = target_x - current_x
	var dir: Vector2i = Vector2i.RIGHT if diff_x > 0 else Vector2i.LEFT

	for i in range(min(abs(diff_x), engine.width)):
		if not engine.move_piece(dir):
			break

	engine.hard_drop()

func _apply_move_with_handling(target_rot: int, target_x: int, use_hold: bool, best_move: Dictionary) -> void:
	# 1. Hold
	if use_hold and engine.can_hold:
		engine.hold_active_piece()
		if rotate_delay_ms > 0:
			await get_tree().create_timer(rotate_delay_ms / 1000.0).timeout
		if engine.active_piece_type.is_empty():
			return

	var p_type: String = engine.active_piece_type
	var kick_table: Dictionary = pieces_controller.get_kick_table(p_type) if pieces_controller != null else {}
	var path: Array = best_move.get("path", [])

	# 2. Path-following reachability if available
	if not path.is_empty():
		var req_soft_drop: bool = best_move.get("requires_soft_drop", false)
		for node: Vector3i in path:
			if engine.rotation_state != node.z:
				await _execute_srs_rotation(node.z, kick_table, p_type, true)

			while engine.active_pos.x != node.x:
				var h_dir = Vector2i.RIGHT if node.x > engine.active_pos.x else Vector2i.LEFT
				if not engine.move_piece(h_dir):
					break
				if move_delay_ms > 0:
					await get_tree().create_timer(move_delay_ms / 1000.0).timeout

			if req_soft_drop:
				while engine.active_pos.y < node.y:
					if not engine.move_piece(Vector2i.DOWN):
						break
					if drop_delay_sec > 0:
						await get_tree().create_timer(drop_delay_sec).timeout

		if req_soft_drop and drop_delay_sec > 0:
			await get_tree().create_timer(drop_delay_sec).timeout
		engine.hard_drop()
		return

	# Fallback Direct Handling
	if not kick_table.is_empty():
		await _execute_srs_rotation(target_rot, kick_table, p_type, true)

	var current_x: int = engine.active_pos.x
	var diff_x: int = target_x - current_x
	var dir: Vector2i = Vector2i.RIGHT if diff_x > 0 else Vector2i.LEFT

	for i in range(min(abs(diff_x), engine.width)):
		if not engine.move_piece(dir):
			break
		if move_delay_ms > 0:
			await get_tree().create_timer(move_delay_ms / 1000.0).timeout

	if drop_delay_sec > 0:
		await get_tree().create_timer(drop_delay_sec).timeout

	engine.hard_drop()

func _start_new_demo_file() -> void:
	if _record_file != null:
		_record_file.close()
		_record_file = null

	DirAccess.make_dir_recursive_absolute(demo_output_dir)
	var timestamp: String = Time.get_datetime_string_from_system().replace(":", "-")
	var path: String = demo_output_dir.path_join("heuristic_gen_%s_p%d_%d.bin" % [timestamp, player_id, randi() % 100000])
	_record_file = FileAccess.open(path, FileAccess.WRITE)
	if _record_file == null:
		push_error("[GENERATOR] Failed to open '%s' for writing!" % path)
	else:
		print("[GENERATOR][BOARD %d] Recording expert samples to: %s" % [player_id, path])

func _write_sample(obs: PackedFloat32Array, action_idx: int) -> void:
	if _record_file == null:
		return
	for v in obs:
		_record_file.store_float(v)
	_record_file.store_32(action_idx)
	total_samples += 1

	if total_samples % 1000 == 0:
		_record_file.flush()
		print("[GENERATOR][BOARD %d] Progress: %d samples recorded" % [player_id, total_samples])

func _exit_tree() -> void:
	if _record_file != null:
		_record_file.close()
		_record_file = null
