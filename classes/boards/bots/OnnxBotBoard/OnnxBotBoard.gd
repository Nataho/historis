class_name OnnxBotBoard
extends Board

@export_group("AI Settings")
@export var onnx_model_path: String = "res://ai_models/tetris_bot.onnx"

@export_group("In-Game Bot Handling Settings")
@export var move_delay_ms: float = 20.0
@export var rotate_delay_ms: float = 30.0
@export var drop_delay_sec: float = 0.05
@export var force_instant_placement: bool = false

var onnx_runner: Object = null
var is_thinking: bool = false
var model_session: Object = null

# Distributional evidence for whether a model's decisions are a
# genuine learned pattern vs a fixed bias — one-off predictions are
# too easy to over-read anecdotally.
var _x_tally: Dictionary = {}
var _hold_true_count: int = 0
var _hold_false_count: int = 0
const _TALLY_SUMMARY_INTERVAL: int = 50

func _ready() -> void:
	super._ready()
	_load_onnx_model()

func _initialize_engine() -> void:
	super._initialize_engine()
	if engine != null:
		if not engine.lines_cleared.is_connected(_on_lines_cleared):
			engine.lines_cleared.connect(_on_lines_cleared)
		if not engine.game_over.is_connected(_on_game_over):
			engine.game_over.connect(_on_game_over)

func start() -> void:
	super.start()
	b2b_streak = 0
	is_thinking = false
	if engine != null:
		if not engine.queue_changed.is_connected(_on_ai_turn_ready):
			engine.queue_changed.connect(_on_ai_turn_ready, CONNECT_DEFERRED)
		_on_ai_turn_ready(engine.queue)

func _load_onnx_model() -> void:
	var runner = Engine.get_singleton("OnnxRunner")
	model_session = runner.load_model(onnx_model_path)

	if model_session != null:
		print("[AI] ONNX Input Name: ", model_session.input_name(0))
		print("[AI] ONNX Input Shape: ", model_session.input_shape(0))

func _get_best_action_from_obs(obs: PackedFloat32Array) -> int:
	if model_session == null:
		return randi() % 80
	
	var logits: PackedFloat32Array = model_session.run(obs)
	if logits == null or logits.is_empty():
		return randi() % 80

	var best_idx: int = 0
	var max_score: float = -999999.0
	
	for i in range(logits.size()):
		if logits[i] > max_score:
			max_score = logits[i]
			best_idx = i

	# Print model predictions to output
	print("[AI Prediction] Selected Action Index: ", best_idx, " | Logit Score: ", max_score)
	_tally_prediction(best_idx)
	return best_idx

func _tally_prediction(action_idx: int) -> void:
	var decoded: Dictionary = decode_action(action_idx)
	var x: int = decoded["target_x"]
	var used_hold: bool = decoded["use_hold"]

	_x_tally[x] = _x_tally.get(x, 0) + 1
	if used_hold:
		_hold_true_count += 1
	else:
		_hold_false_count += 1

	var total: int = _hold_true_count + _hold_false_count
	if total % _TALLY_SUMMARY_INTERVAL == 0:
		var x_line: String = ""
		for xi in range(10):
			x_line += "%d:%d  " % [xi, _x_tally.get(xi, 0)]
		print("[AI TALLY] n=%d  hold=%d/%d (%.0f%%)  target_x counts -> %s" % [
			total, _hold_true_count, total,
			100.0 * float(_hold_true_count) / float(total),
			x_line
		])

func _on_ai_turn_ready(_next_pieces: Array[String]) -> void:
	if engine == null or engine.active_piece_type.is_empty() or is_thinking:
		return

	is_thinking = true
	await get_tree().process_frame

	if engine == null or engine.active_piece_type.is_empty():
		is_thinking = false
		return

	var obs: PackedFloat32Array = get_observation_vector()
	var action_idx: int = _get_best_action_from_obs(obs)
	var action: Dictionary = decode_action(action_idx)
	
	await execute_action(action)
	is_thinking = false


func execute_action(action: Dictionary) -> void:
	if engine == null or engine.active_piece_type.is_empty():
		return

	# --- HANDLING CHECK ---
	# Skip handling delays if training OR if forced instant placement
	var is_training: bool = (self is TrainingBotBoard)
	var apply_handling: bool = not is_training and not force_instant_placement

	var target_rot: int = action.get("target_rot", 0)
	var target_x: int = action.get("target_x", 3)
	var use_hold: bool = action.get("use_hold", false)

	# 1. Hold Piece
	if use_hold and engine.can_hold:
		engine.hold_active_piece()
		if apply_handling and rotate_delay_ms > 0:
			await get_tree().create_timer(rotate_delay_ms / 1000.0).timeout
		if engine.active_piece_type.is_empty():
			return

	# 2. Rotation Handling
	var kick_table: Dictionary = pieces_controller.get_kick_table(engine.active_piece_type)
	if not kick_table.is_empty():
		var rotate_attempts: int = 0
		while engine.rotation_state != target_rot and rotate_attempts < 4:
			rotate_attempts += 1
			if not engine.rotate_piece(true, kick_table):
				break
			if apply_handling and rotate_delay_ms > 0:
				await get_tree().create_timer(rotate_delay_ms / 1000.0).timeout

	# 3. Horizontal Movement Handling
	var current_x: int = engine.active_pos.x
	var diff_x: int = target_x - current_x
	var dir: Vector2i = Vector2i.RIGHT if diff_x > 0 else Vector2i.LEFT
	var max_moves: int = engine.width

	for i in range(min(abs(diff_x), max_moves)):
		if not engine.move_piece(dir):
			break
		if apply_handling and move_delay_ms > 0:
			await get_tree().create_timer(move_delay_ms / 1000.0).timeout

	# 4. Drop Delay Handling
	if apply_handling and drop_delay_sec > 0:
		await get_tree().create_timer(drop_delay_sec).timeout

	engine.hard_drop()

func _on_game_over() -> void:
	b2b_streak = 0
	is_thinking = false
