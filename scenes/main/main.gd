extends Control

func _ready() -> void:
	Audio.play_music("menu_loop")

func exit() -> void:
	get_tree().quit()
