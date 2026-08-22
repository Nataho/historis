extends Control

@onready var name_input: LineEdit = %NameInput
@onready var host_btn: Button = %HostButton
@onready var lan_tab_btn: Button = %LanTabButton
@onready var direct_tab_btn: Button = %DirectTabButton
@onready var lan_panel: Control = %LanPanel
@onready var direct_panel: Control = %DirectPanel
@onready var server_list_container: VBoxContainer = %ServerListContainer
@onready var no_servers_label: Label = %NoServersLabel
@onready var direct_ip_input: LineEdit = %DirectIpInput
@onready var direct_port_input: LineEdit = %DirectPortInput
@onready var direct_connect_btn: Button = %DirectConnectButton
@onready var status_label: Label = %StatusLabel
@onready var back_btn: Button = %BackButton
@onready var refresh_btn: Button = %RefreshButton

func _ready() -> void:
	name_input.text = GameManager.get_player_name()
	name_input.text_changed.connect(_on_name_changed)
	
	host_btn.pressed.connect(_on_host_pressed)
	lan_tab_btn.pressed.connect(func(): _switch_tab(true))
	direct_tab_btn.pressed.connect(func(): _switch_tab(false))
	
	direct_connect_btn.pressed.connect(_on_direct_connect_pressed)
	back_btn.pressed.connect(_on_back_pressed)
	refresh_btn.pressed.connect(_on_refresh_pressed)
	
	EventBus.discovered_servers_updated.connect(_on_discovered_servers_updated)
	EventBus.server_accepted_join.connect(_on_server_accepted_join)
	EventBus.server_rejected_join.connect(_on_server_rejected_join)
	EventBus.failed_to_connect_to_server.connect(_on_connection_failed)
	EventBus.connection_timeout.connect(_on_connection_timeout)
	
	_switch_tab(true)
	_start_lan_discovery()

func _exit_tree() -> void:
	NetworkSync.stop_discovery()

func _on_name_changed(new_name: String) -> void:
	GameManager.set_player_name(new_name)

func _switch_tab(show_lan: bool) -> void:
	lan_panel.visible = show_lan
	direct_panel.visible = not show_lan
	lan_tab_btn.button_pressed = show_lan
	direct_tab_btn.button_pressed = not show_lan

func _start_lan_discovery() -> void:
	status_label.text = "Searching for LAN lobbies..."
	status_label.modulate = Palette.RETRO.BLUE
	NetworkSync.start_discovery()

func _on_refresh_pressed() -> void:
	NetworkSync.stop_discovery()
	for child in server_list_container.get_children():
		child.queue_free()
	no_servers_label.visible = true
	_start_lan_discovery()

func _on_host_pressed() -> void:
	status_label.text = "Creating lobby..."
	status_label.modulate = Palette.RETRO.BLUE
	
	var host_name = GameManager.get_player_name()
	GameManager.player_data["lobby_id"] = 1
	GameManager.network_data["lobby_id"] = 1
	GameManager.network_data["is_host"] = true
	GameManager.network_data["game_status"] = "in_lobby"
	GameManager.network_data["player_list"] = [
		{
			"lobby_id": 1,
			"name": host_name,
			"is_ready": false,
			"is_host": true
		}
	]
	
	var port = 42069
	if direct_port_input.text.is_valid_int():
		port = direct_port_input.text.to_int()
		
	var success = NetworkSync.host_game(port)
	if success:
		get_tree().change_scene_to_file("res://scenes/game_lobby/game_lobby.tscn")
	else:
		status_label.text = "Failed to host lobby on port %d!" % port
		status_label.modulate = Palette.RETRO.RED

func _on_direct_connect_pressed() -> void:
	var ip = direct_ip_input.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
		
	var port = 42069
	if direct_port_input.text.is_valid_int():
		port = direct_port_input.text.to_int()
		
	_connect_to_target(ip, port)

func _connect_to_target(ip: String, port: int) -> void:
	status_label.text = "Connecting to %s:%d..." % [ip, port]
	status_label.modulate = Palette.RETRO.ORANGE
	
	GameManager.player_data["lobby_id"] = GameManager.generate_lobby_id()
	GameManager.network_data["is_host"] = false
	
	NetworkSync.connect_to_server(ip, GameManager.player_data, port)

