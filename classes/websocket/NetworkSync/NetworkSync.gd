extends Node

enum NetMode { OFFLINE, LAN_HOST, LAN_CLIENT, ONLINE }

static var inst: Node = null

var current_mode: NetMode = NetMode.OFFLINE
var server: NetworkServer = null
var client: NetworkClient = null

func _enter_tree() -> void:
	inst = self
	_setup_network_nodes()

func _ready() -> void:
	EventBus.server_accepted_join.connect(_on_server_accepted_join)
	EventBus.client_disconnected.connect(_on_client_disconnected)

func _setup_network_nodes() -> void:
	if server == null:
		server = NetworkServer.new()
		server.name = "NetworkServer"
		add_child(server)
		
	if client == null:
		client = NetworkClient.new()
		client.name = "NetworkClient"
		add_child(client)

func host_game(port: int = 42069) -> bool:
	if client.client_active or client.is_discovering:
		client.stop()
		
	var success = server.start(port)
	if success:
		current_mode = NetMode.LAN_HOST
		if GameManager != null:
			GameManager.network_data["is_host"] = true
	return success

func stop_hosting() -> void:
	server.stop()
	current_mode = NetMode.OFFLINE
	if GameManager != null:
		GameManager.network_data["is_host"] = false

func start_discovery() -> bool:
	if current_mode == NetMode.LAN_HOST:
		return false
	return client.start()

func stop_discovery() -> void:
	client.stop_discovery()

func connect_to_server(ip: String, player_data: Dictionary, port: int = 42069) -> void:
	if current_mode == NetMode.LAN_HOST:
		stop_hosting()
	client.connect_to_server(ip, player_data, port)

func disconnect_from_server() -> void:
	client.stop()
	current_mode = NetMode.OFFLINE
	if GameManager != null:
		GameManager.network_data["is_host"] = false

func _on_server_accepted_join(_server_data: Dictionary) -> void:
	current_mode = NetMode.LAN_CLIENT
	if GameManager != null:
		GameManager.network_data["is_host"] = false

func _on_client_disconnected() -> void:
	current_mode = NetMode.OFFLINE
	if GameManager != null:
		GameManager.network_data["is_host"] = false

func sync_data(data: Dictionary) -> void:
	match current_mode:
		NetMode.LAN_CLIENT:
			client.sync_data(data)
		NetMode.LAN_HOST:
			EventBus.sync_data.emit(data)
			server.broadcast_signal("sync_data", data)
		_:
			pass

func sync_interaction(action: String, player_id: int, player_name: String) -> void:
	match current_mode:
		NetMode.LAN_CLIENT:
			client.sync_interaction(action, player_id, player_name)
		NetMode.LAN_HOST:
			var payload = EventBus.get_base_payload(player_id, player_name)
			payload["action"] = action
			EventBus.sync_interaction.emit(payload)
			server.broadcast_signal("sync_interaction", payload)
		_:
			pass

func send_board_data(data: Dictionary) -> void:
	match current_mode:
		NetMode.LAN_CLIENT:
			client.send_board_data(data)
		NetMode.LAN_HOST:
			EventBus.received_board_data.emit(data)
			server.broadcast_signal("send_board_data", data)
		_:
			pass
