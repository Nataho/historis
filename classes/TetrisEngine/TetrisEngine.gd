class_name TetrisEngine extends RefCounted

signal board_updated(grid_matrix: Array)
signal active_piece_moved(piece_cells: Array[Vector2i], piece_type: int)
signal lines_cleared(line_count: int, combo_count: int)

# Garbage is always sent as an array of "chunks": [{lines:int, hole_column:int}, ...]
# Each chunk represents one attack event (one non-clearing... one clearing placement),
# each with its own randomized hole column. This is what lets two consecutive quads
# arrive as two separate 4-line chunks with different hole columns instead of merging
# into a single misaligned column that's trivial to counter.
signal garbage_sent(chunks: Array)
signal garbage_received(pending_total: int)
signal garbage_applied(rows_added: int)
signal queue_changed(next_pieces: Array[String])
signal hold_changed(piece_key: String)
signal game_over

signal hard_dropped

const LOCK_DELAY_MS: float = 500.0  # 0.5 seconds ground lock delay
const MAX_LOCK_RESETS: int = 15      # Max move/rotation resets on ground
const PIECE_ORDER: Array[String] = ["Z", "L", "O", "S", "I", "J", "T"]

# --- GARBAGE ---
const GARBAGE_TILE_INDEX: int = 9 # Reserved atlas index for garbage tiles (0-6 are pieces, -1 empty)
const GARBAGE_NETWORK_DELAY_MS: float = 500.0 # 0.5s travel time before a receiver becomes aware of incoming garbage
const GARBAGE_ROW_INTERVAL_MS: float = 100.0 # 0.1s per row when rising gradually

const GARBAGE_BASE_TABLE: Dictionary = {
	1: 0, 2: 1, 3: 2, 4: 4
}
const GARBAGE_TSPIN_TABLE: Dictionary = {
	1: 2, 2: 4, 3: 6
}

var width: int
var height: int
var grid: Array = []

var loaded_shapes: Dictionary = {}
var piece_indices: Dictionary = {}
var pieces_controller: PiecesController

var active_piece_type: String = ""
var active_piece_index: int = -1
var active_offsets: Array[Vector2i] = []
var active_pos: Vector2i = Vector2i.ZERO

var bag: Array[String] = []
var queue: Array[String] = []
var preview_count: int = 5
var combo_count: int = -1

var pending_garbage: Array = [] # queued incoming chunks: [{lines:int, hole_column:int}, ...], not yet claimed for rising

# Toggle: true = dump all pending garbage into the grid at once (old behavior).
# false (default) = rise 1 row every GARBAGE_ROW_INTERVAL_MS (0.1s), ticked via process_garbage().
var instant_garbage: bool = false

var _garbage_drain_queue: Array = [] # flattened hole_columns, one entry per row still left to rise
var _garbage_drain_timer_ms: float = 0.0

var hold_piece_type: String = ""
var can_hold: bool = true
var rotation_state: int = 0
var last_move_was_rotate: bool = false

# --- LOCK DELAY TRACKERS ---
var lock_timer: float = 0.0
var lock_resets: int = 0
var lowest_y: int = 0

func _init(board_width: int = 10, board_height: int = 20, preview_size: int = 5) -> void:
	width = board_width
	height = board_height
	preview_count = preview_size
	_reset_grid()

func load_piece_definitions(json_data: Dictionary) -> void:
	loaded_shapes.clear()
	piece_indices.clear()
	
	# Build a case-insensitive map for JSON key lookups
	var normalized_json := {}
	for k in json_data.keys():
		normalized_json[str(k).to_upper()] = json_data[k]

	# Lock atlas X-coordinates 0..6 from Left to Right
	for idx in range(PIECE_ORDER.size()):
		var piece_key: String = PIECE_ORDER[idx]
		piece_indices[piece_key] = idx
		
		if normalized_json.has(piece_key):
			loaded_shapes[piece_key] = _parse_ascii_grid(normalized_json[piece_key])
		elif json_data.has(piece_key):
			loaded_shapes[piece_key] = _parse_ascii_grid(json_data[piece_key])

	# Parse any extra keys if present
	for k in json_data:
		var key_str := str(k).to_upper()
		if not piece_indices.has(key_str) and not piece_indices.has(k):
			piece_indices[k] = piece_indices.size()
			loaded_shapes[k] = _parse_ascii_grid(json_data[k])

