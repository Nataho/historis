extends Control

const SLIDE_SPEED: float = 10.0
const DISTANCE: float = 0.25

@onready var p1_anchor: Control = %Player1Anchor
@onready var p2_anchor: Control = %Player2Anchor
@onready var scoreboard: RichTextLabel = %Scoreboard
@onready var p1_name_label: Label = %P1NameLabel
@onready var p2_name_label: Label = %P2NameLabel
@onready var center_banner: RichTextLabel = %CenterBanner
@onready var center_banner_panel: PanelContainer = %CenterBannerPanel
@onready var back_btn: Button = %BackButton

var active_boards: Dictionary = {} # id -> Board
var ready_players: Array = []
var active_players: Dictionary = {}

var p1_id: int = -1
var p2_id: int = -1
var p1_score: int = 0
var p2_score: int = 0

var first_to: int = 3
var current_seed: int = -1
var local_player_id: int = -1
var is_spectator: bool = false
var is_host: bool = false

var game_started: bool = false
var game_finished: bool = false
var is_resetting: bool = false
var match_round: int = 1

func _ready() -> void:
	back_btn.pressed.connect(_on_back_pressed)
	
	EventBus.sync_data.connect(_on_sync_data_received)
	EventBus.received_board_data.connect(_on_board_data_received)
	EventBus.client_left_lobby.connect(_on_player_left_lobby)
	EventBus.client_disconnected.connect(_on_disconnected)
	EventBus.player_topped_out.connect(func(victim_id: int, _attacker_id: int): _on_board_ko(victim_id))
	
	_setup_match()

func _setup_match() -> void:
	local_player_id = GameManager.get_lobby_id()
	is_host = GameManager.network_data.get("is_host", false)
	
	var raw_players = GameManager.match_data.get("players", GameManager.network_data.get("player_list", []))
	var settings = GameManager.match_data.get("settings", {})
	first_to = int(settings.get("first_to", 3))
	current_seed = int(GameManager.match_data.get("seed", randi()))
	
	if raw_players.is_empty():
		raw_players = [
			{"lobby_id": local_player_id, "name": GameManager.get_player_name(), "is_host": is_host}
		]
		
	for p in raw_players:
		var pid = int(p.get("lobby_id", p.get("player_id", -1)))
		active_players[pid] = p
		
	var player_ids = active_players.keys()
	if player_ids.size() >= 1:
		p1_id = player_ids[0]
	if player_ids.size() >= 2:
		p2_id = player_ids[1]
	else:
		p2_id = -2
		
	# Setup names
	var p1_name = active_players.get(p1_id, {}).get("name", "Player 1")
	var p2_name = active_players.get(p2_id, {}).get("name", "Player 2" if p2_id != -2 else "Opponent")
	
	p1_name_label.text = p1_name.to_upper()
	p2_name_label.text = p2_name.to_upper()
	
	p1_name_label.add_theme_color_override("font_color", Palette.RETRO.RED)
	p2_name_label.add_theme_color_override("font_color", Palette.RETRO.BLUE)
	
	_spawn_boards()
	_update_scoreboard()
	_run_intro_sequence()

func _spawn_boards() -> void:
	# Spawn Left Board (P1)
	var is_p1_local = (local_player_id == p1_id)
	var p1_board: Board
	if is_p1_local:
		p1_board = LocalBoard.create(p1_id, p2_id, current_seed)
	else:
		p1_board = NetworkBoard.create(p1_id, p2_id, is_spectator)
	
	p1_board.add_username(active_players.get(p1_id, {}).get("name", "P1"))
	p1_anchor.add_child(p1_board)
	active_boards[p1_id] = p1_board
	print("p1_anchor size: ", p1_anchor.size, " | board size: ", p1_board.size, " | hold_slot size: ", p1_board.hold_slot.size)
		
	# Spawn Right Board (P2)
	if p2_id != -2:
		var is_p2_local = (local_player_id == p2_id)
		var p2_board: Board
		if is_p2_local:
			p2_board = LocalBoard.create(p2_id, p1_id, current_seed)
		else:
			p2_board = NetworkBoard.create(p2_id, p1_id, is_spectator)
			
		p2_board.add_username(active_players.get(p2_id, {}).get("name", "P2"))
		p2_anchor.add_child(p2_board)
		active_boards[p2_id] = p2_board
		
		p1_board.is_battle = true
		p2_board.is_battle = true

