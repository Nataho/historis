"""
Training Log Reader & Metric Diagnostic Tool for Tetris AI
==========================================================
Parses TensorBoard event files to track training progress,
episode length trends, reward progression, and diagnostic metrics.

Usage:
  python read_logs.py          # Show latest run metrics and health diagnosis
  python read_logs.py --all    # Show history across all previous runs
  python read_logs.py --watch  # Live monitor updating every 5 seconds
"""

import os
import sys
import glob
import time
import argparse
import numpy as np

# Ensure Windows terminal prints UTF-8 properly without charmap crashes
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

try:
    from tensorboard.backend.event_processing.event_accumulator import EventAccumulator
except ImportError:
    print("Error: Tensorboard is required. Run 'pip install tensorboard'")
    exit(1)

TB_DIR = "tb_logs"

def get_event_files():
    pattern = os.path.join(TB_DIR, "**", "events.out.tfevents*")
    files = glob.glob(pattern, recursive=True)
    files = [f for f in files if os.path.isfile(f) and os.path.getsize(f) > 100]
    files.sort(key=os.path.getmtime)
    return files

def parse_run(event_file):
    ea = EventAccumulator(event_file)
    ea.Reload()
    
    tags = ea.Tags().get("scalars", [])
    data = {}
    for tag in tags:
        scalars = ea.Scalars(tag)
        data[tag] = {s.step: s.value for s in scalars}
    return data

