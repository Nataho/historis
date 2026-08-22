extends Control

@onready var lobby_title: Label = %LobbyTitle
@onready var room_info_label: Label = %RoomInfoLabel
@onready var players_container: VBoxContainer = %PlayersContainer
@onready var ready_btn: Button = %ReadyButton
@onready var start_btn: Button = %StartButton
@onready var leave_btn: Button = %LeaveButton
@onready var chat_log: RichTextLabel = %ChatLog
@onready var chat_input: LineEdit = %ChatInput
@onready var send_btn: Button = %SendButton

var player_list: Array = []
var is_local_ready: bool = false
var max_players: int = 8

func _ready() -> void:
	Audio.play_music("menu_loop")
	is_local_ready = false
	_setup_ui_for_role()
	_connect_signals()
	_setup_network_session()

func _setup_ui_for_role() -> void:
	var is_host = GameManager.network_data.get("is_host", false)
	start_btn.visible = is_host
	start_btn.disabled = true
	_update_ready_button_visuals()

func _connect_signals() -> void:
	ready_btn.pressed.connect(_on_ready_pressed)
	start_btn.pressed.connect(_on_start_pressed)
	leave_btn.pressed.connect(_on_leave_pressed)
	send_btn.pressed.connect(_on_send_chat_pressed)
	chat_input.text_submitted.connect(func(_text): _on_send_chat_pressed())
	
	EventBus.sync_data.connect(_on_sync_data)
	
	if GameManager.network_data.get("is_host", false):
		EventBus.join_requested.connect(_on_join_requested)
		EventBus.client_left_lobby.connect(_on_client_left_lobby)
	else:
		EventBus.client_disconnected.connect(_on_server_disconnected)

func _setup_network_session() -> void:
	var is_host = GameManager.network_data.get("is_host", false)
	var my_name = GameManager.get_player_name()
	var my_id = GameManager.get_lobby_id()
	
	if is_host:
		lobby_title.text = my_name.to_upper() + "'S LOBBY"
		room_info_label.text = "Role: Host | Max Players: %d" % max_players
		
		player_list = [
			{
				"lobby_id": my_id,
				"name": my_name,
				"is_ready": false,
				"is_host": true
			}
		]
		
		if NetworkSync.server != null:
			for p in NetworkSync.server.active_players:
				var already_in = false
				for existing in player_list:
					if existing.get("lobby_id", -1) == p.get("lobby_id", -2):
						already_in = true
						break
				if not already_in:
					player_list.append({
						"lobby_id": p.get("lobby_id", randi_range(10000, 99999)),
						"name": p.get("name", "Player"),
						"is_ready": p.get("is_ready", false),
						"is_host": false
					})
					
		GameManager.network_data["player_list"] = player_list
		GameManager.network_data["game_status"] = "in_lobby"
		_update_players_ui()
		_broadcast_player_list()
		_add_log("[color=#00B7CD][System] Lobby created. Waiting for players to join...[/color]")
	else:
		lobby_title.text = "MULTIPLAYER LOBBY"
		room_info_label.text = "Role: Client | Connected to Host"
		_add_log("[color=#00B7CD][System] Connected to lobby. Requesting player list...[/color]")
		NetworkSync.sync_data({"type": "request_player_list"})

func _on_sync_data(data: Dictionary) -> void:
	var type = data.get("type", "")
	match type:
		"update_player_list":
			player_list = data.get("player_list", [])
			GameManager.network_data["player_list"] = player_list
			_update_players_ui()
			_check_start_conditions()
		"request_player_list":
			if GameManager.network_data.get("is_host", false):
				_broadcast_player_list()
		"toggle_ready":
			if GameManager.network_data.get("is_host", false):
				var p_id = data.get("lobby_id", -1)
				var p_ready = data.get("is_ready", false)
				_host_set_player_ready(p_id, p_ready)
		"chat_message":
			var sender = data.get("sender", "Unknown")
			var msg = data.get("message", "")
			_add_log("[b]%s:[/b] %s" % [sender, msg])
		"start_game":
			var match_seed = int(data.get("seed", randi()))
			var settings = data.get("settings", {"first_to": 3})
			if data.has("player_list"):
				player_list = data.get("player_list", player_list)
				GameManager.network_data["player_list"] = player_list
			GameManager.match_data = {
				"players": player_list,
				"seed": match_seed,
				"settings": settings
			}
			_start_game_transition()

func _on_join_requested(ws_peer: WebSocketPeer, new_player_data: Dictionary) -> void:
	var joining_name = new_player_data.get("name", "Player").strip_edges()
	var joining_id = new_player_data.get("lobby_id", -1)
	
	if player_list.size() >= max_players:
		if NetworkSync.server != null:
			NetworkSync.server.reject_join(ws_peer, "Lobby is full.")
		return
		
	if joining_id == -1:
		joining_id = randi_range(10000, 99999)
		new_player_data["lobby_id"] = joining_id
		
	if NetworkSync.server != null:
		NetworkSync.server.approve_join(ws_peer, new_player_data)
		
	player_list.append({
		"lobby_id": joining_id,
		"name": joining_name,
		"is_ready": false,
		"is_host": false
	})
	
	_add_log("[color=#FF9100][System] %s joined the lobby.[/color]" % joining_name)
	_update_players_ui()
	_broadcast_player_list()
	_check_start_conditions()

