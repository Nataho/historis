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
