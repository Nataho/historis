# Historis — Tetris AI Training: Context & Continuation Instructions

> **Last Updated:** 2026-08-22
> **Author:** AI assistant handoff document for future AI sessions
> **Project:** Historis — a Godot 4 Tetris VS game with an RL-trained bot

---

## 1. Project Overview

Historis is a **competitive Tetris VS game** built in Godot 4 (GDScript). It includes:
- Local/multiplayer human play
- A **heuristic bot** (TetrisBot) that uses beam-search + evaluation function
- An **ONNX-based ML bot** (OnnxBotBoard) for inference in-game
- A **PPO training pipeline** (Python, Stable-Baselines3) that communicates with Godot over TCP sockets
- A **behavior cloning (BC) pretrainer** that learns from recorded expert demos
- A **heuristic data generator** that records the heuristic bot's play as BC training data

The user's primary goal is to train an RL bot that plays Tetris competently — clearing lines, using hold, rotating pieces, and surviving long games. **The current trained model is broken** (see Section 4).

---

## 2. Relevant Files — Machine Learning Pipeline

### Python Scripts (project root)

| File | Purpose |
|------|---------|
| `train.py` | **Main PPO training server.** Listens on TCP port 11000 for Godot instance(s). Uses SB3's PPO with a custom `VecEnv` that wraps Godot socket communication. Exports ONNX models for in-game inference. |
| `train_bc.py` | **Behavior Cloning pretrainer.** Loads `.bin` demo files from `demos/`, trains the PPO policy network via supervised cross-entropy loss, saves checkpoint to `ai_models/tetris_bot_bc.zip`. |
| `read_logs.py` | **TensorBoard log reader & diagnostic.** Parses `tb_logs/` event files, prints training metrics (episode length, reward, entropy, KL, value loss), and runs health checks. |
| `run_heuristic_gen.py` | **Multi-instance headless data generator runner.** Launches $N$ Godot instances running `heuristic_environment.tscn` headlessly/silently with a 0.25s staggered start and auto-relaunch loop. Supports custom Godot executable detection (Steam / PATH / `godot_path.txt`). |
| `run_heuristic_gen.bat` | **Batch launcher for data generator.** Forwards CLI arguments to `run_heuristic_gen.py` (e.g., `run_heuristic_gen.bat 4`). |
| `godot_path.txt` | **Godot executable pointer.** Contains absolute path to Godot binary (e.g. Steam Godot path). |

### Key Scenes & UI

| Scene File | Purpose |
|------------|---------|
| `scenes/heuristic_environment/heuristic_environment.tscn` | **Headless Heuristic Battle Arena.** Houses 2 battling `HeuristicDataGenerator` boards (Player 1 & 2) in continuous 1v1 play to record diverse expert moves and garbage downstacking. |
| `scenes/battle/battle.tscn` | Standard 1v1 battle scene for player vs player or player vs bot. |
| `scenes/main/main.tscn` | Main menu & game entry point. |

| File | Purpose |
|------|---------|
| `classes/boards/Board/board.gd` | **Base Board class.** Contains `get_observation_vector()` (413-float obs encoding), `decode_action()` / `encode_action()` (action idx 0-79 ↔ {column, rotation, hold}), and `_get_board_metrics()`. |
| `classes/boards/bots/OnnxBotBoard/OnnxBotBoard.gd` | **ONNX inference bot.** Loads `.onnx` model, runs inference, executes actions with optional visual handling delays. Contains `execute_action()` which translates decoded actions into engine moves (rotation via SRS kicks, horizontal movement, hold, hard drop). Also has `_tally_prediction()` for column/hold distribution tracking. |
| `classes/boards/bots/TrainingBotBoard/TrainingBotBoard.gd` | **Training environment board.** Extends OnnxBotBoard. TCP client connecting to `train.py`. Runs the step loop: send obs+reward+done → receive action → execute → compute reward. Contains the full **reward shaping system** with curriculum presets (Stage 1/2/3). |
| `classes/boards/bots/HeuristicDataGenerator/HeuristicDataGenerator.gd` | **BC data recorder.** Runs the heuristic TetrisBot, records `(obs, action_idx)` pairs to `.bin` files in `demos/` for behavior cloning training. |
| `classes/TetrisBot/TetrisBot.gd` | **Heuristic bot brain.** Beam-search with lookahead. Evaluates placements based on: line clears, T-spin/all-spin detection, hole count, bumpiness, stack height, blockades, well management. Uses BFS reachability checking. This is the "expert" that generates BC training data. |
| `classes/TetrisEngine/TetrisEngine.gd` | **Core Tetris engine.** Grid management, piece spawning, rotation (SRS + 180 kicks), gravity, line clearing, garbage system, hold queue, combo/B2B tracking. |

