class_name TrainingBotBoard
extends OnnxBotBoard

## Training Curriculum Ruleset Presets
enum RulesetPreset {
	STAGE_1_SURVIVAL_MASTERY, ## Goal: Stay alive to 1000 steps, keep stack low, clean holes, single/double/triple/quad all rewarded
	STAGE_2_CLEAN_BUILDER,    ## Goal: Strict surface flatness, heavier hole penalty, quad & combo focus
	STAGE_3_COMBAT_ATTACK,    ## Goal: Maximize Back-to-Back Quads, T-Spins, and sending massive garbage
	CUSTOM,                   ## Goal: Use user-defined inspector export variables directly
}

@export_group("Curriculum Ruleset Preset")
@export var active_ruleset: RulesetPreset = RulesetPreset.STAGE_1_SURVIVAL_MASTERY:
	set(value):
		active_ruleset = value
		if active_ruleset != RulesetPreset.CUSTOM:
			_apply_ruleset_preset(active_ruleset)

@export_group("Episode Goal & Milestones")
@export var max_episode_steps: int = 1000
@export var max_steps_bonus: float = 150.0
@export var auto_reset_on_max_steps: bool = true
@export var enable_milestones: bool = true
@export var verbose_milestone_logs: bool = true
@export var milestone_50_bonus: float = 10.0
@export var milestone_100_bonus: float = 20.0
@export var milestone_250_bonus: float = 40.0
@export var milestone_500_bonus: float = 75.0
@export var milestone_750_bonus: float = 100.0

@export_group("Survival & Stack Height Rules")
@export var step_survival_reward: float = 1.0
@export var invalid_action_penalty: float = 1.0 ## Penalizes out-of-bounds column selections that had to be snapped
@export var hard_drop_tile_reward: float = 0.02 ## Reward per vertical tile dropped (covers stack depth)
@export var soft_drop_tile_multiplier: float = 0.5 ## Half reward per tile if soft drop path was required
@export var low_stack_bonus: float = 0.25
@export var safe_stack_height: int = 6
@export var danger_height_threshold: int = 13
@export var critical_ceiling_height: int = 17
@export var downstack_reward_weight: float = 1.5
@export var high_danger_downstack_multiplier: float = 1.6
@export var upstack_penalty_weight: float = 0.35
@export var danger_upstack_penalty: float = 1.2
@export var ceiling_step_penalty: float = 2.5

@export_group("Holes & Buried Air Rules")
@export var hole_creation_penalty: float = 4.5
@export var hole_clear_reward: float = 4.5
@export var soft_drop_hole_clear_multiplier: float = 0.5 ## Receiving half score when filling/clearing holes via soft drops vs hard drops
@export var covered_blocks_penalty_weight: float = 0.5

@export_group("Surface Flatness Rules")
@export var bumpiness_penalty: float = 0.20
@export var bumpiness_flatten_reward: float = 0.20

@export_group("Line Clear Rules")
@export var reward_single: float = 2.0
@export var reward_double: float = 4.5
@export var reward_triple: float = 8.0
@export var reward_quad: float = 14.0
@export var perfect_clear_bonus: float = 50.0
@export var b2b_bonus_weight: float = 1.0
@export var max_b2b_bonus: float = 5.0
@export var tspin_reward_multiplier: float = 4.0
@export var combo_reward_multiplier: float = 0.5

@export_group("Game Over & Death Penalties")
@export var game_over_penalty: float = 200.0
@export var enable_early_topout_penalty: bool = true
@export var early_topout_step_threshold: int = 60
@export var early_topout_penalty_multiplier: float = 3.0
@export var dynamic_early_scaling: bool = true ## Scales penalty higher the earlier the bot tops out

@export_group("Combat Rules")
@export var garbage_sent_multiplier: float = 0.5
@export var garbage_applied_penalty: float = 0.5

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
var _episode_steps: int = 0

# Action-source diagnostics
var _real_action_count: int = 0
var _random_fallback_count: int = 0
const _ACTION_SUMMARY_INTERVAL: int = 200

