class_name NetworkServer extends Node

@export var listen_port: int = 42069
@export var broadcast_port: int = 4242

var server_active: bool = false
var tcp_server := TCPServer.new()
var connected_clients: Array[WebSocketPeer] = []
var active_players: Array[Dictionary] = []

var udp_broadcaster := PacketPeerUDP.new()
var broadcast_timer: float = 0.0

var local_subnet: String = "255.255.255.255"
var custom_subnet: String = "10.147.17.255"

var client_last_seen: Dictionary = {}

func start(port: int = 42069) -> bool:
	if server_active:
		return true
		
	listen_port = port
	active_players.clear()
	connected_clients.clear()
	client_last_seen.clear()
	
	var err = tcp_server.listen(listen_port)
	if err != OK:
		push_error("[NetworkServer] Failed to listen on port %d! Error: %d" % [listen_port, err])
		return false

	udp_broadcaster.set_broadcast_enabled(true)
	server_active = true
	print("[NetworkServer] Server started on port %d (UDP beacon on port %d)" % [listen_port, broadcast_port])
	return true

func stop() -> void:
	if not server_active:
		return
		
	server_active = false
	udp_broadcaster.close()
	broadcast_timer = 0.0
	
	for ws in connected_clients:
		if ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
			ws.close(1001, "Server shutting down")
			
	connected_clients.clear()
	active_players.clear()
	client_last_seen.clear()
	tcp_server.stop()
	print("[NetworkServer] Server stopped.")

func _process(delta: float) -> void:
	if not server_active:
		return
		
	_handle_udp_broadcast(delta)
	_check_for_new_connections()
	_process_client_messages()

func _handle_udp_broadcast(delta: float) -> void:
	broadcast_timer += delta
	if broadcast_timer >= 2.0:
		broadcast_timer = 0.0
		
		var host_name = "Host"
		var game_status = "in_lobby"
		if GameManager != null:
			host_name = GameManager.player_data.get("name", "Host")
			game_status = GameManager.network_data.get("game_status", "in_lobby")
			
		var broadcast_data: Dictionary = {
			"identifier": "nataho_server",
			"host_name": host_name,
			"status": game_status,
			"player_count": active_players.size() + 1,
			"max_players": 8,
			"port": listen_port
		}
		
		var json_payload = JSON.stringify(broadcast_data)
		var packet_buffer = json_payload.to_utf8_buffer()
		
		var target_subnets = [local_subnet, custom_subnet]
		for subnet in target_subnets:
			udp_broadcaster.set_dest_address(subnet, broadcast_port)
			udp_broadcaster.put_packet(packet_buffer)

func _check_for_new_connections() -> void:
	while tcp_server.is_connection_available():
		var conn = tcp_server.take_connection()
		var ws = WebSocketPeer.new()
		ws.accept_stream(conn)
		ws.set_meta("welcomed", false)
		connected_clients.append(ws)
		client_last_seen[ws] = Time.get_ticks_msec()
		print("[NetworkServer] Incoming connection from client")

func _process_client_messages() -> void:
	var current_time = Time.get_ticks_msec()
	for i in range(connected_clients.size() - 1, -1, -1):
		var ws = connected_clients[i]
		ws.poll()
		var state = ws.get_ready_state()
		
		if state == WebSocketPeer.STATE_OPEN:
			if not ws.get_meta("welcomed", false):
				_send_welcome(ws)
				ws.set_meta("welcomed", true)
				
			_read_packets(ws)
			
			if current_time - client_last_seen.get(ws, current_time) > 15000:
				print("[NetworkServer] Client timed out (no pings for 15s). Dropping connection.")
				ws.close(1008, "Ping Timeout")
		elif state == WebSocketPeer.STATE_CLOSED:
			client_last_seen.erase(ws)
			for p in range(active_players.size() - 1, -1, -1):
				if active_players[p].get("socket") == ws:
					var leaving_player = active_players[p]
					active_players.remove_at(p)
					print("[NetworkServer] Player left: ", leaving_player.get("name", "Unknown"))
					EventBus.client_left_lobby.emit(leaving_player)
			connected_clients.remove_at(i)

func _read_packets(ws: WebSocketPeer) -> void:
	while ws.get_available_packet_count() > 0:
		var packet = ws.get_packet()
		client_last_seen[ws] = Time.get_ticks_msec()
		var msg = packet.get_string_from_utf8()
		var parsed_msg = JSON.parse_string(msg)
		
		if typeof(parsed_msg) != TYPE_DICTIONARY or not parsed_msg.has("signal"):
			continue
		
		if parsed_msg["signal"] == "ping":
			send_to_client(ws, "pong")
			continue
		
		_handle_signal(ws, parsed_msg)

func _handle_signal(ws: WebSocketPeer, data: Dictionary) -> void:
	var signal_name = data.get("signal", "")
	var payload = data.get("data", {})
	
	match signal_name:
		"request_join":
			EventBus.join_requested.emit(ws, payload)
		"sync_data":
			EventBus.sync_data.emit(payload)
			broadcast_signal("sync_data", payload)
		"sync_interaction":
			EventBus.sync_interaction.emit(payload)
			broadcast_signal("sync_interaction", payload)
		"send_board_data":
			EventBus.received_board_data.emit(payload)
			broadcast_signal("send_board_data", payload)
		_:
			print("[NetworkServer] Unhandled signal: ", signal_name)

func approve_join(ws: WebSocketPeer, player_data: Dictionary) -> void:
	var profile = player_data.duplicate()
	profile["socket"] = ws
	active_players.append(profile)
	print("[NetworkServer] Approved join for: ", profile.get("name", "Player"))
	send_to_client(ws, "join_accepted", {
		"total_players": active_players.size() + 1,
		"host_name": GameManager.player_data.get("name", "Host") if GameManager != null else "Host"
	})

func reject_join(ws: WebSocketPeer, reason: String) -> void:
	print("[NetworkServer] Rejected join. Reason: ", reason)
	send_to_client(ws, "join_rejected", {"reason": reason})
	ws.close(1008, "Rejected: " + reason)

func _send_welcome(ws: WebSocketPeer) -> void:
	send_to_client(ws, "server_connected")

func send_to_client(ws: WebSocketPeer, signal_name: String, extra_data: Dictionary = {}) -> void:
	var payload = {"signal": signal_name, "data": extra_data}
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(payload))

func broadcast_signal(signal_name: String, extra_data: Dictionary = {}) -> void:
	var payload = {"signal": signal_name, "data": extra_data}
	var json_str = JSON.stringify(payload)
	for ws in connected_clients:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var is_validated = false
			for p in active_players:
				if p.get("socket") == ws:
					is_validated = true
					break
			if is_validated:
				ws.send_text(json_str)
