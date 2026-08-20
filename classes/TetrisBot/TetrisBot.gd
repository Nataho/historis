class_name TetrisBot extends RefCounted

# Cost charged per actual input instruction (MOVE_X, DROP_Y, or a single
# ROTATE_CW/CCW press) a candidate's reachability path requires to execute.
# Without this, _evaluate_placement only scores the resulting board shape, so
# a placement that's board-optimal but requires snaking through several
# rotate/move steps to physically get there (because the terrain forces a
# different orientation or a detour at different heights) scores identically
# to a placement reachable with one clean move. The bot then has no reason to
# prefer the simple one, producing long, oscillating action queues.
#
# _count_path_instructions() mirrors CloobBotBoard._build_instruction_queue()
# exactly: consecutive x-only or y-only steps merge into a single
# MOVE_X/DROP_Y (until a rotation or the other axis breaks the run), and each
# rotation costs its true shortest-direction press count (1 press for a
# 90-degree turn, 2 for a 180). Scoring on this instead of raw path-node count
# or rotation count alone means the penalty tracks exactly what shows up in
# the printed [BOT QUEUE] line. Real T-spin setups still clear this bar
# easily (worth 15000-90000 in _evaluate_placement); this only suppresses
# maneuvers that aren't worth their execution complexity.
const EXECUTION_INSTRUCTION_PENALTY: float = 800.0

func find_best_move(engine: TetrisEngine, depth: int = 2, beam_width: int = 8) -> Dictionary:
	var top_candidates = _get_candidate_placements(engine, true, true, beam_width)
	
	if top_candidates.is_empty():
		top_candidates = _get_candidate_placements(engine, true, false, beam_width)

	if top_candidates.is_empty():
		return {
			"use_hold": false,
			"rot": engine.rotation_state,
			"x": engine.active_pos.x,
			"y": engine.active_pos.y,
			"requires_soft_drop": false,
			"is_complex": false,
			"clear_type": "",
			"path": []
		}

	if depth <= 1:
		var chosen_move: Dictionary = top_candidates[0]["move"].duplicate()
		chosen_move["result_grid"] = top_candidates[0]["grid"]
		_log_selected_move(chosen_move)
		return chosen_move

	var lookahead_queue: Array[String] = []
	for i in range(min(depth - 1, engine.queue.size())):
		lookahead_queue.append(engine.queue[i])

	if lookahead_queue.is_empty():
		var chosen_move2: Dictionary = top_candidates[0]["move"].duplicate()
		chosen_move2["result_grid"] = top_candidates[0]["grid"]
		_log_selected_move(chosen_move2)
		return chosen_move2

	var best_combined_score: float = -9999999.0
	var best_move: Dictionary = top_candidates[0]["move"].duplicate()
	best_move["result_grid"] = top_candidates[0]["grid"]

	for cand in top_candidates:
		var sim_grid = cand["grid"]
		var score_1 = cand["score"]

		var score_2 = _search_recursive(engine, sim_grid, lookahead_queue, 0, beam_width)
		var total_score = score_1 + score_2

		if total_score > best_combined_score:
			best_combined_score = total_score
			best_move = cand["move"].duplicate()
			best_move["result_grid"] = sim_grid

	_log_selected_move(best_move)
	return best_move