func _ready() -> void:
	super._ready()
	_apply_cmdline_overrides()
	_connect_to_python_server()

func _apply_ruleset_preset(preset: RulesetPreset) -> void:
	match preset:
		RulesetPreset.STAGE_1_SURVIVAL_MASTERY:
			max_episode_steps = 1000
			max_steps_bonus = 150.0
			auto_reset_on_max_steps = true
			enable_milestones = true
			milestone_50_bonus = 10.0
			milestone_100_bonus = 20.0
			milestone_250_bonus = 40.0
			milestone_500_bonus = 75.0
			milestone_750_bonus = 100.0

			step_survival_reward = 1.0
			low_stack_bonus = 0.25
			safe_stack_height = 6
			danger_height_threshold = 13
			critical_ceiling_height = 17
			downstack_reward_weight = 1.5
			high_danger_downstack_multiplier = 1.6
			upstack_penalty_weight = 0.35
			danger_upstack_penalty = 1.2
			ceiling_step_penalty = 2.5

			hole_creation_penalty = 4.5
			hole_clear_reward = 4.5
			covered_blocks_penalty_weight = 0.5

			bumpiness_penalty = 0.20
			bumpiness_flatten_reward = 0.20

			reward_single = 2.0
			reward_double = 4.5
			reward_triple = 8.0
			reward_quad = 14.0
			perfect_clear_bonus = 50.0
			b2b_bonus_weight = 1.0
			max_b2b_bonus = 5.0
			tspin_reward_multiplier = 4.0
			combo_reward_multiplier = 0.5

			game_over_penalty = 200.0
			enable_early_topout_penalty = true
			early_topout_step_threshold = 60
			early_topout_penalty_multiplier = 3.0
			dynamic_early_scaling = true
			garbage_sent_multiplier = 0.5
			garbage_applied_penalty = 0.5

		RulesetPreset.STAGE_2_CLEAN_BUILDER:
			max_episode_steps = 1500
			max_steps_bonus = 200.0
			auto_reset_on_max_steps = true
			enable_milestones = true
			milestone_50_bonus = 5.0
			milestone_100_bonus = 10.0
			milestone_250_bonus = 30.0
			milestone_500_bonus = 60.0
			milestone_750_bonus = 100.0

			step_survival_reward = 0.8
			low_stack_bonus = 0.30
			safe_stack_height = 7
			danger_height_threshold = 14
			critical_ceiling_height = 17
			downstack_reward_weight = 1.2
			high_danger_downstack_multiplier = 1.5
			upstack_penalty_weight = 0.40
			danger_upstack_penalty = 1.5
			ceiling_step_penalty = 3.0

			hole_creation_penalty = 6.0
			hole_clear_reward = 6.0
			covered_blocks_penalty_weight = 0.8

			bumpiness_penalty = 0.35
			bumpiness_flatten_reward = 0.35

			reward_single = 1.0
			reward_double = 3.5
			reward_triple = 7.5
			reward_quad = 18.0
			perfect_clear_bonus = 60.0
			b2b_bonus_weight = 1.5
			max_b2b_bonus = 8.0
			tspin_reward_multiplier = 5.0
			combo_reward_multiplier = 0.8

			game_over_penalty = 250.0
			enable_early_topout_penalty = true
			early_topout_step_threshold = 80
			early_topout_penalty_multiplier = 2.5
			dynamic_early_scaling = true
			garbage_sent_multiplier = 1.0
			garbage_applied_penalty = 0.8

		RulesetPreset.STAGE_3_COMBAT_ATTACK:
			max_episode_steps = 2000
			max_steps_bonus = 250.0
			auto_reset_on_max_steps = true
			enable_milestones = true
			milestone_50_bonus = 5.0
			milestone_100_bonus = 10.0
			milestone_250_bonus = 25.0
			milestone_500_bonus = 50.0
			milestone_750_bonus = 80.0

			step_survival_reward = 0.5
			low_stack_bonus = 0.20
			safe_stack_height = 8
			danger_height_threshold = 15
			critical_ceiling_height = 18
			downstack_reward_weight = 1.0
			high_danger_downstack_multiplier = 1.5
			upstack_penalty_weight = 0.30
			danger_upstack_penalty = 1.5
			ceiling_step_penalty = 3.5

			hole_creation_penalty = 5.0
			hole_clear_reward = 5.0
			covered_blocks_penalty_weight = 0.5

			bumpiness_penalty = 0.25
			bumpiness_flatten_reward = 0.25

			reward_single = 0.5
			reward_double = 2.0
			reward_triple = 5.0
			reward_quad = 20.0
			perfect_clear_bonus = 75.0
			b2b_bonus_weight = 2.5
			max_b2b_bonus = 12.0
			tspin_reward_multiplier = 8.0
			combo_reward_multiplier = 1.2

			game_over_penalty = 300.0
			enable_early_topout_penalty = true
			early_topout_step_threshold = 100
			early_topout_penalty_multiplier = 2.0
			dynamic_early_scaling = true
			garbage_sent_multiplier = 2.5
			garbage_applied_penalty = 1.0

		RulesetPreset.CUSTOM:
			pass