func _process(delta: float) -> void:
	var screen_size := get_viewport_rect().size
	var lerp_weight = 1.0 - exp(-SLIDE_SPEED * delta)
	var screen_center = screen_size * 0.5
	
	var p1_target = Vector2(screen_size.x * (0.5 - DISTANCE), screen_center.y)
	var p2_target = Vector2(screen_size.x * (0.5 + DISTANCE), screen_center.y)
	
	if p1_anchor != null:
		p1_anchor.position = p1_anchor.position.lerp(p1_target, lerp_weight)
	if p2_anchor != null:
		p2_anchor.position = p2_anchor.position.lerp(p2_target, lerp_weight)

func _run_intro_sequence() -> void:
	center_banner_panel.show()
	center_banner.text = "[center][wave amp=40 freq=4][color=#FFF1D1]ROUND %d[/color][/wave]\n[color=#00B7CD]MATCH START[/color][/center]" % match_round
	
	Audio.play_music("menu_loop")
	
	await get_tree().create_timer(1.2).timeout
	center_banner_panel.hide()
	
	# Signal ready to server/peers
	var ready_payload = {
		"action": "player_ready",
		"player_id": local_player_id
	}
	
	if is_host:
		_on_player_ready(local_player_id)
	else:
		NetworkSync.sync_data(ready_payload)

func _on_player_ready(pid: int) -> void:
	if not ready_players.has(pid):
		ready_players.append(pid)
		
	# If host, check if all required players are ready
	if is_host:
		var required_count = 2 if (p2_id != -2) else 1
		if ready_players.size() >= required_count:
			ready_players.clear()
			NetworkSync.sync_data({"action": "start_match"})
			_start_countdown()

func _on_sync_data_received(data: Dictionary) -> void:
	var action = data.get("action", "")
	match action:
		"player_ready":
			if is_host:
				_on_player_ready(int(data.get("player_id", -1)))
		"start_match":
			_start_countdown()
		"next_round":
			var next_seed = int(data.get("seed", randi()))
			var scores = data.get("scores", {})
			p1_score = int(scores.get("p1", p1_score))
			p2_score = int(scores.get("p2", p2_score))
			_perform_next_round(next_seed)
		"match_over":
			var winner_id = int(data.get("winner_id", -1))
			var scores = data.get("scores", {})
			p1_score = int(scores.get("p1", p1_score))
			p2_score = int(scores.get("p2", p2_score))
			_perform_match_over(winner_id)

func _start_countdown() -> void:
	if game_started: return
	game_started = true
	is_resetting = false
	
	# Each board runs its own 3-2-1-GO countdown on its tick label.
	# This mirrors the reference: board.start(3) on ALL boards.
	for b in active_boards.values():
		b.start(3)

func _on_board_data_received(payload: Dictionary) -> void:
	var type = payload.get("update_type", "")
	if type == "garbage":
		var attacker_id = int(payload.get("player_id", -1))
		var target_id = int(payload.get("target_id", -1))
		var chunks = payload.get("chunks", [])
		
		var total_lines = 0
		for ch in chunks:
			total_lines += int(ch.get("lines", 1))
			
		_spawn_garbage_visuals(attacker_id, target_id, total_lines)

func _spawn_garbage_visuals(attacker_id: int, target_id: int, amount: int) -> void:
	var attacker_board = active_boards.get(attacker_id)
	var target_board = active_boards.get(target_id)
	
	if attacker_board != null and target_board != null:
		var from_pos = attacker_board.global_position
		var to_pos = target_board.global_position
		AttackParticle.launch(self, from_pos, to_pos, amount)