func _get_candidate_placements(engine: TetrisEngine, allow_hold: bool, check_reachability: bool, beam_width: int) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	
	var piece_options: Array[Dictionary] = [{"type": engine.active_piece_type, "hold": false}]
	if allow_hold and engine.can_hold:
		var hold_type = engine.hold_piece_type
		if hold_type.is_empty() and not engine.queue.is_empty():
			hold_type = engine.queue[0]
		if not hold_type.is_empty():
			piece_options.append({"type": hold_type, "hold": true})

	var default_spawn = Vector2i(3, 0)

	for p_opt in piece_options:
		var p_type: String = p_opt["type"]
		var is_hold: bool = p_opt["hold"]
		var max_rots: int = 1 if p_type == "O" else (2 if p_type in ["I", "S", "Z"] else 4)

		var start_pos = default_spawn if is_hold else engine.active_pos
		var start_rot = 0 if is_hold else engine.rotation_state

		for rot in range(max_rots):
			var offsets = _get_state_offsets_for_bot(engine, p_type, rot, is_hold)
			if offsets.is_empty(): continue

			for x in range(-2, engine.width + 2):
				var drop_y = _get_drop_y(engine, offsets, x)
				
				# 1. Standard Vertical Drop
				if drop_y != -1:
					var pos = Vector2i(x, drop_y)
					var reach_info = _evaluate_reachability(engine, p_type, start_pos, start_rot, pos, rot, drop_y, is_hold)
					if not check_reachability or reach_info["reachable"]:
						var sim_res = _simulate_grid_and_count(engine.grid, engine.width, engine.height, offsets, pos)
						var is_tspin_move = _is_t_spin(engine.grid, engine.width, engine.height, offsets, pos, p_type)
						var is_allspin_move = false if is_tspin_move else _is_all_spin(engine.grid, engine.width, engine.height, offsets, pos, p_type)
						var clear_type = _get_clear_type(sim_res["lines"], is_tspin_move, is_allspin_move)
						var score = _evaluate_placement(engine.grid, engine.width, engine.height, sim_res["grid"], sim_res["lines"], offsets, pos, p_type, rot)
						score -= float(_count_path_instructions(reach_info["path"], start_rot)) * EXECUTION_INSTRUCTION_PENALTY

						candidates.append({
							"score": score,
							"grid": sim_res["grid"],
							"move": {
								"use_hold": is_hold,
								"rot": rot,
								"x": x,
								"y": drop_y,
								"requires_soft_drop": false,
								"is_complex": is_tspin_move or is_allspin_move,
								"clear_type": clear_type,
								"path": reach_info["path"]
							}
						})

				# 2. Overhangs, Tucks, and Spins
				for alt_y in range(engine.height - 1, -1, -1):
					if alt_y == drop_y: continue
					var pos = Vector2i(x, alt_y)
					if _can_fit_raw(engine.grid, engine.width, engine.height, offsets, pos):
						if not _can_fit_raw(engine.grid, engine.width, engine.height, offsets, pos + Vector2i(0, 1)):
							var reach_info = _evaluate_reachability(engine, p_type, start_pos, start_rot, pos, rot, drop_y, is_hold)
							if not check_reachability or reach_info["reachable"]:
								var sim_res = _simulate_grid_and_count(engine.grid, engine.width, engine.height, offsets, pos)
								var is_tspin_move = _is_t_spin(engine.grid, engine.width, engine.height, offsets, pos, p_type)
								var is_allspin_move = false if is_tspin_move else _is_all_spin(engine.grid, engine.width, engine.height, offsets, pos, p_type)
								var clear_type = _get_clear_type(sim_res["lines"], is_tspin_move, is_allspin_move)
								var score = _evaluate_placement(engine.grid, engine.width, engine.height, sim_res["grid"], sim_res["lines"], offsets, pos, p_type, rot)
								score -= float(_count_path_instructions(reach_info["path"], start_rot)) * EXECUTION_INSTRUCTION_PENALTY

								candidates.append({
									"score": score,
									"grid": sim_res["grid"],
									"move": {
										"use_hold": is_hold,
										"rot": rot,
										"x": x,
										"y": alt_y,
										"requires_soft_drop": true,
										"is_complex": true,
										"clear_type": clear_type,
										"path": reach_info["path"]
									}
								})

	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	if candidates.size() > beam_width:
		return candidates.slice(0, beam_width)
	return candidates

func _count_path_instructions(path: Array, start_rot: int) -> int:
	if path.is_empty():
		return 0

	var count: int = 0
	var curr_rot: int = start_rot
	var curr_x: int = path[0].x
	var curr_y: int = path[0].y
	var last_action: String = ""  # "", "x", or "y" -- mirrors action_queue[-1]["type"]

	for node: Vector3i in path:
		var target_x: int = node.x
		var target_y: int = node.y
		var target_rot: int = node.z

		# Rotation: same shortest-direction logic as _queue_rotation --
		# a 90-degree turn is 1 press, a 180-degree turn is 2. Pressing a
		# rotation always breaks any in-progress MOVE_X/DROP_Y merge run.
		if curr_rot != target_rot:
			var diff: int = posmod(target_rot - curr_rot, 4)
			count += diff if diff <= 2 else 4 - diff
			curr_rot = target_rot
			last_action = ""

		if curr_x != target_x:
			if last_action != "x":
				count += 1
				last_action = "x"
			curr_x = target_x

		if curr_y != target_y:
			if last_action != "y":
				count += 1
				last_action = "y"
			curr_y = target_y

	return count

func _log_selected_move(move: Dictionary) -> void:
	var clear_type: String = move.get("clear_type", "")
	if not clear_type.is_empty():
		print("[BOT DEBUG] Selected Best Move -> ", clear_type)