func _apply_cmdline_overrides() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			var port_str: String = arg.substr(len("--port="))
			if port_str.is_valid_int():
				server_port = port_str.to_int()
		elif arg.begins_with("--ruleset="):
			var r_str: String = arg.substr(len("--ruleset=")).to_lower()
			if r_str == "1" or r_str == "survival":
				active_ruleset = RulesetPreset.STAGE_1_SURVIVAL_MASTERY
			elif r_str == "2" or r_str == "builder" or r_str == "clean":
				active_ruleset = RulesetPreset.STAGE_2_CLEAN_BUILDER
			elif r_str == "3" or r_str == "combat" or r_str == "attack":
				active_ruleset = RulesetPreset.STAGE_3_COMBAT_ATTACK
			elif r_str == "custom":
				active_ruleset = RulesetPreset.CUSTOM

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
	_episode_steps = 0
	if engine == null:
		start()
	else:
		reset()
	prev_metrics = _get_extended_board_metrics()
	call_deferred("_step_ai")

func _on_ai_turn_ready(_next_pieces: Array[String]) -> void:
	pass

func _get_extended_board_metrics() -> Dictionary:
	var base_metrics: Dictionary = _get_board_metrics()
	if engine == null:
		return base_metrics

	var total_blocks: int = 0
	var covered_cells: int = 0
	for x in range(engine.width):
		var hole_found_below: bool = false
		for y in range(engine.height - 1, -1, -1):
			if engine.grid[y][x] == -1:
				hole_found_below = true
			elif hole_found_below:
				covered_cells += 1
			if engine.grid[y][x] != -1:
				total_blocks += 1

	base_metrics["covered_cells"] = covered_cells
	base_metrics["total_blocks"] = total_blocks
	base_metrics["is_perfect_clear"] = (total_blocks == 0)
	return base_metrics

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
			_episode_steps = 0
			reset()
			prev_metrics = _get_extended_board_metrics()
			call_deferred("_step_ai")
			return

		prev_metrics = _get_extended_board_metrics()

		var action: Dictionary = decode_action(action_idx)
		await execute_action(action)

		_episode_steps += 1

		# If execute_action caused a topout, step_done is already true
		if not step_done:
			# Check progressive milestone bonuses
			if enable_milestones:
				if _episode_steps == 50 and milestone_50_bonus > 0:
					accumulated_reward += milestone_50_bonus
					if verbose_milestone_logs:
						print("[TRAIN][BOARD %d] ⭐ Reached 50-step milestone! (+%.1f)" % [player_id, milestone_50_bonus])
				elif _episode_steps == 100 and milestone_100_bonus > 0:
					accumulated_reward += milestone_100_bonus
					if verbose_milestone_logs:
						print("[TRAIN][BOARD %d] ⭐ Reached 100-step milestone! (+%.1f)" % [player_id, milestone_100_bonus])
				elif _episode_steps == 250 and milestone_250_bonus > 0:
					accumulated_reward += milestone_250_bonus
					if verbose_milestone_logs:
						print("[TRAIN][BOARD %d] ⭐ Reached 250-step milestone! (+%.1f)" % [player_id, milestone_250_bonus])
				elif _episode_steps == 500 and milestone_500_bonus > 0:
					accumulated_reward += milestone_500_bonus
					if verbose_milestone_logs:
						print("[TRAIN][BOARD %d] ⭐ Reached 500-step milestone! (+%.1f)" % [player_id, milestone_500_bonus])
				elif _episode_steps == 750 and milestone_750_bonus > 0:
					accumulated_reward += milestone_750_bonus
					if verbose_milestone_logs:
						print("[TRAIN][BOARD %d] ⭐ Reached 750-step milestone! (+%.1f)" % [player_id, milestone_750_bonus])

			var curr_metrics: Dictionary = _get_extended_board_metrics()
			_evaluate_placement_reward(prev_metrics, curr_metrics)

			# Step limit for continuous play & goal achievement
			if max_episode_steps > 0 and _episode_steps >= max_episode_steps:
				if verbose_milestone_logs:
					print("[TRAIN][BOARD %d] 🏆 GOAL ACHIEVED! Survived %d steps! (+%.1f)" % [player_id, _episode_steps, max_steps_bonus])
				accumulated_reward += max_steps_bonus
				if auto_reset_on_max_steps:
					step_done = true
	else:
		_note_random_fallback("is_connected_to_python is false — no python server connected at all")
		var action_idx: int = randi() % 80
		await execute_action(decode_action(action_idx))

	call_deferred("_step_ai")

