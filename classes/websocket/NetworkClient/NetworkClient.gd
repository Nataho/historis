class_name NetworkClient extends Node

@export var listen_port: int = 4242
@export var server_port: int = 42069

var client := WebSocketPeer.new()
var udp_listener := PacketPeerUDP.new()

var client_active: bool = false
var is_connecting: bool = false
var is_discovering: bool = false
var found_server_ip: String = ""

var local_player_data: Dictionary = {}
var discovered_servers: Array[Dictionary] = []

var prune_timer: float = 0.0
var heartbeat_timer: float = 0.0
var connection_timer: float = 0.0
var last_ping_time: int = 0
var ping_ms: int = 0

const CONNECTION_TIMEOUT: float = 15.0

func start() -> bool:
	if client_active or is_connecting or is_discovering:
		return true
		
	discovered_servers.clear()
	found_server_ip = ""
	
	if udp_listener.is_bound():
		udp_listener.close()
	
	var err = udp_listener.bind(listen_port)
	if err == OK:
		is_discovering = true
		EventBus.client_searching.emit()
		print("[NetworkClient] Listening for LAN servers on UDP port %d" % listen_port)
		return true
	else:
		print("[NetworkClient] Could not bind UDP listener on port %d (Error %d). Direct IP connect is still available." % [listen_port, err])
		is_discovering = false
		return false

func connect_to_server(ip: String, player_data: Dictionary, port: int = 42069) -> void:
	if client_active or is_connecting:
		stop()
		
	local_player_data = player_data.duplicate()
	server_port = port
	found_server_ip = ip.strip_edges()
	if found_server_ip.is_empty():
		found_server_ip = "127.0.0.1"
		
	is_discovering = false
	if udp_listener.is_bound():
		udp_listener.close()
		
	client_active = true
	is_connecting = true
	connection_timer = CONNECTION_TIMEOUT
	
	var url = "ws://" + found_server_ip + ":" + str(server_port)
	print("[NetworkClient] Connecting to %s..." % url)
	client = WebSocketPeer.new()
	var err = client.connect_to_url(url)
	if err != OK:
		push_error("[NetworkClient] Failed to initiate connection to %s! Error: %d" % [url, err])
		stop()
		EventBus.failed_to_connect_to_server.emit()

func stop_discovery() -> void:
	if udp_listener.is_bound():
		udp_listener.close()
	is_discovering = false

func stop() -> void:
	stop_discovery()
		
	if client.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		client.close()
		
	client_active = false
	is_connecting = false
	found_server_ip = ""
	connection_timer = 0.0
	discovered_servers.clear()
	print("[NetworkClient] Client stopped.")

func _process(delta: float) -> void:
	if is_discovering:
		_search_for_servers()
		_prune_stale_servers(delta)

	if is_connecting:
		connection_timer -= delta
		if connection_timer <= 0.0:
			print("[NetworkClient] Connection timed out!")
			stop()
			EventBus.connection_timeout.emit()
			EventBus.failed_to_connect_to_server.emit()
			return

	if not client_active:
		return

	client.poll()
	var state = client.get_ready_state()
	
	if state == WebSocketPeer.STATE_OPEN:
		if is_connecting:
			is_connecting = false
			print("[NetworkClient] WebSocket connection established!")
			
		_handle_server_messages()
		
		heartbeat_timer += delta
		if heartbeat_timer >= 1.0:
			heartbeat_timer = 0.0
			last_ping_time = Time.get_ticks_msec()
			send_signal("ping")
	elif state == WebSocketPeer.STATE_CLOSED:
		print("[NetworkClient] WebSocket disconnected from server.")
		stop()
		EventBus.client_disconnected.emit()