func _on_board_ko(victim_id: int) -> void:
	if is_resetting or game_finished: return
	
	if not is_host: return
	
	is_resetting = true
	var winner_id = p1_id if victim_id == p2_id else p2_id
	if winner_id == p1_id:
		p1_score += 1
	else:
		p2_score += 1
		
	_update_scoreboard()
	
	if p1_score >= first_to or p2_score >= first_to:
		game_finished = true
		NetworkSync.sync_data({
			"action": "match_over",
			"winner_id": winner_id,
			"scores": {"p1": p1_score, "p2": p2_score}
		})
		_perform_match_over(winner_id)
	else:
		var new_seed = randi()
		NetworkSync.sync_data({
			"action": "next_round",
			"seed": new_seed,
			"scores": {"p1": p1_score, "p2": p2_score}
		})
		_perform_next_round(new_seed)

func _perform_next_round(next_seed: int) -> void:
	is_resetting = true
	match_round += 1
	_update_scoreboard()
	
	center_banner_panel.show()
	center_banner.text = "[center][wave amp=30 freq=4][color=#FFF1D1]ROUND %d[/color][/wave][/center]" % match_round
	
	await get_tree().create_timer(1.2).timeout
	center_banner_panel.hide()
	
	current_seed = next_seed
	for b in active_boards.values():
		b.reset(current_seed)
		
	game_started = false
	_start_countdown()

func _perform_match_over(winner_id: int) -> void:
	game_finished = true
	is_resetting = true
	_update_scoreboard()
	
	for b in active_boards.values():
		b.stop()
		
	var winner_name = active_players.get(winner_id, {}).get("name", "Player")
	center_banner_panel.show()
	center_banner.text = "[center][bounce amp=30 freq=5][color=#FF9100]%s[/color][/bounce]\n[wave amp=40 freq=5][color=#00B7CD]WINS THE MATCH![/color][/wave][/center]" % winner_name.to_upper()
	
	Audio.play_sound("KO")
	
	await get_tree().create_timer(3.5).timeout
	_return_to_lobby()

func _update_scoreboard() -> void:
	var mp = first_to - 1
	var p1_str = "(%d/%d)" % [p1_score, first_to]
	var p2_str = "(%d/%d)" % [p2_score, first_to]
	
	var p1_colored = "[color=#DF301C]%s[/color]" % p1_str
	var p2_colored = "[color=#00B7CD]%s[/color]" % p2_str
	
	if p1_score == mp and p2_score == mp:
		p1_colored = "[shake rate=20 level=8][color=#FF9100]%s[/color][/shake]" % p1_str
		p2_colored = "[shake rate=20 level=8][color=#FF9100]%s[/color][/shake]" % p2_str
	elif p1_score == mp:
		p1_colored = "[bounce amp=15 freq=5][color=#FF9100]%s[/color][/bounce]" % p1_str
	elif p2_score == mp:
		p2_colored = "[bounce amp=15 freq=5][color=#FF9100]%s[/color][/bounce]" % p2_str
		
	scoreboard.text = "[center]%s   [color=#FFF1D1]FT%d[/color]   %s[/center]" % [p1_colored, first_to, p2_colored]

func _on_player_left_lobby(leaving_player: Dictionary) -> void:
	var left_id = int(leaving_player.get("lobby_id", leaving_player.get("player_id", -1)))
	if left_id == p1_id or left_id == p2_id:
		center_banner_panel.show()
		center_banner.text = "[center][color=#DF301C]Opponent disconnected!\nReturning to lobby...[/color][/center]"
		await get_tree().create_timer(2.0).timeout
		_return_to_lobby()

func _on_disconnected() -> void:
	_return_to_lobby()

func _on_back_pressed() -> void:
	_return_to_lobby()

var _is_returning: bool = false

func _return_to_lobby() -> void:
	if _is_returning:
		return
	_is_returning = true
	var tree = get_tree()
	if tree != null:
		tree.change_scene_to_file("res://scenes/game_lobby/game_lobby.tscn")
