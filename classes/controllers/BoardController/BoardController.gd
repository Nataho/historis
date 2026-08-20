extends TileMapLayer
class_name BoardController

var start_point:Vector2i
var grid_size:Vector2i
var pieces_controller: PiecesController
var placed_tiles_layer:TileMapLayer

var border_coords := Vector2i(9,0)
var grid_coords := Vector2(10,0)

func clear_board():
	clear()

func setup_board(grid_size:Vector2i):
	self.grid_size = grid_size
	clear_board()
	get_start_point(grid_size)
	_draw_border()
	_draw_grid()
	
#region setup_board() functions
func get_start_point(grid_size:Vector2i):
	var gridx = grid_size.x
	var gridy = grid_size.y
	
	var startx = gridx/2 * -1
	var starty = gridy/2 * -1
	
	start_point = Vector2i(startx, starty)
	
func _draw_border():
	var start = start_point - Vector2i(1, 1)
	var end = start_point + grid_size
	
	for x in range(start.x, end.x + 1):
		set_cell(Vector2i(x, start.y), 0, border_coords)
		set_cell(Vector2i(x, end.y), 0, border_coords)
		
	for y in range(start.y, end.y + 1):
		set_cell(Vector2i(start.x, y), 0, border_coords) 
		set_cell(Vector2i(end.x, y), 0, border_coords)

func _draw_grid():
	for y in range(grid_size.y):
		for x in range(grid_size.x):
			var target_pos = start_point + Vector2i(x, y)
			set_cell(target_pos, 0, grid_coords)
			
			await get_tree().create_timer(0.005).timeout
#endregion setup_board() functions

#region reference setters
func set_pieces_controller(pieces_controller:PiecesController):
	self.pieces_controller = pieces_controller
	
func set_placed_tiles(placed_tiles_reference:TileMapLayer):
	placed_tiles_layer = placed_tiles_reference
#endregion reference setters