func _search_for_servers() -> void:
	if not udp_listener.is_bound():
		return
		
	var current_time = Time.get_ticks_msec()
	var list_changed = false
	
	while udp_listener.get_available_packet_count() > 0:
		var packet = udp_listener.get_packet()
		var packet_msg = packet.get_string_from_utf8()
		var parsed = JSON.parse_string(packet_msg)
		
		if typeof(parsed) == TYPE_DICTIONARY and parsed.get("identifier") == "nataho_server":
			var server_ip = udp_listener.get_packet_ip()
			var server_info: Dictionary = {
				"ip": server_ip,
				"last_seen": current_time,
				"host_name": parsed.get("host_name", "Unknown Host"),
				"status": parsed.get("status", "in_lobby"),
				"player_count": parsed.get("player_count", 1),
				"max_players": parsed.get("max_players", 8),
				"port": parsed.get("port", 42069)
			}
			
			var existing_index = -1
			for i in range(discovered_servers.size()):
				if discovered_servers[i]["ip"] == server_ip and discovered_servers[i].get("port", 42069) == server_info["port"]:
					existing_index = i
					break
			
			if existing_index != -1:
				discovered_servers[existing_index] = server_info
				list_changed = true
			else:
				discovered_servers.append(server_info)
				list_changed = true
				print("[NetworkClient] Discovered server: %s (%s:%d)" % [server_info["host_name"], server_ip, server_info["port"]])
				
	if list_changed:
		EventBus.discovered_servers_updated.emit(discovered_servers)

func _prune_stale_servers(delta: float) -> void:
	prune_timer += delta
	if prune_timer < 1.0:
		return
	prune_timer = 0.0
	
	var current_time = Time.get_ticks_msec()
	var list_changed = false
	for i in range(discovered_servers.size() - 1, -1, -1):
		if current_time - discovered_servers[i]["last_seen"] > 6000:
			discovered_servers.remove_at(i)
			list_changed = true
			
	if list_changed:
		EventBus.discovered_servers_updated.emit(discovered_servers)

func _handle_server_messages() -> void:
	while client.get_available_packet_count() > 0:
		var packet = client.get_packet()
		var raw_data = packet.get_string_from_utf8()
		if raw_data.is_empty():
			continue
		var parsed_msg = JSON.parse_string(raw_data)
		if typeof(parsed_msg) != TYPE_DICTIONARY:
			continue
		_process_server_signal(parsed_msg)

func _process_server_signal(data: Dictionary) -> void:
	var signal_name = data.get("signal", "")
	var payload = data.get("data", {})
	if signal_name.is_empty():
		return

	match signal_name:
		"server_connected":
			EventBus.client_connected_to_server.emit()
			print("[NetworkClient] Server accepted connection. Requesting join with: ", local_player_data)
			send_signal("request_join", local_player_data)
		"join_accepted":
			print("[NetworkClient] Join accepted by server!")
			EventBus.server_accepted_join.emit(payload)
		"join_rejected":
			var reason = payload.get("reason", "Unknown reason")
			print("[NetworkClient] Join rejected by server: ", reason)
			EventBus.server_rejected_join.emit(reason)
			stop()
		"sync_data":
			EventBus.sync_data.emit(payload)
		"sync_interaction":
			EventBus.sync_interaction.emit(payload)
		"send_board_data":
			EventBus.received_board_data.emit(payload)
		"pong":
			ping_ms = Time.get_ticks_msec() - last_ping_time
		_:
			print("[NetworkClient] Received server signal: ", signal_name)

func sync_interaction(action: String, player_id: int, player_name: String) -> void:
	var payload = EventBus.get_base_payload(player_id, player_name)
	payload["action"] = action
	send_signal("sync_interaction", payload)

func sync_data(data: Dictionary) -> void:
	send_signal("sync_data", data)

func send_board_data(data: Dictionary) -> void:
	send_signal("send_board_data", data)

func send_signal(signal_name: String, extra_data: Dictionary = {}) -> void:
	var payload = {"signal": signal_name, "data": extra_data}
	if client.get_ready_state() == WebSocketPeer.STATE_OPEN:
		client.send_text(JSON.stringify(payload))
