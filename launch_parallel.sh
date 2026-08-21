#!/usr/bin/env bash

GODOT_BIN="/home/nataho/.local/share/Steam/steamapps/common/Godot Engine/godot.x11.opt.tools.64"
PROJECT_PATH="/home/nataho/Godot/historis"
SCENE_PATH="res://classes/boards/bots/TrainingBotBoard/TrainingBotBoard.tscn"

NUM_ENVS="${1:-14}"
PORT="${2:-11000}"

echo "Launching $NUM_ENVS silent headless Godot instance(s) targeting port $PORT..."

PIDS=()
for i in $(seq 1 $NUM_ENVS); do
    "$GODOT_BIN" --path "$PROJECT_PATH" --headless --quiet "$SCENE_PATH" -- --port="$PORT" > /dev/null 2>&1 &
    PIDS+=($!)
done

echo "Started PIDs: ${PIDS[*]}"
echo "Now run train.py in another terminal. Press Ctrl+C here to stop all instances."

trap 'echo "Stopping all instances..."; kill "${PIDS[@]}" 2>/dev/null' INT TERM
wait