extends Control
@onready var hbox: HBoxContainer = $HBoxContainer

@export var slow_down: bool = false:
	set(val):
		slow_down = val
		_apply_speed_settings()

var players = {}

func _ready() -> void:
	# 1. Dynamically register and setup all boards in HBoxContainer
	var boards: Array[Board] = []
	for child in hbox.get_children():
		if child is Board:
			boards.append(child)
			players[child.player_id] = child

	# 2. Auto-link opponent_board references for 1v1 battle pairs if not set
	if boards.size() == 2:
		if boards[0].opponent_board == null:
			boards[0].opponent_board = boards[1]
		if boards[1].opponent_board == null:
			boards[1].opponent_board = boards[0]

	EventBus.player_topped_out.connect(_on_player_topped_out)
	_apply_speed_settings()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		# Press Tab or T to toggle slow-down mode at runtime
		if event.keycode == KEY_TAB or event.keycode == KEY_T:
			slow_down = not slow_down
			print("[TEST SCENE] Slow Down toggled -> %s" % ("ON (Watching Gameplay)" if slow_down else "OFF (Fast Generation)"))
			accept_event()

func _apply_speed_settings() -> void:
	if not is_inside_tree() or not is_node_ready():
		return

	var container = get_node_or_null("HBoxContainer")
	if container != null:
		for child in container.get_children():
			if child is HeuristicDataGenerator:
				child.slow_down = slow_down
			elif child is OnnxBotBoard:
				child.debug_slow_mode = slow_down

	Engine.time_scale = 1.0 if slow_down else 20.0

func _on_player_topped_out(victim_id: int, _attacker_id: int) -> void:
	# Only execute visual delay reset if slow_down is active; in fast mode, generator boards reset themselves immediately
	if not slow_down:
		return

	var victim_board: Board = players.get(victim_id)
	if victim_board != null:
		await get_tree().create_timer(1.5).timeout
		if slow_down and victim_board.is_topped_out():
			victim_board.reset()
