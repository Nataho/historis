extends Node

# --- Gameplay Signals ---
signal lines_cleared(line_count: int, combo_count: int)
signal score_updated(new_score: int, added_points: int)
signal level_updated(new_level: int)
signal player_topped_out(player_id: int, last_attacker_id: int)
signal game_started
signal game_over

# --- Piece & Input Signals ---
signal piece_placed(piece_type: String)
signal piece_held(piece_type: String)

# --- multiplayer signals ---
# chunks: Array of {lines:int, hole_column:int} - see TetrisEngine.garbage_sent.
# Emitted by the sending Board only after its own 0.5s network delay has elapsed.
signal send_garbage(chunks: Array, sender_id: int, receiver_id: int)

# --- Networking & Connection Signals ---
signal client_searching
signal connection_timeout
signal client_connected_to_server
signal failed_to_connect_to_server
signal client_disconnected
signal server_rejected_join(reason: String)
signal server_accepted_join(server_data: Dictionary)
signal discovered_servers_updated(servers_list: Array[Dictionary])

# --- Server & Lobby Handshake Signals ---
signal join_requested(ws_peer: WebSocketPeer, player_data: Dictionary)
signal client_joined_lobby(player_data: Dictionary)
signal client_left_lobby(player_data: Dictionary)

# --- Network Sync & Messaging Signals ---
signal sync_data(data: Dictionary)
signal sync_interaction(data: Dictionary)
signal received_board_data(data: Dictionary)

## Helper to build standard network payloads
static func get_base_payload(player_id: int, player_name: String) -> Dictionary:
	return {
		"player_id": player_id,
		"player_name": player_name
	}