### Model & Data Directories

| Directory | Contents |
|-----------|----------|
| `ai_models/` | `tetris_ppo.zip` (PPO checkpoint), `tetris_bot.onnx` (live ONNX export), `tetris_bot_best.onnx` (best score ONNX), `tetris_bot_bc.zip` (BC checkpoint), `best_score.json` |
| `tb_logs/` | TensorBoard event files. Single run directory `ppo_tetris_0/` with ~109 event files spanning the full training history. |
| `demos/` | BC training data directory (currently empty — no demo files present). |
| `log_viewer/` | Web-based TensorBoard log viewer (HTML + Python server). |

---

## 3. Technical Architecture

### Observation Space (413 floats)

```
Index Range   | Size | Description
0..199        | 200  | Grid cells: binary (0=empty, 1=filled), row-major, 20×10
200..202      |   3  | Board metrics: max_height/20, holes/20, bumpiness/40
203..209      |   7  | Active piece one-hot: [I, J, L, O, S, T, Z]
210..244      |  35  | Preview queue one-hot: 5 pieces × 7 types
245..251      |   7  | Hold piece one-hot
252..255      |   4  | Status: can_hold, pending_garbage/20, b2b_streak/10, combo/10
256..395      | 140  | Opponent grid bottom 14 rows (binary, 14×10) — zeros if no opponent
396..399      |   4  | Opponent metrics: height, holes, bumpiness, garbage
400..406      |   7  | Opponent active piece one-hot
407..408      |   2  | Opponent b2b_streak/10, knockouts/10
409..412      |   4  | Padding zeros
```

### Action Space (Discrete 80)

```
action_idx (0-79) = hold_offset + rotation * 10 + column

hold_offset: 0 = no hold, 40 = use hold
rotation:    0-3 (0=spawn, 1=CW, 2=180, 3=CCW)
column:      0-9 (target x position)

decode: use_hold = (idx >= 40), local = idx % 40, col = local % 10, rot = local / 10
encode: local = rot * 10 + col, idx = local + (40 if hold else 0)
```

### Network Architecture

```
Actor:  Linear(413, 256) → ReLU → Linear(256, 256) → ReLU → Linear(256, 128) → ReLU → Linear(128, 80)
Critic: Linear(413, 256) → ReLU → Linear(256, 256) → ReLU → Linear(256, 128) → ReLU → Linear(128, 1)
```

### Training Hyperparameters (current in train.py)

```python
ent_coef = 0.025        # Has been raised multiple times, was insufficient
learning_rate = 5e-5
gamma = 0.99
n_epochs = 4
target_kl = 0.02
max_grad_norm = 0.5
n_steps = 1024          # Per environment
batch_size = 512
REWARD_SCALE = 0.1      # All rewards from Godot are multiplied by 0.1 for critic stability
```

### Reward Shaping (Stage 1 — Survival Mastery, currently active)

```
Per-step survival:        +1.0
Low stack (≤6):           +0.25
Hold usage:               +0.20
Hard drop per tile:       +0.02
Hole created:             -4.5 per hole
Hole cleared:             +5.5 per hole
Bumpiness increase:       -0.20 per unit
Bumpiness decrease:       +0.20 per unit
Covered cells penalty:    -0.5 per block above hole
Upstack (moderate):       -0.35 per height unit
Upstack (danger, >13):    -1.2 per unit
Downstack:                +2.5 per unit (×1.8 in danger zone)
Ceiling (≥17):            -2.5 per step
Line clears:              +3.5 / +7.0 / +12.0 / +20.0 (single/double/triple/quad)
T-spin:                   +4.0 × lines cleared
Combo:                    +0.5 × combo count
B2B bonus:                min(b2b × 1.0, 5.0)
Perfect clear:            +50.0
Milestones:               +10/+20/+40/+75/+100 at steps 50/100/250/500/750
Max steps (1000):         +150.0 bonus, then episode resets
Game over:                -200.0 (×3.0 if early topout <60 steps, with dynamic scaling)
Invalid action snap:      -1.0
```

All rewards are ×0.1 by REWARD_SCALE in train.py before reaching PPO.

### TCP Protocol (train.py ↔ Godot)

```
Godot → Python:  [4 bytes float: reward] [4 bytes int: done_flag] [413 × 4 bytes float: obs]
Python → Godot:  [4 bytes int: action_idx]
```

---

## 4. CURRENT CRITICAL PROBLEM: Policy Collapse

### What's happening