func _get_clear_type(lines: int, is_tspin: bool, is_allspin: bool = false) -> String:
	if is_tspin:
		match lines:
			0: return "T-Spin Zero"
			1: return "T-Spin Single"
			2: return "T-Spin Double"
			3: return "T-Spin Triple"
	elif is_allspin:
		match lines:
			0: return "All-Spin Zero"
			1: return "All-Spin Single"
			2: return "All-Spin Double"
			3: return "All-Spin Triple"
	else:
		match lines:
			1: return "Single"
			2: return "Double"
			3: return "Triple"
			4: return "Quad"
	return ""

func _evaluate_placement(base_grid: Array, width: int, height: int, sim_grid: Array, lines: int, offsets: Array[Vector2i], pos: Vector2i, p_type: String, rot: int) -> float:
	var score: float = 0.0
	
	var is_tspin = _is_t_spin(base_grid, width, height, offsets, pos, p_type)
	if is_tspin and pos.y == _get_drop_y_raw(base_grid, width, height, offsets, pos.x):
		is_tspin = false

	var is_allspin = false
	if not is_tspin:
		is_allspin = _is_all_spin(base_grid, width, height, offsets, pos, p_type)
		if is_allspin and pos.y == _get_drop_y_raw(base_grid, width, height, offsets, pos.x):
			is_allspin = false

	# 1. Attack Line Clears
	if is_tspin:
		match lines:
			3: score += 90000.0
			2: score += 70000.0
			1: score += 35000.0
			0: score += 15000.0
	elif is_allspin:
		# All-spins pay less than a T-spin (they're a more opportunistic,
		# "skim for whatever attack is on offer" tool rather than the
		# primary attack plan), but still comfortably outscore a plain
		# clear so the bot will actively hunt for J/L/S/Z spin windows
		# instead of only ever spinning T pieces.
		match lines:
			3: score += 60000.0
			2: score += 45000.0
			1: score += 20000.0
	elif lines == 4:
		score += 65000.0
	elif lines > 0:
		var base_h = _count_holes(base_grid, width, height)
		var sim_h = _count_holes(sim_grid, width, height)
		if sim_h >= base_h:
			score -= float(lines) * 10000.0

	# 2. Reward Only NEW T-Spin Slots
	var base_tspin_slots = _count_tspin_slots(base_grid, width, height)
	var sim_tspin_slots = _count_tspin_slots(sim_grid, width, height)
	if sim_tspin_slots > base_tspin_slots:
		score += float(sim_tspin_slots - base_tspin_slots) * 30000.0

	# 2b. Reward Only NEW generic all-spin cavities (J/L/S/Z/I setups). This
	# is what lets the bot deliberately "risk" a slightly rougher-looking
	# stack -- tucking an overhang in on purpose -- because it's banking on
	# skimming a future all-spin attack out of that pocket rather than
	# only ever playing flat.
	var base_allspin_slots = _count_all_spin_slots(base_grid, width, height)
	var sim_allspin_slots = _count_all_spin_slots(sim_grid, width, height)
	if sim_allspin_slots > base_allspin_slots:
		score += float(sim_allspin_slots - base_allspin_slots) * 12000.0

	# 3. Hole and Blockade Penalties
	var sim_holes = _count_holes(sim_grid, width, height)
	score -= float(sim_holes) * 75000.0

	var blockades = _count_blockades(sim_grid, width, height)
	score -= float(blockades) * 12000.0

	# 4. Flatness and Column Heights
	var col_heights = _get_column_heights(sim_grid, width, height)
	var primary_well = _find_best_well(col_heights, width)
	var bumpiness = _get_bumpiness(col_heights, width, primary_well)
	score -= float(bumpiness) * 1000.0

	# 5. Penalize Secondary Wells (Prevents 2-Well Canyon Bug)
	for c in range(width):
		if c == primary_well: continue
		var left_h = col_heights[c - 1] if c > 0 else col_heights[c] + 2
		var right_h = col_heights[c + 1] if c < width - 1 else col_heights[c] + 2
		var dip = min(left_h, right_h) - col_heights[c]
		if dip >= 2:
			score -= float(dip * dip) * 8000.0

	# 6. Penalize Relative Spires (Columns sticking up higher than neighbors)
	for c in range(1, width - 1):
		var diff_left = col_heights[c] - col_heights[c - 1]
		var diff_right = col_heights[c] - col_heights[c + 1]
		if diff_left > 2 and diff_right > 2:
			var spire_height = min(diff_left, diff_right)
			score -= float(spire_height * spire_height) * 4000.0

	# 7. Stack Height Penalties
	var stack_height = _get_stack_height(sim_grid, width, height)
	if stack_height > 10:
		var over_h = stack_height - 10
		score -= float(over_h * over_h) * 3000.0

	var landing_height = height - pos.y
	score -= float(landing_height) * 10.0

	return score