func _parse_ascii_grid(ascii_grid: Array) -> Array[Vector2i]:
	var offsets: Array[Vector2i] = []
	var pivot := Vector2i(-1, -1)
	
	for y in range(ascii_grid.size()):
		var row: String = ascii_grid[y]
		for x in range(row.length()):
			if row[x] == 'x':
				pivot = Vector2i(x, y)
				break
		if pivot != Vector2i(-1, -1): break
			
	if pivot == Vector2i(-1, -1): pivot = Vector2i.ZERO

	for y in range(ascii_grid.size()):
		var row: String = ascii_grid[y]
		for x in range(row.length()):
			if row[x] == '*' or row[x] == 'x':
				offsets.append(Vector2i(x - pivot.x, y - pivot.y))
				
	return offsets

func _reset_grid() -> void:
	grid.clear()
	for y in range(height):
		var row: Array = []
		row.resize(width)
		row.fill(-1)
		grid.append(row)

func start_game() -> void:
	_reset_grid()
	combo_count = -1
	bag.clear()
	queue.clear()
	pending_garbage.clear()
	_garbage_drain_queue.clear()
	_garbage_drain_timer_ms = 0.0
	hold_piece_type = ""
	can_hold = true
	board_updated.emit(grid)
	
	_refill_queue()
	spawn_piece()

func _generate_bag() -> Array[String]:
	var new_bag: Array[String] = []
	for key in loaded_shapes.keys():
		new_bag.append(key)
	new_bag.shuffle()
	return new_bag

func _refill_queue() -> void:
	if loaded_shapes.is_empty():
		push_error("TetrisEngine: Cannot refill queue, loaded_shapes is empty! Check piece JSON keys.")
		return

	while queue.size() < preview_count + 7:
		if bag.is_empty():
			bag = _generate_bag()
			if bag.is_empty():
				push_error("TetrisEngine: Failed to generate bag from loaded_shapes!")
				break

		var next_piece: Variant = bag.pop_front()
		if next_piece != null:
			queue.append(str(next_piece))

func spawn_piece() -> void:
	if loaded_shapes.is_empty():
		push_error("TetrisEngine: No piece definitions loaded! Call load_piece_definitions() first.")
		return
		
	_refill_queue()
	active_piece_type = queue.pop_front()
	active_piece_index = piece_indices.get(active_piece_type, 0)
	
	active_offsets.clear()
	for offset in loaded_shapes[active_piece_type]:
		active_offsets.append(offset)
		
	active_pos = Vector2i(width / 2 - 1, 1)
	rotation_state = 0
	last_move_was_rotate = false
	
	# Reset Lock Delay trackers on spawn
	lock_timer = 0.0
	lock_resets = 0
	lowest_y = active_pos.y
	
	queue_changed.emit(queue.slice(0, preview_count))
	
	if not _can_fit(active_offsets, active_pos):
		game_over.emit()
		return
		
	_emit_active_piece()

# --- GROUND DETECTION & LOCK DELAY LOGIC ---

func is_grounded() -> bool:
	return not _can_fit(active_offsets, active_pos + Vector2i.DOWN)

func process_lock_delay(delta_ms: float) -> void:
	if is_grounded():
		lock_timer += delta_ms
		if lock_timer >= LOCK_DELAY_MS:
			lock_piece()
	else:
		lock_timer = 0.0

func _on_piece_manipulated() -> void:
	# If piece dropped lower than ever before, reset lock limit counter
	if active_pos.y > lowest_y:
		lowest_y = active_pos.y
		lock_resets = 0

	# 15-reset cap while on ground
	if is_grounded():
		if lock_resets < MAX_LOCK_RESETS:
			lock_resets += 1
			lock_timer = 0.0  # Reset 0.5s timer

func move_piece(direction: Vector2i) -> bool:
	var target_pos: Vector2i = active_pos + direction
	
	if _can_fit(active_offsets, target_pos):
		active_pos = target_pos
		last_move_was_rotate = false
		_on_piece_manipulated()
		_emit_active_piece()
		return true
		
	return false

func soft_drop() -> void:
	if not move_piece(Vector2i.DOWN):
		# Grounded: process_lock_delay handles timing out instead of locking instantly
		pass

func hard_drop() -> void:
	var dropped_steps = 0
	while move_piece(Vector2i.DOWN):
		dropped_steps += 1
	
	# Preserve rotation status if piece was already grounded when rotated
	if dropped_steps == 0:
		pass 
	
	hard_dropped.emit()
	lock_piece()

