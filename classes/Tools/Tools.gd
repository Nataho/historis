class_name Tools

static func read_json(path:String):
	if not FileAccess.file_exists(path):
		printerr("Error: File does not exist at ", path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text()

	var parsed_data = JSON.parse_string(text)

	if parsed_data is Dictionary:
		return parsed_data
	else:
		printerr("Error: JSON at ", path, " is not formatted as a Dictionary/Object.")
		return {}