def analyze_and_print_run(event_file, run_idx=1, total_runs=1):
    file_name = os.path.basename(event_file)
    file_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(event_file)))
    file_size_kb = os.path.getsize(event_file) / 1024.0

    print("=" * 105)
    print(f"📊 RUN [{run_idx}/{total_runs}]: {file_name}")
    print(f"   Last Updated: {file_time} | File Size: {file_size_kb:.1f} KB")
    print("=" * 105)

    data = parse_run(event_file)
    if not data or "rollout/ep_len_mean" not in data:
        print("   (No episode rollout metrics recorded in this event file yet)")
        return

    ep_lens = data.get("rollout/ep_len_mean", {})
    ep_rews = data.get("rollout/ep_rew_mean", {})
    ent_losses = data.get("train/entropy_loss", {})
    kl_divs = data.get("train/approx_kl", {})
    v_losses = data.get("train/value_loss", {})
    p_losses = data.get("train/policy_gradient_loss", {})
    fps_vals = data.get("time/fps", {})
    lrs = data.get("train/learning_rate", {})

    steps = sorted(ep_lens.keys())
    if not steps:
        print("   (No completed rollout steps found)")
        return

    # Header table
    print(f"{'Step':>8} | {'Avg Steps':>10} | {'Avg Reward':>12} | {'Entropy':>10} | {'Approx KL':>10} | {'Value Loss':>12} | {'Pol Loss':>10} | {'FPS':>6}")
    print("-" * 105)

    len_list = []
    rew_list = []

    for s in steps:
        l = ep_lens.get(s, float('nan'))
        r = ep_rews.get(s, float('nan'))
        ent = ent_losses.get(s, float('nan'))
        kl = kl_divs.get(s, float('nan'))
        vl = v_losses.get(s, float('nan'))
        pl = p_losses.get(s, float('nan'))
        fps = fps_vals.get(s, float('nan'))

        len_list.append(l)
        rew_list.append(r)

        # Highlight trend in output
        len_str = f"{l:>10.2f}"
        rew_str = f"{r:>12.2f}"
        ent_str = f"{ent:>10.4f}" if not np.isnan(ent) else f"{'--':>10}"
        kl_str = f"{kl:>10.4f}" if not np.isnan(kl) else f"{'--':>10}"
        vl_str = f"{vl:>12.2f}" if not np.isnan(vl) else f"{'--':>12}"
        pl_str = f"{pl:>10.4f}" if not np.isnan(pl) else f"{'--':>10}"
        fps_str = f"{int(fps):>6d}" if not np.isnan(fps) else f"{'--':>6}"

        print(f"{s:8d} | {len_str} | {rew_str} | {ent_str} | {kl_str} | {vl_str} | {pl_str} | {fps_str}")

    print("-" * 105)

    # Statistical Summary & Diagnostic
    first_len = len_list[0]
    last_len = len_list[-1]
    max_len = np.max(len_list)
    min_len = np.min(len_list)

    first_rew = rew_list[0]
    last_rew = rew_list[-1]
    max_rew = np.max(rew_list)
    min_rew = np.min(rew_list)

    print("\n📈 [SUMMARY STATS]")
    print(f"   • Steps / Survival: Start = {first_len:.1f} | Peak = {max_len:.1f} | Current = {last_len:.1f} | Low = {min_len:.1f}")
    print(f"   • Reward:           Start = {first_rew:.1f} | Peak = {max_rew:.1f} | Current = {last_rew:.1f}")

    # Root Cause Diagnostic Analysis
    print("\n🔍 [TRAINING HEALTH DIAGNOSIS]")
    
    # 1. Episode Length Dropping
    if last_len < first_len:
        drop_pct = ((first_len - last_len) / first_len) * 100.0
        print(f"   ⚠️  EPISODE LENGTH DECREASED: Dropped by {drop_pct:.1f}% (from {first_len:.1f} down to {last_len:.1f} steps).")
    elif last_len > first_len:
        gain_pct = ((last_len - first_len) / first_len) * 100.0
        print(f"   ✅  EPISODE LENGTH IMPROVED: Increased by {gain_pct:.1f}% (from {first_len:.1f} up to {last_len:.1f} steps).")

    # 2. Entropy collapse check
    recent_ent = [ent_losses[s] for s in steps if s in ent_losses]
    if recent_ent:
        curr_ent = recent_ent[-1]
        # SB3 logs entropy loss as -entropy, so entropy = -loss
        actual_entropy = -curr_ent
        if actual_entropy < 1.0:
            print(f"   ⚠️  LOW POLICY ENTROPY ({actual_entropy:.2f}): The policy may be prematurely collapsing to repetitive / rigid moves (e.g. always dumping pieces into the same column). Increasing ent_coef or lowering learning rate helps maintain exploration.")
        else:
            print(f"   ✅  Policy Entropy Healthy ({actual_entropy:.2f}): Exploration active across the 80 actions.")

    # 3. Value Loss explosion check
    recent_vl = [v_losses[s] for s in steps if s in v_losses]
    if recent_vl:
        curr_vl = recent_vl[-1]
        if curr_vl > 2000.0:
            print(f"   ⚠️  HIGH VALUE LOSS ({curr_vl:.1f}): The critic network is having difficulty predicting returns, likely due to large reward spikes (e.g. -600 top-out penalties vs +1 step rewards).")
        else:
            print(f"   ✅  Value Loss Stable ({curr_vl:.1f}).")

    # 4. KL Divergence / Policy Drift check
    recent_kl = [kl_divs[s] for s in steps if s in kl_divs]
    if recent_kl:
        curr_kl = recent_kl[-1]
        if curr_kl > 0.05:
            print(f"   ⚠️  HIGH APPROX KL ({curr_kl:.4f}): Policy updates are taking large jumps per epoch, which can destabilize learned strategies.")
        else:
            print(f"   ✅  Approx KL Divergence Stable ({curr_kl:.4f}).")

    print("=" * 105 + "\n")

def main():
    parser = argparse.ArgumentParser(description="Tetris AI Training Log Reader & Diagnostic Tool")
    parser.add_argument("--all", action="store_true", help="Display all previous run logs")
    parser.add_argument("--watch", action="store_true", help="Live watch mode (refreshes every 5s)")
    parser.add_argument("--interval", type=int, default=5, help="Watch refresh interval in seconds")
    args = parser.parse_args()

    while True:
        files = get_event_files()
        if not files:
            print(f"No TensorBoard event files found in {TB_DIR}/")
            if args.watch:
                time.sleep(args.interval)
                continue
            return

        if args.watch:
            # Clear console for clean live monitoring
            os.system("cls" if os.name == "nt" else "clear")
            print(f"🔄 [LIVE TRAINING MONITOR] - Watching latest run (Refresh: {args.interval}s, Ctrl+C to exit)\n")

        if args.all:
            for i, f in enumerate(files, 1):
                analyze_and_print_run(f, i, len(files))
        else:
            latest = files[-1]
            analyze_and_print_run(latest, len(files), len(files))

        if not args.watch:
            break
        time.sleep(args.interval)

if __name__ == "__main__":
    main()