func _on_discovered_servers_updated(servers_list: Array[Dictionary]) -> void:
	if not is_instance_valid(server_list_container):
		return
		
	for child in server_list_container.get_children():
		child.queue_free()
		
	if servers_list.is_empty():
		if is_instance_valid(no_servers_label):
			no_servers_label.visible = true
			no_servers_label.text = "No LAN lobbies found yet. Searching..."
		return
		
	if is_instance_valid(no_servers_label):
		no_servers_label.visible = false
	if is_instance_valid(status_label):
		status_label.text = "Found %d LAN lobb%s." % [servers_list.size(), "y" if servers_list.size() == 1 else "ies"]
		status_label.modulate = Palette.RETRO.BLUE
	
	for server_info in servers_list:
		var item = _create_server_list_item(server_info)
		server_list_container.add_child(item)

func _create_server_list_item(server_info: Dictionary) -> PanelContainer:
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.9)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 12
	style.content_margin_top = 8
	style.content_margin_right = 12
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	panel.add_child(hbox)
	
	var info_vbox = VBoxContainer.new()
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info_vbox)
	
	var host_label = Label.new()
	host_label.text = server_info.get("host_name", "Unknown Host") + "'s Lobby"
	host_label.add_theme_font_size_override("font_size", 20)
	host_label.add_theme_color_override("font_color", Color(0.15, 0.15, 0.15, 1))
	info_vbox.add_child(host_label)
	
	var details_label = Label.new()
	var ip = server_info.get("ip", "127.0.0.1")
	var port = server_info.get("port", 42069)
	var players = server_info.get("player_count", 1)
	var max_p = server_info.get("max_players", 8)
	var status = server_info.get("status", "in_lobby")
	details_label.text = "%s:%d | Players: %d/%d | Status: %s" % [ip, port, players, max_p, status]
	details_label.add_theme_font_size_override("font_size", 14)
	details_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4, 1))
	info_vbox.add_child(details_label)
	
	var join_btn = Button.new()
	join_btn.text = "JOIN"
	join_btn.custom_minimum_size = Vector2(100, 40)
	
	var btn_style = StyleBoxFlat.new()
	btn_style.bg_color = Palette.RETRO.BLUE
	btn_style.corner_radius_top_left = 4
	btn_style.corner_radius_top_right = 4
	btn_style.corner_radius_bottom_right = 4
	btn_style.corner_radius_bottom_left = 4
	join_btn.add_theme_stylebox_override("normal", btn_style)
	
	var hover_style = StyleBoxFlat.new()
	hover_style.bg_color = Palette.RETRO.ORANGE
	hover_style.corner_radius_top_left = 4
	hover_style.corner_radius_top_right = 4
	hover_style.corner_radius_bottom_right = 4
	hover_style.corner_radius_bottom_left = 4
	join_btn.add_theme_stylebox_override("hover", hover_style)
	
	join_btn.pressed.connect(func(): _connect_to_target(ip, port))
	hbox.add_child(join_btn)
	
	return panel

func _on_server_accepted_join(server_data: Dictionary) -> void:
	status_label.text = "Joined successfully!"
	status_label.modulate = Palette.RETRO.BLUE
	print("[RoomSelection] Server accepted join: ", server_data)
	get_tree().change_scene_to_file("res://scenes/game_lobby/game_lobby.tscn")

func _on_server_rejected_join(reason: String) -> void:
	status_label.text = "Join Rejected: " + reason
	status_label.modulate = Palette.RETRO.RED

func _on_connection_failed() -> void:
	status_label.text = "Connection Failed! Could not reach host."
	status_label.modulate = Palette.RETRO.RED

func _on_connection_timeout() -> void:
	status_label.text = "Connection Timed Out!"
	status_label.modulate = Palette.RETRO.RED

func _on_back_pressed() -> void:
	NetworkSync.stop_discovery()
	get_tree().change_scene_to_file("res://scenes/main/main.tscn")
