#!/usr/bin/env bash

# Resolve project root directory
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENE_PATH="${1:-res://scenes/test.tscn}"

# Auto-detect Godot binary location
DEFAULT_STEAM_GODOT="/home/nataho/.local/share/Steam/steamapps/common/Godot Engine/godot.x11.opt.tools.64"

if [ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ]; then
    GODOT_EXEC="$GODOT_BIN"
elif [ -x "$DEFAULT_STEAM_GODOT" ]; then
    GODOT_EXEC="$DEFAULT_STEAM_GODOT"
elif command -v godot >/dev/null 2>&1; then
    GODOT_EXEC="$(command -v godot)"
elif command -v godot4 >/dev/null 2>&1; then
    GODOT_EXEC="$(command -v godot4)"
else
    echo "❌ Error: Could not find Godot executable!"
    echo "Please set GODOT_BIN environment variable, e.g.:"
    echo "  export GODOT_BIN='/path/to/godot'"
    exit 1
fi

echo "========================================================="
echo "🎮 Launching Godot Headless Test Arena"
echo "   Binary:  $GODOT_EXEC"
echo "   Project: $PROJECT_DIR"
echo "   Scene:   $SCENE_PATH"
echo "========================================================="
echo "Press Ctrl+C to stop the headless instance."
echo ""

# Run Godot headless
exec "$GODOT_EXEC" --path "$PROJECT_DIR" --headless "$SCENE_PATH" "${@:2}"