func rotate_piece(clockwise: bool, kick_table: Dictionary) -> bool:
	if active_piece_type.to_upper() == "O": 
		return true

	var old_state: int = rotation_state
	var new_state: int = (rotation_state + (1 if clockwise else -1)) % 4
	if new_state < 0: 
		new_state += 4

	var target_offsets: Array[Vector2i] = []
	if pieces_controller != null:
		target_offsets = pieces_controller.get_state_offsets(active_piece_type, new_state)

	if target_offsets.is_empty():
		return false

	var transition_key: String = str(old_state) + "->" + str(new_state)
	var kicks: Array = kick_table.get(transition_key, [Vector2i.ZERO])

	for kick in kicks:
		var test_pos: Vector2i = active_pos + kick
		if _can_fit(target_offsets, test_pos):
			active_offsets = target_offsets
			active_pos = test_pos
			rotation_state = new_state
			last_move_was_rotate = true
			_on_piece_manipulated()
			_emit_active_piece()
			return true

	return false

func rotate_180(kick_table: Dictionary) -> bool:
	if active_piece_type.to_upper() == "O": 
		return true

	var old_state: int = rotation_state
	var new_state: int = (rotation_state + 2) % 4

	# 1. Fetch exact SRS state shape offsets for new_state (180 deg flip)
	var target_offsets: Array[Vector2i] = []
	if pieces_controller != null:
		target_offsets = pieces_controller.get_state_offsets(active_piece_type, new_state)

	if target_offsets.is_empty():
		return false

	# 2. Fetch transition kick vectors (e.g., "0->2", "1->3")
	var transition_key: String = str(old_state) + "->" + str(new_state)
	var kicks: Array = kick_table.get(transition_key, [Vector2i.ZERO])

	# 3. Test kicks sequentially
	for kick in kicks:
		var test_pos: Vector2i = active_pos + kick
		if _can_fit(target_offsets, test_pos):
			active_offsets = target_offsets
			active_pos = test_pos
			rotation_state = new_state
			last_move_was_rotate = true
			_on_piece_manipulated()
			_emit_active_piece()
			return true

	return false

func _can_fit(offsets: Array[Vector2i], origin: Vector2i) -> bool:
	for offset in offsets:
		var cell = origin + offset
		if cell.x < 0 or cell.x >= width or cell.y < 0 or cell.y >= height:
			return false
		if grid[cell.y][cell.x] != -1:
			return false
	return true

func _check_t_spin() -> bool:
	if active_piece_type.to_upper() != "T" or not last_move_was_rotate:
		return false
	
	# 3-Corner Rule check for T-Spin around center
	var corners = [
		active_pos + Vector2i(-1, -1),
		active_pos + Vector2i(1, -1),
		active_pos + Vector2i(-1, 1),
		active_pos + Vector2i(1, 1)
	]
	
	var occupied_corners: int = 0
	for corner in corners:
		if corner.x < 0 or corner.x >= width or corner.y < 0 or corner.y >= height:
			occupied_corners += 1
		elif grid[corner.y][corner.x] != -1:
			occupied_corners += 1

	return occupied_corners >= 3

func _check_all_spin() -> bool:
	# General ("all-spin") immobility rule for non-T pieces (J, L, S, Z, I).
	# Unlike the T-piece's 3-corner rule, these pieces don't pivot around a
	# fixed center cell, so the standard test guideline engines use instead
	# is: the last input was a rotation, AND the piece is now completely
	# wedged -- it cannot slide left, cannot slide right, and cannot drop
	# any further. If any of those three moves is still open, the piece
	# could simply have been slid/dropped into this spot without spinning,
	# so it doesn't count.
	if active_piece_type.to_upper() == "T": return false
	if active_piece_type.to_upper() == "O": return false
	if not last_move_was_rotate: return false

	if _can_fit(active_offsets, active_pos + Vector2i(-1, 0)): return false
	if _can_fit(active_offsets, active_pos + Vector2i(1, 0)): return false
	if _can_fit(active_offsets, active_pos + Vector2i(0, 1)): return false
	return true

func lock_piece() -> void:
	var is_tspin: bool = _check_t_spin()
	var is_allspin: bool = false if is_tspin else _check_all_spin()

	for offset in active_offsets:
		var cell = active_pos + offset
		if cell.y >= 0 and cell.y < height and cell.x >= 0 and cell.x < width:
			grid[cell.y][cell.x] = active_piece_index
			
	board_updated.emit(grid)
	_check_line_clears(is_tspin, is_allspin)
	can_hold = true
	spawn_piece()