After 43M+ training steps, the PPO policy has **collapsed into a degenerate lookup table** that maps piece type → fixed (column, rotation) while completely ignoring the grid state. The bot:

- **Never uses hold** (0% for 6/7 piece types, ~4% overall across random boards)
- **Never rotates** (rotation 0 for almost everything)
- **Maps each piece to 1-2 fixed columns** regardless of board state
- Only uses **25 out of 80 possible actions**
- Has per-piece entropy as low as **0.003** (uniform would be 4.38)

### Diagnostic evidence (from probing checkpoint weights)

**Empty board per-piece behavior:**
```
I → col 4, rot 0, no hold (100% probability)
J → col 8, rot 0, no hold (99.9%)
L → col 8, rot 0, no hold (99.5%)
O → col 0, rot 0, no hold (99.9%)
S → col 4, rot 0, no hold (65.4%)
T → col 4, rot 0, no hold (86.0%)
Z → col 8, rot 0, no hold (100%)
```

The network learned to route the 7-float one-hot piece encoding (obs indices 203-209) directly to logits while zeroing out the grid's influence.

### What has already been tried (and failed)

1. **Raising `ent_coef` multiple times** — went from default up to 0.025+. Did not help because the weights are already 43M steps deep into the collapsed local minimum. Entropy penalty gradient is too small to overcome the entrenched piece→action mapping.

2. **Continued training from the same checkpoint** — every restart loads `tetris_ppo.zip` which contains the collapsed weights. No amount of hyperparameter adjustment can rescue a policy this deeply locked in.

### Why `ent_coef` alone cannot fix this

- The flat `Discrete(80)` action space allows the network to discover a trivial shortcut: read the 7-float one-hot piece vector, output a single fixed action index. The 200-float grid is ignored because the shortcut provides enough reward (survives ~95 steps by distributing pieces across columns).
- Hold actions (indices 40-79) get essentially zero probability mass, so no gradient signal ever flows through them — exploration death spiral.
- The collapsed policy is a **deep local minimum**, not a temporary exploration dip.

---

## 5. Recommended Fix: MultiDiscrete Action Space

The **structural root cause** is that `Discrete(80)` lets the network memorize `piece_type → action_idx` as a single-neuron shortcut. The strongest fix is to split the action space into independent decision heads:

### Option A: MultiDiscrete (Recommended — strongest structural fix)

Replace `Discrete(80)` with `MultiDiscrete([10, 4, 2])`:
- **Column head** (0-9): which column to target
- **Rotation head** (0-3): which rotation state
- **Hold head** (0-1): whether to use hold

This forces the network to make 3 separate decisions with independent gradient signals. The hold head gets its own binary cross-entropy gradient on every step, making it impossible to "forget" about hold.

**Files that need modification:**
1. `train.py` — Change `action_space`, adjust action sending/receiving (3 ints instead of 1)
2. `board.gd` — Update `decode_action()` / `encode_action()` to handle 3-element arrays
3. `TrainingBotBoard.gd` — Update TCP protocol to send/receive 3 ints, update `_step_ai()`
4. `OnnxBotBoard.gd` — Update ONNX inference to handle 3 output heads
5. `train_bc.py` — Update BC training target encoding
6. `HeuristicDataGenerator.gd` — Update sample recording format

### Option B: Fresh start from BC with conservative fine-tuning

1. Generate BC training data using HeuristicDataGenerator (currently no demo files exist in `demos/`)
2. Run `python train_bc.py` to pretrain
3. Run `python train.py --reset-to-bc` with very conservative hyperparameters (target_kl=0.005, ent_coef=0.05, n_epochs=2)

### Option C: Nuclear reset with higher ent_coef schedule

Delete `tetris_ppo.zip`, start fresh with `ent_coef` on a linear decay schedule (0.1 → 0.01 over 10M steps). Less effective than MultiDiscrete but less invasive.

### Also consider: Action Masking

Use SB3-contrib's `MaskablePPO` to mask out physically impossible placements (invalid column/rotation combos for each piece type). This reduces the effective action space and prevents the network from wasting capacity learning "don't pick impossible actions."

---

## 6. Other Useful Context

### Running training
```bash
# Start PPO training server (waits for Godot to connect)
python train.py

# Start fresh from BC weights (if available)
python train.py --reset-to-bc

# Read training logs
python read_logs.py          # Latest run
python read_logs.py --all    # All runs
python read_logs.py --watch  # Live monitoring
```