func _evaluate_reachability(engine: TetrisEngine, p_type: String, start_pos: Vector2i, start_rot: int, target_pos: Vector2i, target_rot: int, drop_y: int, is_hold: bool) -> Dictionary:
	# Direct vertical shaft fast-path.
	# IMPORTANT: only valid when no rotation is required. This shortcut never
	# checks kick legality, so if a rotation is needed we MUST fall through to
	# the full BFS below (which validates every rotation step against the
	# real kick table) instead of just assuming "rotate then slide" is free.
	# Skipping this check was letting the bot approve placements it could not
	# actually execute, which is what made soft-dropped pieces stall short of
	# their planned destination.
	if target_pos.y == drop_y and start_rot == target_rot:
		var target_offsets = _get_state_offsets_for_bot(engine, p_type, target_rot, is_hold)
		if not target_offsets.is_empty():
			var dir = 1 if target_pos.x > start_pos.x else -1
			var curr_x = start_pos.x
			var clear_path := true
			
			while true:
				if not _can_fit_raw(engine.grid, engine.width, engine.height, target_offsets, Vector2i(curr_x, start_pos.y)):
					clear_path = false
					break
				if curr_x == target_pos.x: break
				curr_x += dir

			if clear_path:
				var path_nodes: Array[Vector3i] = [
					Vector3i(start_pos.x, start_pos.y, start_rot),
					Vector3i(target_pos.x, start_pos.y, target_rot),
					Vector3i(target_pos.x, target_pos.y, target_rot)
				]
				return {"reachable": true, "path": path_nodes}

	# Translate-only search, tried whenever the placement doesn't actually
	# require a different final rotation (this covers tucks/slides under
	# overhangs, which is most of what falls through the fast path above
	# since it only handles target_pos.y == drop_y).
	# IMPORTANT: without this, every such placement went straight to the full
	# (x, y, rot) BFS below. In that search a rotation+kick is just one more
	# step, same cost as a single-cell slide -- but a kick can shift the
	# piece sideways by MORE than one cell in that one step. So whenever a
	# direct horizontal slide was blocked, BFS would happily "discover" a
	# cheaper route by rotating out, riding the kick sideways, then rotating
	# back to the original rotation -- a real, executable path, but one that
	# spins the piece for no reason since it ends at the same rotation it
	# started at. Trying translation-only first eliminates that noise for
	# every placement that doesn't genuinely need a rotation, while still
	# falling back to the full BFS for placements where target_rot differs
	# from start_rot, or where rotation truly is the only way in.
	if start_rot == target_rot:
		var translate_result = _is_reachable_translation_only(engine, p_type, start_pos, target_pos, target_rot, is_hold)
		if translate_result["reachable"]:
			return translate_result
	else:
		# Rotate-first search: try rotating in place at start_pos BEFORE moving
		# at all, then glide to target_pos with no further rotation needed.
		# This is the "convenient" ordering -- it's how a human would play,
		# and every action here happens while the piece is still up near
		# spawn, nowhere near the stack. It matters because the piece is
		# grounded (touching the stack, engine.is_grounded() true) for most
		# of a tuck's descent, and every action taken while grounded resets
		# the engine's lock delay timer. The full BFS below doesn't know or
		# care where the piece is grounded -- it just finds *a* shortest
		# path, which can and does land rotations mid-descent, while
		# grounded, purely because that happened to tie for fewest actions.
		# Repeated grounded resets can force an unintended early lock before
		# the piece reaches its planned spot. Trying this ordering first
		# means rotation, when needed, happens once, immediately, while
		# fully elevated -- and only falls through to the interleaved BFS
		# when rotating that early genuinely doesn't fit (true spin-drops).
		var rotate_first = _try_rotate_first_then_translate(engine, p_type, start_pos, start_rot, target_pos, target_rot, is_hold)
		if rotate_first["reachable"]:
			return rotate_first

	return _is_reachable_bfs(engine, p_type, start_pos, start_rot, target_pos, target_rot, is_hold)