func _on_client_left_lobby(leaving_player_data: Dictionary) -> void:
	var left_id = leaving_player_data.get("lobby_id", -1)
	var left_name = leaving_player_data.get("name", "A player")
	
	for i in range(player_list.size() - 1, -1, -1):
		if player_list[i].get("lobby_id", -1) == left_id:
			player_list.remove_at(i)
			break
			
	_add_log("[color=#DF301C][System] %s left the lobby.[/color]" % left_name)
	_update_players_ui()
	_broadcast_player_list()
	_check_start_conditions()

func _host_set_player_ready(p_id: int, ready_state: bool) -> void:
	for p in player_list:
		if p.get("lobby_id", -1) == p_id:
			p["is_ready"] = ready_state
			var status_str = "is READY!" if ready_state else "is NOT ready."
			_add_log("[color=#00B7CD][System] %s %s[/color]" % [p.get("name", "Player"), status_str])
			break
	_update_players_ui()
	_broadcast_player_list()
	_check_start_conditions()

func _broadcast_player_list() -> void:
	NetworkSync.sync_data({
		"type": "update_player_list",
		"player_list": player_list
	})

func _check_start_conditions() -> void:
	if not GameManager.network_data.get("is_host", false):
		return
		
	var all_ready = true
	for p in player_list:
		if not p.get("is_ready", false):
			all_ready = false
			break
			
	start_btn.disabled = not (all_ready and player_list.size() >= 1)

func _update_players_ui() -> void:
	for child in players_container.get_children():
		child.queue_free()
		
	for p in player_list:
		var card = _create_player_card(p)
		players_container.add_child(card)

func _create_player_card(player_profile: Dictionary) -> PanelContainer:
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.9)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 14
	style.content_margin_top = 10
	style.content_margin_right = 14
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	
	var hbox = HBoxContainer.new()
	panel.add_child(hbox)
	
	var name_label = Label.new()
	var p_name = player_profile.get("name", "Unknown")
	var is_host = player_profile.get("is_host", false)
	var is_ready = player_profile.get("is_ready", false)
	
	name_label.text = p_name + (" (HOST)" if is_host else "")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Color(0.15, 0.15, 0.15, 1))
	hbox.add_child(name_label)
	
	var status_badge = Label.new()
	status_badge.text = "READY" if is_ready else "NOT READY"
	status_badge.add_theme_font_size_override("font_size", 16)
	var badge_color = Palette.RETRO.BLUE if is_ready else Palette.RETRO.ORANGE
	status_badge.add_theme_color_override("font_color", badge_color)
	hbox.add_child(status_badge)
	
	return panel

func _on_ready_pressed() -> void:
	is_local_ready = not is_local_ready
	_update_ready_button_visuals()
	
	var my_id = GameManager.get_lobby_id()
	if GameManager.network_data.get("is_host", false):
		_host_set_player_ready(my_id, is_local_ready)
	else:
		NetworkSync.sync_data({
			"type": "toggle_ready",
			"lobby_id": my_id,
			"is_ready": is_local_ready
		})

func _update_ready_button_visuals() -> void:
	ready_btn.text = "UNREADY" if is_local_ready else "READY UP"
	var style = StyleBoxFlat.new()
	style.bg_color = Palette.RETRO.ORANGE if is_local_ready else Palette.RETRO.BLUE
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_bottom_left = 4
	ready_btn.add_theme_stylebox_override("normal", style)

var _is_transitioning: bool = false

func _on_start_pressed() -> void:
	if not GameManager.network_data.get("is_host", false):
		return
	_add_log("[color=#00B7CD][System] Starting game...[/color]")
	var match_seed = randi()
	var match_settings = {"first_to": 3}
	GameManager.match_data = {
		"players": player_list,
		"seed": match_seed,
		"settings": match_settings
	}
	NetworkSync.sync_data({
		"type": "start_game",
		"seed": match_seed,
		"settings": match_settings,
		"player_list": player_list
	})

func _start_game_transition() -> void:
	if _is_transitioning:
		return
	_is_transitioning = true
	print("[Lobby] Transitioning to battle match scene...")
	var tree = get_tree()
	if tree != null:
		tree.change_scene_to_file("res://scenes/battle/battle.tscn")

func _on_send_chat_pressed() -> void:
	var msg = chat_input.text.strip_edges()
	if msg.is_empty():
		return
		
	chat_input.text = ""
	var my_name = GameManager.get_player_name()
	
	NetworkSync.sync_data({
		"type": "chat_message",
		"sender": my_name,
		"message": msg
	})
	
	if GameManager.network_data.get("is_host", false):
		_add_log("[b]%s:[/b] %s" % [my_name, msg])

func _add_log(bbcode_line: String) -> void:
	var time_str = Time.get_time_string_from_system()
	chat_log.append_text("[color=#888888][%s][/color] %s\n" % [time_str, bbcode_line])

func _on_server_disconnected() -> void:
	_add_log("[color=#DF301C][System] Disconnected from server.[/color]")
	await get_tree().create_timer(1.5).timeout
	_on_leave_pressed()

func _on_leave_pressed() -> void:
	if GameManager.network_data.get("is_host", false):
		NetworkSync.stop_hosting()
	else:
		NetworkSync.disconnect_from_server()
		
	GameManager.reset_network_data()
	get_tree().change_scene_to_file("res://scenes/room_selection/room_selection.tscn")