func _check_line_clears(is_tspin: bool = false, is_allspin: bool = false) -> void:
	var cleared_lines: int = 0
	var y = height - 1
	
	while y >= 0:
		var is_full = true
		for x in range(width):
			if grid[y][x] == -1:
				is_full = false
				break
				
		if is_full:
			cleared_lines += 1
			grid.remove_at(y)
			var empty_row = []
			empty_row.resize(width)
			empty_row.fill(-1)
			grid.insert(0, empty_row)
		else:
			y -= 1

	# Debug logging for line clears, T-Spins, and All-Spins
	var clear_type: String = ""
	
	if is_tspin:
		clear_type += "T-Spin "
	elif is_allspin:
		clear_type += "All-Spin "
	match cleared_lines:
		1: clear_type += "Single"
		2: clear_type += "Double"
		3: clear_type += "Triple"
		4: clear_type += "Quad"
	
	if not clear_type.is_empty():
		print("[DEBUG] Line Clear: ", clear_type)
	elif is_tspin or is_allspin:
		print("[DEBUG] Line Clear: ", "T-Spin Zero" if is_tspin else "All-Spin Zero")
			
	if cleared_lines > 0:
		combo_count += 1
		lines_cleared.emit(cleared_lines, combo_count)
		board_updated.emit(grid)
		
		var base_garbage: int = 0
		if is_tspin or is_allspin:
			# All-spins ride the same attack table as T-spins here -- they're
			# harder to engineer for non-T pieces, so a landed one earns the
			# reward just as much as a T-spin does.
			base_garbage = GARBAGE_TSPIN_TABLE.get(cleared_lines, GARBAGE_BASE_TABLE.get(cleared_lines, 0))
		else:
			base_garbage = GARBAGE_BASE_TABLE.get(cleared_lines, 0)
		
		var total_garbage: int = base_garbage + _get_combo_bonus(combo_count)
		
		if total_garbage > 0:
			var lines_to_send: int = _cancel_garbage(total_garbage)
			if lines_to_send > 0:
				var chunk: Dictionary = {
					"lines": lines_to_send,
					"hole_column": randi() % width
				}
				print("[GARBAGE][ENGINE] sending chunk ", chunk, " (base=", base_garbage, " combo_bonus=", _get_combo_bonus(combo_count), " combo=", combo_count, ", canceled=", total_garbage - lines_to_send, ")")
				garbage_sent.emit([chunk])
			else:
				print("[GARBAGE][ENGINE] attack of ", total_garbage, " fully canceled ready incoming garbage, nothing sent")
		
		# Clearing lines blocks/cancels this turn's incoming garbage from being applied.
	else:
		combo_count = -1
		if not pending_garbage.is_empty():
			print("[GARBAGE][ENGINE] no clear on this placement, applying pending: ", pending_garbage)
		_apply_pending_garbage()

# Logarithmic combo bonus (extra garbage lines on top of the base clear/T-Spin table).
# combo_count is -1 before any clear and 0 on the first clear of a streak, so bonuses
# only kick in from the 2nd consecutive clear (combo_count >= 1) onward.
func _get_combo_bonus(combo: int) -> int:
	if combo <= 0:
		return 0
	return int(floor(log(combo + 1.0) * 1.25))

# Called on a placement that clears zero lines: this is the trigger that lets
# whatever's queued in pending_garbage start hitting the board. Which path it
# takes depends on instant_garbage.
func _apply_pending_garbage() -> void:
	if pending_garbage.is_empty():
		return
	
	if instant_garbage:
		_apply_pending_garbage_instant()
	else:
		_queue_pending_garbage_for_gradual_rise()

# instant_garbage == true: dump every queued chunk into the grid immediately.
# Runs from inside _check_line_clears, before spawn_piece() resets active_pos/
# active_offsets, so there's no "current falling piece" to push here - the piece
# that just locked is already baked into grid and rises with it for free.
func _apply_pending_garbage_instant() -> void:
	var chunks_to_apply: Array = pending_garbage.duplicate(true)
	pending_garbage.clear()
	
	var rows_added: int = 0
	for chunk in chunks_to_apply:
		var lines: int = int(chunk.get("lines", 0))
		var hole_column: int = int(chunk.get("hole_column", 0))
		for i in range(lines):
			_insert_garbage_row(hole_column)
			rows_added += 1
	
	if rows_added > 0:
		print("[GARBAGE][ENGINE][instant] applied ", chunks_to_apply, " -> ", rows_added, " rows added to grid")
		board_updated.emit(grid)
		garbage_applied.emit(rows_added)

