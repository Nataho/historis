@tool
extends RichTextEffect
class_name RichTextBounce

# This defines the actual text you will type in your BBCode!
var bbcode = "bounce"

func _process_custom_fx(char_fx: CharFXTransform) -> bool:
	# 1. Grab our custom parameters (or set defaults if left blank)
	var freq = char_fx.env.get("freq", 5.0) as float
	var amp = char_fx.env.get("amp", 10.0) as float
	
	# 2. The Bounce Math 
	# We use abs(sin()) so the curve "bounces" off zero instead of swinging below it like a wave
	var time = char_fx.elapsed_time * freq
	var letter_offset = char_fx.range.x * 0.5 # Staggers the jump per letter
	
	var bounce_height = abs(sin(time + letter_offset)) * amp
	
	# 3. Apply the movement (Negative Y goes UP in Godot 2D)
	char_fx.offset.y -= bounce_height
	
	return true
