class_name AttackParticle extends Node2D

var start_point: Vector2 = Vector2.ZERO
var control_point: Vector2 = Vector2.ZERO
var target_point: Vector2 = Vector2.ZERO
var target_node: Control = null

var travel_time: float = 0.55
var elapsed: float = 0.0
var particle_color: Color = Color("DF301C")
var particle_radius: float = 8.0

static func launch(parent: Node, from_pos: Vector2, to_pos: Vector2, amount: int = 1) -> void:
	for i in range(min(amount, 12)):
		var p = AttackParticle.new()
		p.start_point = from_pos + Vector2(randf_range(-20, 20), randf_range(-20, 20))
		p.target_point = to_pos
		
		# Arc upward
		var mid = (from_pos + to_pos) * 0.5
		var arc_height = randf_range(-120.0, -260.0)
		var arc_spread = randf_range(-60.0, 60.0)
		p.control_point = Vector2(mid.x + arc_spread, min(from_pos.y, to_pos.y) + arc_height)
		
		p.travel_time = randf_range(0.45, 0.65)
		
		# Color based on amount using Palette
		if amount < 4:
			p.particle_color = Palette.RETRO.RED
			p.particle_radius = 7.0
		elif amount < 6:
			p.particle_color = Palette.RETRO.ORANGE
			p.particle_radius = 9.0
		elif amount < 8:
			p.particle_color = Palette.PURPLE_GRADIENT.BRIGHT
			p.particle_radius = 11.0
		else:
			var colors = [
				Palette.RETRO.RED,
				Palette.RETRO.ORANGE,
				Palette.PURPLE_GRADIENT.BRIGHT,
				Palette.TEAL_GRADIENT.LIGHT,
				Palette.BLUE_GRADIENT.DARK
			]
			p.particle_color = colors[i % colors.size()]
			p.particle_radius = 13.0
			
		parent.add_child(p)

func _ready() -> void:
	global_position = start_point

func _process(delta: float) -> void:
	elapsed += delta
	var t = clampf(elapsed / travel_time, 0.0, 1.0)
	
	# Quadratic Bezier: B(t) = (1-t)^2 * P0 + 2(1-t)t * P1 + t^2 * P2
	var current_target = target_node.global_position if (target_node != null and is_instance_valid(target_node)) else target_point
	var p0 = start_point
	var p1 = control_point
	var p2 = current_target
	
	var one_minus_t = 1.0 - t
	var pos = (one_minus_t * one_minus_t * p0) + (2.0 * one_minus_t * t * p1) + (t * t * p2)
	global_position = pos
	
	queue_redraw()
	
	if t >= 1.0:
		_on_impact()

func _draw() -> void:
	# Glow / Outer circle
	draw_circle(Vector2.ZERO, particle_radius * 1.5, Color(particle_color.r, particle_color.g, particle_color.b, 0.35))
	# Inner bright circle
	draw_circle(Vector2.ZERO, particle_radius, particle_color)
	# Center highlight
	draw_circle(Vector2.ZERO, particle_radius * 0.4, Color.WHITE)

func _on_impact() -> void:
	set_process(false)
	var tween = create_tween()
	tween.tween_property(self, "scale", Vector2(1.8, 1.8), 0.1)
	tween.parallel().tween_property(self, "modulate:a", 0.0, 0.1)
	tween.tween_callback(queue_free)
