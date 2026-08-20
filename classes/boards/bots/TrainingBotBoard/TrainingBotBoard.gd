class_name TrainingBotBoard
extends OnnxBotBoard

@export_group("TCP Training Settings")
@export var server_host: String = "127.0.0.1"
@export var server_port: int = 11000
@export var auto_reconnect: bool = true

var tcp_client: StreamPeerTCP = StreamPeerTCP.new()
var is_connected_to_python: bool = false
var is_running_loop: bool = false

var accumulated_reward: float = 0.0
var step_done: bool = false
var prev_metrics: Dictionary = {}

# Action-source diagnostics — the only way to know whether this board is
# actually being driven by python's PPO decisions or silently degrading
# to random moves. Logged as a periodic summary rather than per-step
# since _step_ai() fires very frequently.
var _real_action_count: int = 0
var _random_fallback_count: int = 0
const _ACTION_SUMMARY_INTERVAL: int = 200

func _ready() -> void:
	super._ready()
	_apply_port_override()
	_connect_to_python_server()

func _apply_port_override() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			var port_str: String = arg.substr(len("--port="))
			if port_str.is_valid_int():
				server_port = port_str.to_int()

func _process(delta: float) -> void:
	super._process(delta)
	tcp_client.poll()
	
	var status: StreamPeerTCP.Status = tcp_client.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		if not is_connected_to_python:
			is_connected_to_python = true
			start_ai_loop()
	elif status != StreamPeerTCP.STATUS_CONNECTING:
		if is_connected_to_python:
			is_running_loop = false
		is_connected_to_python = false
		
		if status != StreamPeerTCP.STATUS_NONE:
			tcp_client.disconnect_from_host()
			
		if auto_reconnect and Engine.get_process_frames() % 180 == 0:
			_connect_to_python_server()

func _connect_to_python_server() -> void:
	if tcp_client.get_status() != StreamPeerTCP.STATUS_NONE:
		return
	tcp_client.connect_to_host(server_host, server_port)

func _initialize_engine() -> void:
	super._initialize_engine()
	if engine != null:
		if not engine.garbage_sent.is_connected(_on_garbage_sent):
			engine.garbage_sent.connect(_on_garbage_sent)
		if not engine.garbage_applied.is_connected(_on_garbage_applied):
			engine.garbage_applied.connect(_on_garbage_applied)

func start_ai_loop() -> void:
	if is_running_loop:
		return
	is_running_loop = true
	start()
	prev_metrics = _get_board_metrics()
	call_deferred("_step_ai")

func _on_ai_turn_ready(_next_pieces: Array[String]) -> void:
	pass

func _step_ai() -> void:
	if not is_running_loop or engine == null:
		return
	if engine.active_piece_type.is_empty():
		call_deferred("_step_ai")
		return

	var obs: PackedFloat32Array = get_observation_vector()

	if is_connected_to_python:
		_send_state_to_python(obs, accumulated_reward, step_done)
		var was_done: bool = step_done
		accumulated_reward = 0.0
		step_done = false

		var action_idx: int = await _receive_action_from_python()

		if was_done:
			reset()
			prev_metrics = _get_board_metrics()
			call_deferred("_step_ai")
			return

		prev_metrics = _get_board_metrics()
		
		var action: Dictionary = decode_action(action_idx)
		await execute_action(action)
		
		var curr_metrics: Dictionary = _get_board_metrics()
		_evaluate_placement_reward(prev_metrics, curr_metrics)
	else:
		_note_random_fallback("is_connected_to_python is false — no python server connected at all")
		var action_idx: int = randi() % 80
		await execute_action(decode_action(action_idx))

	call_deferred("_step_ai")

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
		"max_height": max_h
	}

func _evaluate_placement_reward(prev: Dictionary, curr: Dictionary) -> void:
	var delta_holes: int = curr.get("holes", 0) - prev.get("holes", 0)
	var delta_bumpiness: int = curr.get("bumpiness", 0) - prev.get("bumpiness", 0)
	var curr_height: int = curr.get("max_height", 0)
	var prev_height: int = prev.get("max_height", 0)

	if delta_holes > 0:
		accumulated_reward -= delta_holes * 12.0
	elif delta_holes < 0:
		accumulated_reward += abs(delta_holes) * 15.0

	accumulated_reward -= delta_bumpiness * 0.8

	if curr_height > 14:
		if curr_height < prev_height:
			accumulated_reward += 12.0
		if delta_holes > 0:
			accumulated_reward -= 20.0

func _send_state_to_python(obs: PackedFloat32Array, reward: float, done: bool) -> void:
	var packet := PackedByteArray()
	packet.resize(8 + obs.size() * 4)
	packet.encode_float(0, reward)
	packet.encode_s32(4, 1 if done else 0)
	
	var offset: int = 8
	for f in obs:
		packet.encode_float(offset, f)
		offset += 4
		
	tcp_client.put_data(packet)

func _receive_action_from_python() -> int:
	var timeout_frames: int = 120
	while tcp_client.get_status() == StreamPeerTCP.STATUS_CONNECTED and tcp_client.get_available_bytes() < 4 and timeout_frames > 0:
		tcp_client.poll()
		await get_tree().process_frame
		timeout_frames -= 1

	if tcp_client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_note_random_fallback("connection dropped mid-wait (status=%s)" % tcp_client.get_status())
		return randi() % 80

	if timeout_frames <= 0 and tcp_client.get_available_bytes() < 4:
		_note_random_fallback("timed out after 120 frames waiting for python's action")
		return randi() % 80

	if tcp_client.get_available_bytes() >= 4:
		var result: Array = tcp_client.get_data(4)
		if result[0] == OK:
			var bytes: PackedByteArray = result[1]
			_note_real_action()
			return bytes.decode_s32(0)
		else:
			_note_random_fallback("get_data() failed with error %s" % result[0])
			return randi() % 80

	_note_random_fallback("fell through with no data available (unexpected)")
	return randi() % 80

func _note_real_action() -> void:
	_real_action_count += 1
	if _real_action_count % _ACTION_SUMMARY_INTERVAL == 0:
		print("[TRAIN] action source so far: %d real (from python), %d random-fallback" % [_real_action_count, _random_fallback_count])

func _note_random_fallback(reason: String) -> void:
	_random_fallback_count += 1
	push_warning("[TRAIN] action FELL BACK TO RANDOM (%s) — this step is NOT from PPO. Running total: %d real, %d random." % [reason, _real_action_count, _random_fallback_count])

func _on_lines_cleared(line_count: int, combo_count: int, is_tspin:bool) -> void:
	super._on_lines_cleared(line_count, combo_count, is_tspin)
	match line_count:
		1: accumulated_reward += 5.0
		2: accumulated_reward += 15.0
		3: accumulated_reward += 25.0
		4: 
			accumulated_reward += 40.0
			if b2b_streak > 1:
				accumulated_reward += float(b2b_streak) * 20.0
			if prev_metrics.get("holes", 0) > 0:
				accumulated_reward += 30.0

	if combo_count > 0:
		accumulated_reward += float(combo_count) * 6.0

func _on_garbage_sent(chunks: Array) -> void:
	for chunk in chunks:
		var lines: int = int(chunk.get("lines", 0))
		accumulated_reward += float(lines) * 15.0

func _on_garbage_applied(rows_added: int) -> void:
	accumulated_reward -= float(rows_added) * 5.0

func _on_game_over() -> void:
	super._on_game_over()
	accumulated_reward -= 1000.0
	step_done = true