func _try_rotate_first_then_translate(engine: TetrisEngine, p_type: String, start_pos: Vector2i, start_rot: int, target_pos: Vector2i, target_rot: int, is_hold: bool) -> Dictionary:
	var target_offsets = _get_state_offsets_for_bot(engine, p_type, target_rot, is_hold)
	if target_offsets.is_empty():
		return {"reachable": false, "path": []}

	# Only trust a kick-free, in-place rotation here -- if the piece doesn't
	# fit at start_pos in its target orientation without any kick offset,
	# don't guess at which kick the engine's rotate_piece() would resolve to;
	# fall through to the full BFS, which validates real kicks step by step.
	if not _can_fit_raw(engine.grid, engine.width, engine.height, target_offsets, start_pos):
		return {"reachable": false, "path": []}

	var translate_result = _is_reachable_translation_only(engine, p_type, start_pos, target_pos, target_rot, is_hold)
	if not translate_result["reachable"]:
		return {"reachable": false, "path": []}

	var path: Array[Vector3i] = [Vector3i(start_pos.x, start_pos.y, start_rot)]
	path.append_array(translate_result["path"])
	return {"reachable": true, "path": path}

func _is_reachable_translation_only(engine: TetrisEngine, p_type: String, start_pos: Vector2i, target_pos: Vector2i, rot: int, is_hold: bool) -> Dictionary:
	var offsets = _get_state_offsets_for_bot(engine, p_type, rot, is_hold)
	if offsets.is_empty():
		return {"reachable": false, "path": []}

	var visited := {}
	var parents := {}
	var start_key = ((start_pos.y + 5) << 8) | (start_pos.x + 5)
	visited[start_key] = true

	var queue: Array[Vector2i] = [start_pos]
	var queue_idx = 0
	var iterations = 0
	var max_iterations = 800
	var target_key = -1

	while queue_idx < queue.size() and iterations < max_iterations:
		iterations += 1
		var curr = queue[queue_idx]
		queue_idx += 1
		var curr_key = ((curr.y + 5) << 8) | (curr.x + 5)

		if curr == target_pos:
			target_key = curr_key
			break

		for dir in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
			var next_pos = curr + dir
			var key = ((next_pos.y + 5) << 8) | (next_pos.x + 5)
			if not visited.has(key):
				if _can_fit_raw(engine.grid, engine.width, engine.height, offsets, next_pos):
					visited[key] = true
					parents[key] = curr_key
					queue.append(next_pos)

	if target_key == -1:
		return {"reachable": false, "path": []}

	var full_path: Array[Vector3i] = []
	var key_to_pos := {}
	for node in queue:
		var k = ((node.y + 5) << 8) | (node.x + 5)
		key_to_pos[k] = node

	var curr_k = target_key
	while curr_k != start_key:
		if key_to_pos.has(curr_k):
			var p: Vector2i = key_to_pos[curr_k]
			full_path.push_front(Vector3i(p.x, p.y, rot))
		if parents.has(curr_k):
			curr_k = parents[curr_k]
		else:
			break

	full_path.push_front(Vector3i(start_pos.x, start_pos.y, rot))
	return {"reachable": true, "path": full_path}

