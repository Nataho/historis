extends Node
const FILE = "res://classes/Audio/Audio.tscn"

#static var inst:Audio = null

#static func spawn():
	#var loaded = ResourceLoader.load(FILE, "", ResourceLoader.CACHE_MODE_REPLACE)
	#if loaded:
		#inst = loaded.instantiate()
		#Dummy.add_child(inst)
	#else:
		#push_error("CRITICAL: Failed to load Audio.tscn via Cache Mode Replace!")

# The acting autoload instance
#static var active_node: Audio

enum SOUND_END_EFFECTS {NONE, FADE, VINYL}
enum SOUND_START_EFFECTS {NONE, FADE}

var music_player_node: AudioStreamPlayer

var stop_tween: Tween
var start_tween: Tween

# 1. DECLARE THEM EMPTY HERE
var _sound := {}
var _music := {}

const MASTER_BUS = "Master"
const SFX_BUS = "Sfx"
const MUSIC_BUS = "Music"

func _enter_tree() -> void:
	# Set the static reference to THIS node when it enters the scene
	music_player_node = AudioStreamPlayer.new()
	add_child(music_player_node)
	
	# 2. FILL THEM HERE! Godot cannot cache this.
	_sound = {
		"hard_drop":[preload("uid://cnnuyv3y4oa6d"), 0],
		"hold": [preload("uid://dqsbfl3a7fsm6"), 0],
		
		"clear1": [preload("uid://cdhy288ahx2sl"), 0],
		"clear2": [preload("uid://dtrds64sbhict"), 0],
		"clear3": [preload("uid://bw2uxkyiwsvhb"), 0],
		"clear4": [preload("uid://birfik5hfkwn2"), 0],
		
		"tick_3": [preload("uid://cosmdl2ppooxg"), 0],
		"tick_2": [preload("uid://4amnaxdj3ejb"), 0],
		"tick_1": [preload("uid://djxafuyqr1jlx"), 0],
		"tick_go": [preload("uid://bodhv4aggukgi"), 0],
		
		"combo1": [preload("uid://b3ieh5qwi2fh5"), 0],
		"combo2": [preload("uid://dq100ev2bifdx"), 0],
		"combo3": [preload("uid://b8icel6gep6nc"), 0],
		"combo4": [preload("uid://dxb13e5opcqjr"), 0],
		"combo5": [preload("uid://5i4btyjrbx4b"), 0],
		"combo6": [preload("uid://rx5me2ysuwmb"), 0],
		"combo7": [preload("uid://c1cbhrgnjs5fr"), 0],
		
		"KO": [preload("uid://de6vqyx6mixmg"), 0]
	}

	_music = {
		"menu_loop": [preload("uid://c1hsx4s22yct8"), 0],
		"battle": []
		
	}

# ==========================================
# INSTANCE METHODS (The actual logic)
# ==========================================

func play_sound(sound_key: String, offset: float = 0) -> void:
	if sound_key not in _sound.keys(): 
		push_error("sound not found: ", sound_key)
		return
		
	var sfx := AudioStreamPlayer.new()
	sfx.stream = _sound[sound_key][0]
	sfx.volume_db = _sound[sound_key][1]
	sfx.bus = &"Sfx"
	
	add_child(sfx)
	sfx.play(offset)
	await sfx.finished
	sfx.queue_free()

func play_music(music_key: String, end_effect: SOUND_END_EFFECTS = SOUND_END_EFFECTS.NONE, start_effect: SOUND_START_EFFECTS = SOUND_START_EFFECTS.NONE) -> void:
	music_player_node.bus = &"Music"
	if not _music.has(music_key):
		push_error("The sound key is not found in the dictionary: ", music_key)
		return
	
	var loaded_file = _music[music_key][0]
	var target_volume = _music[music_key][1]
	
	# If this exact track is already playing, don't restart it
	if music_player_node.stream == loaded_file and music_player_node.playing:
		return
		
	# 1. Handle the END effect
	if music_player_node.playing:
		if end_effect == SOUND_END_EFFECTS.VINYL:
			await _trigger_vinyl_stop(2.0)
		elif end_effect == SOUND_END_EFFECTS.FADE:
			await _trigger_fade_out(1.5)
		else:
			music_player_node.stop()
				
	# 2. Setup the NEW track
	music_player_node.stream = loaded_file
	music_player_node.pitch_scale = 1.0 
	
	# 3. Handle the START effect
	if start_effect == SOUND_START_EFFECTS.FADE:
		music_player_node.volume_db = -80.0 
		music_player_node.play()
		_trigger_fade_in(target_volume, 1.5)
	else:
		music_player_node.volume_db = target_volume
		music_player_node.play()
		
	print("Now playing: ", music_key)
	print("is playing?: ", music_player_node.playing)

func _trigger_fade_out(duration: float = 1.5) -> void:
	if stop_tween and stop_tween.is_running():
		stop_tween.kill()
		
	stop_tween = create_tween()
	stop_tween.tween_property(music_player_node, "volume_db", -80.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	
	stop_tween.tween_callback(func():
		music_player_node.stop()
	)
	
	await stop_tween.finished

func _trigger_fade_in(target_volume: float, duration: float = 1.5) -> void:
	if start_tween and start_tween.is_running():
		start_tween.kill()
		
	start_tween = create_tween()
	start_tween.tween_property(music_player_node, "volume_db", target_volume, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _trigger_vinyl_stop(duration: float = 20.0) -> void:
	if stop_tween and stop_tween.is_running():
		stop_tween.kill()
		
	stop_tween = create_tween().set_parallel(true)
	
	# Slide pitch down to 0.01 (Godot crashes at exactly 0.0)
	stop_tween.tween_property(music_player_node, "pitch_scale", 0.01, duration).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	# Slide volume down to silence (-80.0 db)
	stop_tween.tween_property(music_player_node, "volume_db", -80.0, duration).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	
	stop_tween.chain().tween_callback(func():
		music_player_node.stop()
		music_player_node.pitch_scale = 1.0 # Reset pitch for the next track
	)
	
	await stop_tween.finished

#func _set_bus_volume(bus_name: String, volume_db: float) -> void:
	## Find the ID of the bus by its name (e.g., "Master", "Music", "Sfx")
	#var bus_idx = AudioServer.get_bus_index(bus_name)
	#
	#GameManager.inst.sound_settings[bus_name] = volume_db
	#
	#if bus_idx == -1:
		#push_error("Audio bus not found: ", bus_name)
		#return
		#
	## If volume is -30 or lower, completely mute the bus
	#GameManager.SAVE_GAME()
	#if GameManager.inst._is_muted: return
	#
	#if volume_db <= -30.0:
		#AudioServer.set_bus_mute(bus_idx, true)
		#AudioServer.set_bus_volume_db(bus_idx, -30.0)
	#else:
		## Otherwise, unmute it and set the specific volume
		#AudioServer.set_bus_mute(bus_idx, false)
		#AudioServer.set_bus_volume_db(bus_idx, volume_db)

func _apply_wavy_pitch(player: AudioStreamPlayer, progress: float) -> void:
	var time: float = Time.get_ticks_msec() / 1000.0 
	var wobble: float = sin(time * 30.0) * 0.15 * progress
	
	player.pitch_scale = max(0.01, progress + wobble)
	player.volume_db = linear_to_db(progress)

func _update_volume():
	pass