### The heuristic bot (TetrisBot.gd) is very strong
- Uses depth-2 beam search with beam width 8
- Scores placements on: holes (×75,000), bumpiness, T-spin slots (×30,000), all-spin slots (×12,000), quad clears (×65,000), stack height, secondary well penalties, spire penalties
- Handles SRS rotation with full kick table awareness
- BFS reachability checking for tucks, overhangs, and spin placements
- This bot generates the BC training data and is the quality bar the RL bot should approach

### Current training stats (latest run, 43M steps)
```
Episode length:  ~90-96 steps (plateaued, should be 500-1000+)
Average reward:  -140 to -160 (consistently negative due to frequent topouts)
Policy entropy:  0.14 (severely collapsed — should be >1.0 for healthy exploration)
Value loss:      ~12 (stable, not an issue)
Approx KL:       ~0.006 (stable, not an issue)
```

### Reward scaling note
All rewards from Godot are multiplied by `REWARD_SCALE = 0.1` in train.py before reaching PPO. This is intentional to keep value loss manageable (the raw game-over penalty is -200, which becomes -20 after scaling).

### The CloobBotBoard
There's also a `CloobBotBoard.gd` in `classes/boards/bots/cloob/` — this appears to be another bot variant. May be worth checking for reference but is not part of the current training pipeline.

---

## 7. Quick Reference: Class Hierarchy & Scene Mapping
 
 ```
 Board (classes/boards/Board/board.gd)
 ├── LocalBoard (classes/boards/LocalBoard/LocalBoard.gd) — Human-controlled board
 ├── MultiplayerBoard (classes/boards/MultiplayerBoard/MultiplayerBoard.gd) — Network-synced board
 ├── NetworkBoard (classes/boards/NetworkBoard/NetworkBoard.gd) — Remote player display
 ├── HeuristicDataGenerator (classes/boards/bots/HeuristicDataGenerator/HeuristicDataGenerator.gd) — BC data recorder (extends Board)
 └── OnnxBotBoard (classes/boards/bots/OnnxBotBoard/OnnxBotBoard.gd) — ONNX inference bot
     └── TrainingBotBoard (classes/boards/bots/TrainingBotBoard/TrainingBotBoard.gd) — PPO training environment
         (also has CloobBotBoard as a sibling under classes/boards/bots/cloob/)

TetrisBot (classes/TetrisBot/TetrisBot.gd) — Standalone heuristic brain (RefCounted, beam search + reachability)
TetrisEngine (classes/TetrisEngine/TetrisEngine.gd) — Core game logic
PiecesController (classes/controllers/PiecesController/PiecesController.gd) — SRS kick tables (KICKS_JLSTZ, KICKS_I, KICKS_180_*), rotation offsets
```

---

## 8. Session Changelog & History (2026-08-22)

### Summary of Changes Made:
1. **Multi-Instance Headless Data Generator Setup**:
   - Created `run_heuristic_gen.py` to spawn $N$ instances (default: 1, supports e.g. `python run_heuristic_gen.py 4`).
   - Added `0.25s` delay between launches to stagger initialization.
   - Added process monitor loop: when an instance finishes its target games, it is automatically relaunched in 0.25s.
   - Configured headless mode (`--headless`) and dummy audio driver (`--audio-driver Dummy`) with `DEVNULL` redirection for silent, low-resource background execution.
   - Created `run_heuristic_gen.bat` for quick double-click / CMD execution.
   - Added `godot_path.txt` and automated detection for Steam Godot installations (`A:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`).

2. **Collision-Proof Demo Recording**:
   - Modified `HeuristicDataGenerator.gd` (`_start_new_demo_file()`):
   - Added high-resolution millisecond timestamps (`Time.get_ticks_msec()`), OS Process ID (`OS.get_process_id()`), `player_id`, and random salt to prevent concurrent file overwrite when multiple instances run simultaneously.

3. **Super Rotation System (SRS) & Border Compliance Verification**:
   - Confirmed that `TetrisBot.gd` (`_is_reachable_bfs` and `_evaluate_reachability`) directly queries `PiecesController.gd` for official SRS kicks (`KICKS_JLSTZ`, `KICKS_I`, `KICKS_180_*`).
   - Verified that `HeuristicDataGenerator.gd` uses `TetrisBot.gd` on every step, guaranteeing that all generated training demos in `demos/` are 100% boundary-legal and SRS-compliant.

### Complete End-to-End Workflow:
```bash
# 1. Run 4 headless data generator instances to record expert demos (target: ~200k-500k samples):
python run_heuristic_gen.py 4

# 2. Train policy network using Behavior Cloning (pretraining):
python train_bc.py

# 3. Fine-tune with PPO starting from BC checkpoint:
python train.py --reset-to-bc

# 4. Monitor training metrics:
python read_logs.py --watch
```