func _is_reachable_bfs(engine: TetrisEngine, p_type: String, start_pos: Vector2i, start_rot: int, target_pos: Vector2i, target_rot: int, is_hold: bool) -> Dictionary:
	var visited := {}
	var parents := {}
	
	var start_state = Vector3i(start_pos.x, start_pos.y, start_rot)
	var start_key = (start_rot << 16) | ((start_pos.y + 5) << 8) | (start_pos.x + 5)
	visited[start_key] = true

	var queue: Array[Vector3i] = [start_state]
	var kick_table = engine.pieces_controller.get_kick_table(p_type)
	var queue_idx = 0
	var iterations = 0
	var max_iterations = 800
	var target_key = -1

	while queue_idx < queue.size() and iterations < max_iterations:
		iterations += 1
		var curr = queue[queue_idx]
		queue_idx += 1

		if curr.x == target_pos.x and curr.y == target_pos.y and curr.z == target_rot:
			target_key = (curr.z << 16) | ((curr.y + 5) << 8) | (curr.x + 5)
			break

		var c_pos = Vector2i(curr.x, curr.y)
		var c_rot = curr.z
		var curr_key = (c_rot << 16) | ((c_pos.y + 5) << 8) | (c_pos.x + 5)

		for dir in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]:
			var next_pos = c_pos + dir
			var key = (c_rot << 16) | ((next_pos.y + 5) << 8) | (next_pos.x + 5)
			if not visited.has(key):
				# c_rot only still matches the piece's true live shape while
				# it equals start_rot (i.e. before any rotation happened
				# along this path) -- see _get_state_offsets_for_bot.
				var offsets = _get_state_offsets_for_bot(engine, p_type, c_rot, is_hold) if c_rot == start_rot else engine.pieces_controller.get_state_offsets(p_type, c_rot)
				if _can_fit_raw(engine.grid, engine.width, engine.height, offsets, next_pos):
					visited[key] = true
					parents[key] = curr_key
					queue.append(Vector3i(next_pos.x, next_pos.y, c_rot))

		for rot_dir in [1, -1]:
			var next_rot = posmod(c_rot + rot_dir, 4)
			var kicks = _get_kicks(kick_table, p_type, c_rot, next_rot)
			var next_offsets = engine.pieces_controller.get_state_offsets(p_type, next_rot)

			for kick in kicks:
				var kicked_pos = c_pos + kick
				var key = (next_rot << 16) | ((kicked_pos.y + 5) << 8) | (kicked_pos.x + 5)
				if not visited.has(key):
					if _can_fit_raw(engine.grid, engine.width, engine.height, next_offsets, kicked_pos):
						visited[key] = true
						parents[key] = curr_key
						queue.append(Vector3i(kicked_pos.x, kicked_pos.y, next_rot))
						break

	if target_key == -1:
		return {"reachable": false, "path": []}

	# Reconstruct exact step-by-step path
	var full_path: Array[Vector3i] = []
	var curr_k = target_key
	var key_to_state := {}
	for node in queue:
		var k = (node.z << 16) | ((node.y + 5) << 8) | (node.x + 5)
		key_to_state[k] = node

	while curr_k != start_key:
		if key_to_state.has(curr_k):
			full_path.push_front(key_to_state[curr_k])
		if parents.has(curr_k):
			curr_k = parents[curr_k]
		else: break
			
	full_path.push_front(start_state)
	return {"reachable": true, "path": full_path}

func _find_best_well(col_heights: Array[int], width: int) -> int:
	var best_well = width - 1
	var max_depth = 0
	for c in range(width):
		var left_h = col_heights[c - 1] if c > 0 else col_heights[c] + 3
		var right_h = col_heights[c + 1] if c < width - 1 else col_heights[c] + 3
		var relative_depth = min(left_h, right_h) - col_heights[c]
		if relative_depth > max_depth:
			max_depth = relative_depth
			best_well = c
	return best_well

func _count_tspin_slots(grid: Array, width: int, height: int) -> int:
	var count: int = 0
	for r in range(1, height - 1):
		for c in range(0, width - 2):
			var f0 = (r + 1 >= height) or (grid[r + 1][c] != -1)
			var f1 = (r + 1 >= height) or (grid[r + 1][c + 1] != -1)
			var f2 = (r + 1 >= height) or (grid[r + 1][c + 2] != -1)
			if not (f0 and f1 and f2): continue

			if grid[r][c] != -1 or grid[r][c + 1] != -1 or grid[r][c + 2] != -1: continue
			if r - 1 < 0 or grid[r - 1][c + 1] != -1: continue

			var left_overhang = (grid[r - 1][c] != -1)
			var right_overhang = (grid[r - 1][c + 2] != -1)

			if (left_overhang and not right_overhang) or (right_overhang and not left_overhang):
				var corners = [Vector2i(c, r - 1), Vector2i(c + 2, r - 1), Vector2i(c, r + 1), Vector2i(c + 2, r + 1)]
				var occupied = 0
				for corner in corners:
					if corner.x < 0 or corner.x >= width or corner.y >= height or (corner.y >= 0 and grid[corner.y][corner.x] != -1):
						occupied += 1
				if occupied >= 3: count += 1
	return count

func _is_all_spin(grid: Array, width: int, height: int, offsets: Array[Vector2i], pos: Vector2i, p_type: String) -> bool:
	# General ("all-spin") placement test for J/L/S/Z/I -- mirrors
	# TetrisEngine._check_all_spin()'s immobility rule so the bot's
	# candidate scoring agrees with what the engine will actually reward
	# with garbage. T and O are excluded: T has its own 3-corner rule
	# above, and O never changes footprint on rotation so it can't spin.
	if p_type == "T" or p_type == "O": return false

	# If the piece could simply have dropped straight down into this cell,
	# it isn't a spin -- it's just a normal placement that happens to sit
	# under an overhang.
	if _can_fit_raw(grid, width, height, offsets, pos + Vector2i(0, -1)): return false
	if _can_fit_raw(grid, width, height, offsets, pos + Vector2i(-1, 0)): return false
	if _can_fit_raw(grid, width, height, offsets, pos + Vector2i(1, 0)): return false
	if _can_fit_raw(grid, width, height, offsets, pos + Vector2i(0, 1)): return false
	return true