func _evaluate_placement_reward(prev: Dictionary, curr: Dictionary) -> void:
	var prev_holes: int = prev.get("holes", 0)
	var curr_holes: int = curr.get("holes", 0)
	var delta_holes: int = curr_holes - prev_holes

	var prev_bumpiness: int = prev.get("bumpiness", 0)
	var curr_bumpiness: int = curr.get("bumpiness", 0)
	var delta_bumpiness: int = curr_bumpiness - prev_bumpiness

	var prev_height: int = prev.get("max_height", 0)
	var curr_height: int = curr.get("max_height", 0)
	var delta_height: int = curr_height - prev_height

	var prev_covered: int = prev.get("covered_cells", 0)
	var curr_covered: int = curr.get("covered_cells", 0)
	var delta_covered: int = curr_covered - prev_covered

	# 1. Base continuous survival reward: strong baseline per placement to encourage living long
	var step_score: float = step_survival_reward

	# Out-of-bounds invalid placement penalty
	if last_action_was_snapped:
		step_score -= invalid_action_penalty

	# Drop Distance / Depth Bonus (more tiles covered from spawn to lock = higher reward)
	if last_drop_distance > 0 and hard_drop_tile_reward > 0:
		var drop_mult: float = soft_drop_tile_multiplier if last_action_used_soft_drop else 1.0
		step_score += float(last_drop_distance) * (hard_drop_tile_reward * drop_mult)

	# 2. Holes penalty / reward: creating holes severely degrades long-term survivability
	if delta_holes > 0:
		step_score -= float(delta_holes) * hole_creation_penalty
	elif delta_holes < 0:
		var reward_mult: float = soft_drop_hole_clear_multiplier if last_action_used_soft_drop else 1.0
		step_score += float(abs(delta_holes)) * (hole_clear_reward * reward_mult)

	# 3. Buried holes penalty (blocks stacked above holes making them harder to clear)
	if delta_covered > 0:
		step_score -= float(delta_covered) * covered_blocks_penalty_weight
	elif delta_covered < 0:
		step_score += float(abs(delta_covered)) * (covered_blocks_penalty_weight * 0.5)

	# 4. Bumpiness penalty / reward: maintain flat, organized terrain
	if delta_bumpiness > 0:
		step_score -= float(delta_bumpiness) * bumpiness_penalty
	elif delta_bumpiness < 0:
		step_score += float(abs(delta_bumpiness)) * bumpiness_flatten_reward

	# 5. Stack Height & Downstacking Rules
	if curr_height <= safe_stack_height:
		step_score += low_stack_bonus
	elif curr_height > safe_stack_height and curr_height <= danger_height_threshold:
		if delta_height < 0:
			step_score += float(abs(delta_height)) * downstack_reward_weight
		elif delta_height > 0:
			step_score -= float(delta_height) * upstack_penalty_weight
	elif curr_height > danger_height_threshold:
		if delta_height < 0:
			step_score += float(abs(delta_height)) * downstack_reward_weight * high_danger_downstack_multiplier
		elif delta_height > 0:
			step_score -= float(delta_height) * danger_upstack_penalty

	# Critical ceiling danger warning (near topout height >= critical_ceiling_height)
	if curr_height >= critical_ceiling_height:
		step_score -= ceiling_step_penalty

	# 6. Perfect Clear (All Clear) bonus
	if curr.get("is_perfect_clear", false) and prev.get("total_blocks", 0) > 0:
		step_score += perfect_clear_bonus
		if verbose_milestone_logs:
			print("[TRAIN][BOARD %d] ✨ PERFECT CLEAR (ALL CLEAR)! (+%.1f)" % [player_id, perfect_clear_bonus])

	accumulated_reward += step_score

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
	var timeout_frames: int = 1200
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

