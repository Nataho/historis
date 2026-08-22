extends Control

func _ready() -> void:
	Audio.play_music("menu_loop")
	var mp_btn = get_node_or_null("VBoxContainer/multiplayer")
	if mp_btn != null and not mp_btn.pressed.is_connected(_on_multiplayer_pressed):
		mp_btn.pressed.connect(_on_multiplayer_pressed)

func _on_multiplayer_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/room_selection/room_selection.tscn")

func exit() -> void:
	get_tree().quit()