func _count_all_spin_slots(grid: Array, width: int, height: int) -> int:
	# Approximate count of "spin-friendly" pockets for J/L/S/Z/I: a single
	# empty cell that's covered by an overhang above, supported below, and
	# walled on at least one side -- the shape of notch those pieces can
	# rotate into (a hook for J/L, a cave for S/Z). This is deliberately a
	# looser, cheaper proxy than the exact T-spin slot geometry below,
	# since J/L/S/Z each fit differently-shaped notches; it's enough to
	# steer the bot toward building coverable terrain for skims instead of
	# always flat-stacking, without hand-modeling every piece's spin shape.
	var count: int = 0
	for r in range(1, height - 1):
		for c in range(0, width):
			if grid[r][c] != -1: continue
			if grid[r - 1][c] == -1: continue
			var supported = (r + 1 >= height) or (grid[r + 1][c] != -1)
			if not supported: continue
			var left_wall = (c == 0) or (grid[r][c - 1] != -1)
			var right_wall = (c == width - 1) or (grid[r][c + 1] != -1)
			if left_wall or right_wall:
				count += 1
	return count

func _is_t_spin(grid: Array, width: int, height: int, offsets: Array[Vector2i], pos: Vector2i, p_type: String) -> bool:
	if p_type != "T": return false
	var center_offset := Vector2i(-1, -1)
	for off in offsets:
		var neighbors = 0
		for n in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			if (off + n) in offsets: neighbors += 1
		if neighbors == 3:
			center_offset = off
			break

	if center_offset == Vector2i(-1, -1): return false
	var center = pos + center_offset
	var corners = [center + Vector2i(-1, -1), center + Vector2i(1, -1), center + Vector2i(-1, 1), center + Vector2i(1, 1)]

	var occupied = 0
	for c in corners:
		if c.x < 0 or c.x >= width or c.y >= height or (c.y >= 0 and grid[c.y][c.x] != -1):
			occupied += 1

	if occupied < 3: return false
	if _can_fit_raw(grid, width, height, offsets, pos + Vector2i(0, -1)): return false
	return true

func _search_recursive(engine: TetrisEngine, grid: Array, queue: Array[String], queue_idx: int, beam_width: int) -> float:
	if queue_idx >= queue.size(): return 0.0
	var piece_type = queue[queue_idx]
	var candidates = _get_simulated_candidates(grid, engine.width, engine.height, piece_type, beam_width, engine)
	if candidates.is_empty(): return -999999.0

	var best_score: float = -9999999.0
	for cand in candidates:
		var score = cand["score"]
		if queue_idx + 1 < queue.size():
			var next_score = _search_recursive(engine, cand["grid"], queue, queue_idx + 1, beam_width)
			score = -999999.0 if next_score <= -900000.0 else score + next_score
		if score > best_score: best_score = score
	return best_score

func _get_simulated_candidates(grid: Array, width: int, height: int, piece_type: String, beam_width: int, engine: TetrisEngine) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	var max_rots: int = 1 if piece_type == "O" else (2 if piece_type in ["I", "S", "Z"] else 4)

	for rot in range(max_rots):
		var offsets = engine.pieces_controller.get_state_offsets(piece_type, rot)
		if offsets.is_empty(): continue
		for x in range(-2, width + 2):
			var drop_y = _get_drop_y_raw(grid, width, height, offsets, x)
			if drop_y == -1: continue
			var pos = Vector2i(x, drop_y)
			var sim_res = _simulate_grid_and_count(grid, width, height, offsets, pos)
			var score = _evaluate_placement(grid, width, height, sim_res["grid"], sim_res["lines"], offsets, pos, piece_type, rot)
			candidates.append({"score": score, "grid": sim_res["grid"]})

	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	if candidates.size() > beam_width: return candidates.slice(0, beam_width)
	return candidates