func _on_lines_cleared(line_count: int, combo_count: int, is_tspin: bool) -> void:
	super._on_lines_cleared(line_count, combo_count, is_tspin)

	# Balanced rewards for clearing lines and downstacking safely
	match line_count:
		1: accumulated_reward += reward_single
		2: accumulated_reward += reward_double
		3: accumulated_reward += reward_triple
		4:
			accumulated_reward += reward_quad
			if b2b_streak > 1:
				accumulated_reward += min(float(b2b_streak) * b2b_bonus_weight, max_b2b_bonus)

	# T-Spin reward
	if is_tspin:
		accumulated_reward += tspin_reward_multiplier * float(line_count)
		if b2b_streak > 1:
			accumulated_reward += min(float(b2b_streak) * b2b_bonus_weight, max_b2b_bonus)

	# Combo reward
	if combo_count > 0:
		accumulated_reward += float(combo_count) * combo_reward_multiplier

func _on_garbage_sent(chunks: Array) -> void:
	for chunk in chunks:
		var lines: int = int(chunk.get("lines", 0))
		accumulated_reward += float(lines) * garbage_sent_multiplier

func _on_garbage_applied(rows_added: int) -> void:
	accumulated_reward -= float(rows_added) * garbage_applied_penalty

func _on_game_over() -> void:
	super._on_game_over()
	var steps_lived: int = _episode_steps
	var penalty: float = game_over_penalty

	if enable_early_topout_penalty and steps_lived < early_topout_step_threshold:
		var mult: float = early_topout_penalty_multiplier
		if dynamic_early_scaling and early_topout_step_threshold > 0:
			var ratio: float = 1.0 - (float(steps_lived) / float(early_topout_step_threshold))
			mult = lerp(1.0, early_topout_penalty_multiplier, ratio)
		penalty *= mult
		if verbose_milestone_logs:
			print("[TRAIN][BOARD %d] 💀 EARLY TOPOUT at step %d (< %d min)! Multiplier: %.2fx -> Penalty: -%.1f" % [player_id, steps_lived, early_topout_step_threshold, mult, penalty])
	elif verbose_milestone_logs:
		print("[TRAIN][BOARD %d] 💀 Topout at step %d. Penalty: -%.1f" % [player_id, steps_lived, penalty])

	accumulated_reward -= penalty
	step_done = true
