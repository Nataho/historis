"""
Heuristic Environment Multi-Instance Launcher
=============================================
Launches Godot instance(s) running the heuristic recording environment scene in an infinite loop.

Usage:
    python run_heuristic_gen.py        # Runs 1 instance (default)
    python run_heuristic_gen.py 4      # Runs 4 instances concurrently
    python run_heuristic_gen.py 8      # Runs 8 instances
"""

import sys
import os
import time
import subprocess
import shutil

SCENE_PATH = "res://scenes/heuristic_environment/heuristic_environment.tscn"
DEFAULT_INSTANCES = 1
LAUNCH_DELAY_SEC = 0.25  # 250ms stagger between process spawns

def find_godot_executable() -> str:
    # 0. Check config file if present
    cfg_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "godot_path.txt")
    if os.path.isfile(cfg_file):
        with open(cfg_file, "r", encoding="utf-8") as f:
            p = f.read().strip().strip('"')
            if os.path.isfile(p):
                return p

    # 1. Environment variable override
    env_godot = os.environ.get("GODOT_BIN") or os.environ.get("GODOT_PATH")
    if env_godot and os.path.isfile(env_godot):
        return env_godot

    # 2. Check PATH
    for name in ["godot", "godot4", "godot_v4", "Godot"]:
        path = shutil.which(name)
        if path:
            return path

    # 3. Check common directories (including Steam libraries)
    base_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        r"A:\SteamLibrary\steamapps\common\Godot Engine",
        r"C:\Program Files (x86)\Steam\steamapps\common\Godot Engine",
        r"D:\SteamLibrary\steamapps\common\Godot Engine",
        r"E:\SteamLibrary\steamapps\common\Godot Engine",
        base_dir,
        os.path.dirname(base_dir),
        r"C:\Godot",
        r"D:\Godot",
        r"C:\Program Files\Godot",
        r"C:\Program Files (x86)\Godot",
        os.path.expanduser("~"),
        os.path.expanduser(r"~\Desktop"),
        os.path.expanduser(r"~\Downloads"),
    ]

    for c in candidates:
        if not os.path.exists(c):
            continue
        try:
            for item in os.listdir(c):
                if item.lower().startswith("godot") and item.lower().endswith(".exe"):
                    return os.path.join(c, item)
        except Exception:
            continue

    return None

def main():
    num_instances = DEFAULT_INSTANCES
    if len(sys.argv) > 1:
        try:
            num_instances = max(1, int(sys.argv[1]))
        except ValueError:
            print(f"[!] Invalid instance count '{sys.argv[1]}'. Defaulting to {DEFAULT_INSTANCES}.")

    godot_exe = find_godot_executable()
    if not godot_exe:
        print("[!] Godot executable not found on system PATH.")
        print("    Please do one of the following:")
        print("    1. Create a 'godot_path.txt' file in this folder containing the full path to Godot.exe")
        print("    2. Or set the GODOT_PATH environment variable (e.g., set GODOT_PATH=C:\\path\\to\\godot.exe)")
        sys.exit(1)
    project_dir = os.path.dirname(os.path.abspath(__file__))

    print("============================================================")
    print("  Tetris Heuristic Data Generator Runner")
    print("============================================================")
    print(f"  Instances: {num_instances}")
    print(f"  Delay:     {LAUNCH_DELAY_SEC}s per instance")
    print(f"  Godot Exe: {godot_exe}")
    print(f"  Mode:      Headless & Silent (Audio Disabled)")
    print(f"  Scene:     {SCENE_PATH}")
    print("============================================================")
    print("Press Ctrl+C at any time to stop all running instances.\n")

    def build_cmd():
        return [
            godot_exe,
            "--headless",
            "--audio-driver", "Dummy",
            "--path", project_dir,
            SCENE_PATH
        ]

    processes = []
    try:
        for i in range(num_instances):
            p = subprocess.Popen(build_cmd(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(p)
            print(f"[+] Launched Headless Instance {i+1}/{num_instances} (PID: {p.pid})")
            if i < num_instances - 1:
                time.sleep(LAUNCH_DELAY_SEC)

        print("\nAll instances running headlessly! Generating expert data to 'demos/'...")
        while True:
            for i, p in enumerate(processes):
                ret = p.poll()
                if ret is not None:
                    print(f"[!] Instance {i+1} finished/restarted. Relaunching in 0.25s...")
                    time.sleep(LAUNCH_DELAY_SEC)
                    new_p = subprocess.Popen(build_cmd(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    processes[i] = new_p
                    print(f"[+] Relaunched Instance {i+1} (New PID: {new_p.pid})")
            time.sleep(1.0)

    except KeyboardInterrupt:
        print("\n[!] Stopping all instances...")
        for p in processes:
            try:
                p.terminate()
            except Exception:
                pass
        print("[✓] All instances stopped.")

if __name__ == "__main__":
    main()