func _get_state_offsets_for_bot(engine: TetrisEngine, p_type: String, rot: int, is_hold: bool) -> Array[Vector2i]:
	# TetrisEngine.spawn_piece() builds active_offsets from its OWN
	# ascii/pivot parser (loaded_shapes). rotate_piece() only re-syncs
	# active_offsets from pieces_controller.get_state_offsets() the moment a
	# piece actually rotates. Until that first rotation happens, the two
	# shape tables can disagree -- even by a single row -- and the O piece
	# NEVER rotates (rotate_piece() early-returns for "O"), so it stays on
	# the engine's own shape for its entire lifetime. Since the bot plans
	# everything else against pieces_controller, that mismatch was enough to
	# make the bot land the O piece one tile short of where it could
	# actually go.
	# For the live active (non-hold) piece, at its current, not-yet-rotated
	# state, trust engine.active_offsets directly -- that's the real
	# collision authority the engine will use, not pieces_controller's copy.
	if not is_hold and rot == engine.rotation_state:
		return engine.active_offsets
	return engine.pieces_controller.get_state_offsets(p_type, rot)

func _get_kicks(kick_table, p_type: String, from_rot: int, to_rot: int) -> Array:
	var key_str = "%d->%d" % [from_rot, to_rot]
	if kick_table is Dictionary and kick_table.has(key_str):
		return kick_table[key_str]
	# MUST mirror TetrisEngine.rotate_piece()'s fallback exactly. The engine
	# falls back to a single zero-offset kick when a transition is missing
	# from the table, not the full SRS kick set. If this fallback is richer
	# than the engine's, the BFS can "discover" a rotation via a wall/floor
	# kick that the engine will never actually try, producing a plan that
	# looks reachable but fails (or lands somewhere different) at execution
	# time.
	return [Vector2i.ZERO]

func _get_bumpiness(col_heights: Array[int], width: int, exclude_col: int) -> int:
	var bumpiness: int = 0
	for c in range(width - 1):
		if c == exclude_col or (c + 1) == exclude_col: continue
		bumpiness += abs(col_heights[c] - col_heights[c + 1])
	return bumpiness

func _get_column_heights(grid: Array, width: int, height: int) -> Array[int]:
	var col_heights: Array[int] = []
	col_heights.resize(width)
	for c in range(width):
		var h = 0
		for r in range(height):
			if grid[r][c] != -1:
				h = height - r
				break
		col_heights[c] = h
	return col_heights

func _count_holes(grid: Array, width: int, height: int) -> int:
	var holes: int = 0
	for c in range(width):
		var found_block := false
		for r in range(height):
			if grid[r][c] != -1: found_block = true
			elif found_block: holes += 1
	return holes

func _count_blockades(grid: Array, width: int, height: int) -> int:
	var count: int = 0
	for c in range(width):
		var blocks_above: int = 0
		for r in range(height):
			if grid[r][c] != -1: blocks_above += 1
			else: count += blocks_above
	return count

func _get_stack_height(grid: Array, width: int, height: int) -> int:
	for r in range(height):
		for c in range(width):
			if grid[r][c] != -1: return height - r
	return 0

func _get_drop_y(engine: TetrisEngine, offsets: Array[Vector2i], x: int) -> int:
	return _get_drop_y_raw(engine.grid, engine.width, engine.height, offsets, x)

func _get_drop_y_raw(grid: Array, width: int, height: int, offsets: Array[Vector2i], x: int) -> int:
	var y = 0
	if not _can_fit_raw(grid, width, height, offsets, Vector2i(x, y)): return -1
	while _can_fit_raw(grid, width, height, offsets, Vector2i(x, y + 1)): y += 1
	return y

func _can_fit_raw(grid: Array, width: int, height: int, offsets: Array[Vector2i], origin: Vector2i) -> bool:
	for offset in offsets:
		var cell = origin + offset
		# Boundary check
		if cell.x < 0 or cell.x >= width or cell.y >= height:
			return false
		# Grid collision check
		if cell.y >= 0 and grid[cell.y][cell.x] != -1:
			return false
	return true

func _simulate_grid_and_count(base_grid: Array, width: int, height: int, offsets: Array[Vector2i], pos: Vector2i) -> Dictionary:
	var grid_copy: Array = []
	for row in base_grid: grid_copy.append(row.duplicate())
	for offset in offsets:
		var cell = pos + offset
		if cell.y >= 0 and cell.y < height and cell.x >= 0 and cell.x < width:
			grid_copy[cell.y][cell.x] = 1

	var lines_cleared: int = 0
	var r = height - 1
	while r >= 0:
		if not -1 in grid_copy[r]:
			lines_cleared += 1
			grid_copy.remove_at(r)
			var empty_row: Array = []
			empty_row.resize(width)
			empty_row.fill(-1)
			grid_copy.push_front(empty_row)
		else: r -= 1

	return {"grid": grid_copy, "lines": lines_cleared}