# instant_garbage == false: flatten each chunk into individual rows (keeping each
# row's own hole_column) and hand them to the drain queue that process_garbage()
# ticks through, 1 row at a time.
func _queue_pending_garbage_for_gradual_rise() -> void:
	var chunks_to_apply: Array = pending_garbage.duplicate(true)
	pending_garbage.clear()
	
	for chunk in chunks_to_apply:
		var lines: int = int(chunk.get("lines", 0))
		var hole_column: int = int(chunk.get("hole_column", 0))
		for i in range(lines):
			_garbage_drain_queue.append(hole_column)
	
	print("[GARBAGE][ENGINE][gradual] queued ", chunks_to_apply, " -> ", _garbage_drain_queue.size(), " rows total waiting to rise, 1 every ", GARBAGE_ROW_INTERVAL_MS, "ms")

# Call every frame (e.g. from Board._process) with delta in milliseconds. Drains
# _garbage_drain_queue at a steady 1 row per GARBAGE_ROW_INTERVAL_MS, independent
# of piece locks, so the stack visibly climbs while the player keeps playing.
func process_garbage(delta_ms: float) -> void:
	if _garbage_drain_queue.is_empty():
		_garbage_drain_timer_ms = 0.0
		return
	
	_garbage_drain_timer_ms += delta_ms
	while _garbage_drain_timer_ms >= GARBAGE_ROW_INTERVAL_MS and not _garbage_drain_queue.is_empty():
		_garbage_drain_timer_ms -= GARBAGE_ROW_INTERVAL_MS
		var hole_column: int = _garbage_drain_queue.pop_front()
		_rise_one_garbage_row(hole_column)

# Inserts one garbage row and, unlike the instant path, there IS a live falling
# piece to worry about here - so it gets pushed up along with the stack to keep
# its relative position unchanged, instead of the stack rising to meet it.
func _rise_one_garbage_row(hole_column: int) -> void:
	_insert_garbage_row(hole_column) # already emits game_over if a locked row got pushed off the top
	
	# Try to raise the piece with the stack so its height above the floor stays
	# unchanged. If that would push any of its cells above row 0 (there's no
	# hidden buffer zone here), skip the shift for this row instead of forcing
	# it out of bounds. Forcing it out of bounds used to make _can_fit() reject
	# EVERY subsequent move/rotate/drop (any out-of-bounds cell always fails
	# the bounds check), which froze player input on the piece, and then
	# lock_piece() would silently drop the out-of-bounds cells when the lock
	# timer expired - the piece would just vanish instead of locking normally.
	var raised_pos: Vector2i = active_pos + Vector2i.UP
	if _can_fit(active_offsets, raised_pos):
		active_pos = raised_pos
	
	print("[GARBAGE][ENGINE][gradual] rose 1 row (hole_column=", hole_column, ") | ", _garbage_drain_queue.size(), " rows remaining")
	board_updated.emit(grid)
	garbage_applied.emit(1)
	_emit_active_piece()

func get_pending_garbage_total() -> int:
	var total: int = 0
	for chunk in pending_garbage:
		total += int(chunk.get("lines", 0))
	total += _garbage_drain_queue.size()
	return total

# Cancels an outgoing attack against this player's own "ready" incoming garbage
# - anything that hasn't actually landed in the grid yet: unclaimed chunks in
# pending_garbage, plus rows already queued for gradual rise in
# _garbage_drain_queue (queued but not yet inserted). Cancels the
# soonest-to-land rows first (front of the drain queue, then oldest pending
# chunks), since those are the most immediate threat. Returns however much of
# the attack is left after canceling - that's what actually gets sent out.
func _cancel_garbage(attack_lines: int) -> int:
	var remaining_attack: int = attack_lines
	if remaining_attack <= 0:
		return 0

	var canceled_from_queue: int = 0
	while remaining_attack > 0 and not _garbage_drain_queue.is_empty():
		_garbage_drain_queue.pop_front()
		remaining_attack -= 1
		canceled_from_queue += 1

	var canceled_from_pending: int = 0
	while remaining_attack > 0 and not pending_garbage.is_empty():
		var chunk: Dictionary = pending_garbage[0]
		var lines: int = int(chunk.get("lines", 0))
		if lines <= remaining_attack:
			remaining_attack -= lines
			canceled_from_pending += lines
			pending_garbage.pop_front()
		else:
			chunk["lines"] = lines - remaining_attack
			pending_garbage[0] = chunk
			canceled_from_pending += remaining_attack
			remaining_attack = 0

	var total_canceled: int = canceled_from_queue + canceled_from_pending
	if total_canceled > 0:
		print("[GARBAGE][ENGINE] canceled ", total_canceled, " ready incoming lines (", canceled_from_queue, " already rising, ", canceled_from_pending, " still pending) | ", get_pending_garbage_total(), " ready lines remain")
		garbage_received.emit(get_pending_garbage_total())

	return remaining_attack

