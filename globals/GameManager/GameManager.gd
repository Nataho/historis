extends Node

var player_data: Dictionary = {
	"name": "Player",
	"lobby_id": -1
}

var network_data: Dictionary = {
	"is_host": false,
	"is_ready": false,
	"game_status": "inactive",
	"player_list": [],
	"lobby_id": -1
}

var match_data: Dictionary = {
	"players": [],
	"seed": -1,
	"settings": {
		"first_to": 3
	}
}

var _is_muted = false

func _ready() -> void:
	_CLA()
	if player_data.get("lobby_id", -1) == -1:
		player_data["lobby_id"] = generate_lobby_id()
	network_data["lobby_id"] = player_data["lobby_id"]
	
	#if _is_muted:
		#var bus_idx = AudioServer.get_bus_index("Master")
		#AudioServer.set_bus_mute(bus_idx,false)

func generate_lobby_id() -> int:
	return randi_range(10000, 99999)

func set_player_name(new_name: String) -> void:
	var clean_name = new_name.strip_edges()
	if clean_name.is_empty():
		clean_name = "Player"
	player_data["name"] = clean_name

func get_player_name() -> String:
	return player_data.get("name", "Player")

func get_lobby_id() -> int:
	return player_data.get("lobby_id", -1)

func reset_network_data() -> void:
	network_data = {
		"is_host": false,
		"is_ready": false,
		"game_status": "inactive",
		"player_list": [],
		"lobby_id": player_data.get("lobby_id", -1)
	}

func _CLA():
	var args = OS.get_cmdline_args()
	if "--mute" in args:
		print("muting")
		_is_muted = true
		AudioServer.set_bus_mute(0,true)
	#if "--nostart" in args:
		#no_start = true
