class_name QueueSlot extends Control

@export var tile_texture: Texture2D # Any resolution atlas
@export var atlas_columns: int = 12 # Total tile frames in the row
@export var x_separation: float = 1.0 # Pixel gap between tiles

var current_grid: Array = []
var tile_index: int = 0

func render_ascii_piece(ascii_grid: Array, piece_tile_index: int = 0) -> void:
	current_grid = ascii_grid
	tile_index = piece_tile_index
	queue_redraw()

func _draw() -> void:
	if current_grid.is_empty() or not tile_texture or atlas_columns <= 0:
		return
		
	# 1. Calculate tile dimensions dynamically from texture dimensions
	var sheet_w: float = tile_texture.get_width()
	var sheet_h: float = tile_texture.get_height()
	
	var total_separation: float = (atlas_columns - 1) * x_separation
	var dynamic_tile_w: float = (sheet_w - total_separation) / float(atlas_columns)
	var dynamic_tile_h: float = sheet_h
	var calculated_tile_size := Vector2(dynamic_tile_w, dynamic_tile_h)
	
	# 2. Find active tile boundaries
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	var active_cells: Array[Vector2i] = []
	
	for y in range(current_grid.size()):
		var row: String = current_grid[y]
		for x in range(row.length()):
			if row[x] == '*' or row[x] == 'x':
				active_cells.append(Vector2i(x, y))
				min_pos.x = min(min_pos.x, x)
				max_pos.x = max(max_pos.x, x)
				min_pos.y = min(min_pos.y, y)
				max_pos.y = max(max_pos.y, y)
				
	if active_cells.is_empty(): 
		return
	
	# 3. Compute scale factor based on the dynamic tile size
	var piece_tile_width = (max_pos.x - min_pos.x) + 1.0
	var piece_tile_height = (max_pos.y - min_pos.y) + 1.0
	
	var piece_pixel_size = Vector2(piece_tile_width, piece_tile_height) * calculated_tile_size
	
	var scale_factor: float = min(
		size.x / piece_pixel_size.x if piece_pixel_size.x > 0 else 1.0,
		size.y / piece_pixel_size.y if piece_pixel_size.y > 0 else 1.0,
		1.0 # Prevents blowing up small retro textures beyond 100%
	)
	
	var draw_tile_size = calculated_tile_size * scale_factor
	var total_draw_size = Vector2(piece_tile_width, piece_tile_height) * draw_tile_size
	var center_start = (size - total_draw_size) / 2.0
	
	# 4. Slice the dynamic source rect from atlas
	var source_x = tile_index * (dynamic_tile_w + x_separation)
	var source_rect = Rect2(source_x, 0, dynamic_tile_w, dynamic_tile_h)
	
	# 5. Render active piece cells
	for cell in active_cells:
		var relative_cell = Vector2(cell.x - min_pos.x, cell.y - min_pos.y)
		var draw_pos = center_start + (relative_cell * draw_tile_size)
		var draw_rect = Rect2(draw_pos, draw_tile_size)
		
		draw_texture_rect_region(tile_texture, draw_rect, source_rect)