# Called by the multiplayer layer once the network delay for an incoming attack has
# elapsed. Chunks are appended, preserving each attack's own hole_column.
func queue_garbage(chunks: Array) -> void:
	for chunk in chunks:
		pending_garbage.append(chunk)
	print("[GARBAGE][ENGINE] queued ", chunks, " | pending total now = ", get_pending_garbage_total())
	garbage_received.emit(get_pending_garbage_total())

# Removes the top row (topping the game out if it held any blocks - they got pushed
# off the board) and appends one garbage row at the bottom with a single hole.
func _insert_garbage_row(hole_column: int) -> void:
	var top_row: Array = grid[0]
	var top_row_occupied: bool = false
	for cell in top_row:
		if cell != -1:
			top_row_occupied = true
			break
	
	grid.remove_at(0)
	
	var garbage_row: Array = []
	garbage_row.resize(width)
	garbage_row.fill(GARBAGE_TILE_INDEX)
	if hole_column >= 0 and hole_column < width:
		garbage_row[hole_column] = -1
	grid.append(garbage_row)
	
	if top_row_occupied:
		game_over.emit()

func _emit_active_piece() -> void:
	var world_cells: Array[Vector2i] = []
	for offset in active_offsets:
		world_cells.append(active_pos + offset)
	active_piece_moved.emit(world_cells, active_piece_index)

func get_ghost_position() -> Vector2i:
	var ghost_pos = active_pos
	while _can_fit(active_offsets, ghost_pos + Vector2i.DOWN):
		ghost_pos += Vector2i.DOWN
	return ghost_pos

# Creates a standalone, decoupled copy of just the state TetrisBot needs to plan
# a move: the grid, the active piece, the upcoming queue, and hold state. Every
# TetrisBot helper only ever READS from the engine it's given, never mutates it,
# so handing the bot this snapshot instead of the live engine lets it search on a
# background Thread without ever racing gameplay as it keeps mutating the real
# grid/queue/active piece on the main thread.
# pieces_controller/loaded_shapes/piece_indices are shared by reference rather
# than duplicated - they're read-only lookup tables (piece shapes, kick tables)
# that never change during gameplay, so concurrent reads of them are safe.
func duplicate_snapshot() -> TetrisEngine:
	var copy := TetrisEngine.new(width, height, preview_count)
	copy.pieces_controller = pieces_controller
	copy.loaded_shapes = loaded_shapes
	copy.piece_indices = piece_indices
	
	copy.grid.clear()
	for row in grid:
		copy.grid.append(row.duplicate())
	
	copy.active_piece_type = active_piece_type
	copy.active_piece_index = active_piece_index
	copy.active_offsets = active_offsets.duplicate()
	copy.active_pos = active_pos
	copy.rotation_state = rotation_state
	
	copy.queue = queue.duplicate()
	copy.hold_piece_type = hold_piece_type
	copy.can_hold = can_hold
	copy.combo_count = combo_count
	
	return copy

func hold_active_piece() -> void:
	if not can_hold: return
	
	can_hold = false
	var temp_type = active_piece_type
	
	if hold_piece_type.is_empty():
		hold_piece_type = temp_type
		spawn_piece()
	else:
		active_piece_type = hold_piece_type
		hold_piece_type = temp_type
		active_piece_index = piece_indices.get(active_piece_type, 0)
		
		active_offsets.clear()
		for offset in loaded_shapes[active_piece_type]:
			active_offsets.append(offset)
		active_pos = Vector2i(width / 2 - 1, 1)
		rotation_state = 0
		last_move_was_rotate = false
		
		lock_timer = 0.0
		lock_resets = 0
		lowest_y = active_pos.y
		
		_emit_active_piece()
		
	hold_changed.emit(hold_piece_type)
