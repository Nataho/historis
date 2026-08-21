"""
Tetris VS-Bot PPO Training Server (Always-On High Score Tracking)
========================================================================
"""

import argparse
import os
import json
import socket
import struct
import time
import traceback
import warnings

import numpy as np
import torch
import gymnasium as gym
from gymnasium import spaces
from stable_baselines3 import PPO
from stable_baselines3.common.vec_env.base_vec_env import VecEnv
from stable_baselines3.common.callbacks import BaseCallback

# Suppress PyTorch ONNX export deprecation warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=UserWarning)

HOST = "127.0.0.1"
PORT = 11000

def get_device(requested: str = "auto") -> tuple[str, str]:
    if requested == "cuda" or (requested == "auto" and torch.cuda.is_available()):
        if torch.cuda.is_available():
            dev_name = torch.cuda.get_device_name(0)
            return "cuda", f"GPU / CUDA ({dev_name})"
        else:
            log("⚠️  CUDA requested but not available. Falling back to CPU.")

    # CPU mode: multi-threaded optimization
    threads = min(8, os.cpu_count() or 4)
    torch.set_num_threads(threads)
    return "cpu", f"CPU ({threads} threads / {os.cpu_count()} logical cores)"

DEVICE, DEVICE_LABEL = get_device("auto")

OBS_SIZE = 413
HEADER_SIZE = 8
OBS_BYTES = OBS_SIZE * 4
ACTION_SPACE_SIZE = 80

MODEL_DIR = "ai_models"
ONNX_PATH = os.path.join(MODEL_DIR, "tetris_bot.onnx")
BEST_ONNX_PATH = os.path.join(MODEL_DIR, "tetris_bot_best.onnx")
CHECKPOINT_PATH = os.path.join(MODEL_DIR, "tetris_ppo.zip")
BC_CHECKPOINT_PATH = os.path.join(MODEL_DIR, "tetris_bot_bc.zip")  # produced by train_bc.py
HIGH_SCORE_FILE = os.path.join(MODEL_DIR, "best_score.json")
TENSORBOARD_DIR = "tb_logs"

# --- ANSI Terminal Color Codes ----------------------------------------
COLOR_RESET = "\033[0m"
COLOR_BLUE = "\033[94m"
COLOR_GREEN = "\033[92m"
COLOR_YELLOW_BOLD = "\033[1;93m"  # Fixed ANSI syntax

REWARD_SCALE = 0.1                 # Scales reward for Critic stability (avoids Value Loss explosion)

# --- Logging & Export Knobs -------------------------------------------
N_STEPS = 1024                       # Increased for GPU throughput
SOCKET_TIMEOUT_SEC = 20.0

SHOW_STEP_LOGS = False              # Set True to see individual step actions
LOG_ONLY_NONZERO_STEPS = True       # If SHOW_STEP_LOGS is True, ignores 0.0 reward steps
MIN_EPISODE_REWARD_TO_LOG = -600.0  # Filters out normal non-record death episodes

SILENT_CHECKPOINTS = False           # Suppresses export logs during routine saves
CHECKPOINT_FREQ_STEPS = 10000       # Saves in background every 10,000 steps


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def load_persistent_high_score() -> float:
    if os.path.exists(HIGH_SCORE_FILE):
        try:
            with open(HIGH_SCORE_FILE, "r") as f:
                data = json.load(f)
                return float(data.get("high_score", -float("inf")))
        except Exception:
            pass
    return -float("inf")


def save_persistent_high_score(score: float) -> None:
    os.makedirs(MODEL_DIR, exist_ok=True)
    with open(HIGH_SCORE_FILE, "w") as f:
        json.dump({"high_score": float(score)}, f)


class TetrisVecEnv(VecEnv):
    def __init__(self, host: str = "127.0.0.1", port: int = 11000, discovery_timeout: float = 3.0):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((host, port))
        server.listen(128)

        log(f"Listening on {host}:{port} — waiting for Godot instance(s)...")

        self.conns: list[socket.socket] = []

        # 1. Wait for the FIRST Godot instance
        server.settimeout(60.0)
        try:
            conn, addr = server.accept()
            conn.settimeout(SOCKET_TIMEOUT_SEC)
            self.conns.append(conn)
            log(f"[env 0] ✅ Connected: {addr}")
        except socket.timeout:
            server.close()
            raise TimeoutError("No Godot instances connected within 60 seconds.")

        # 2. Gather remaining instances in discovery window
        server.settimeout(discovery_timeout)
        while True:
            try:
                conn, addr = server.accept()
                conn.settimeout(SOCKET_TIMEOUT_SEC)
                self.conns.append(conn)
                log(f"[env {len(self.conns)-1}] ✅ Connected: {addr}")
            except socket.timeout:
                break

        server.close()

        num_envs = len(self.conns)
        log(f"⚡ Auto-Discovered {num_envs} Godot environment(s)! Initializing PPO with NUM_ENVS = {num_envs}.")

        observation_space = spaces.Box(
            low=0.0, high=999.0, shape=(OBS_SIZE,), dtype=np.float32
        )
        action_space = spaces.Discrete(ACTION_SPACE_SIZE)
        super().__init__(num_envs, observation_space, action_space)

        self._pending_reset_obs: list = [None] * num_envs
        self._episode_count = [0] * num_envs
        self._episode_reward = [0.0] * num_envs
        self._episode_steps = [0] * num_envs
        self._global_step = 0
        self._actions = None
        
        # Load high score record from disk across script restarts
        self.high_score = load_persistent_high_score()
        self.new_high_score_flag = False
        if self.high_score != -float("inf"):
            log(f"🏆 Loaded All-Time High Score Baseline: {self.high_score:+.1f}")

    def _recv_exact(self, idx: int, n: int) -> bytes:
        conn = self.conns[idx]
        buf = b""
        while len(buf) < n:
            try:
                chunk = conn.recv(n - len(buf))
            except socket.timeout:
                log(f"[env {idx}] ⏱️  TIMEOUT after {SOCKET_TIMEOUT_SEC}s.")
                raise
            if not chunk:
                raise ConnectionError(f"Godot instance {idx} closed the connection.")
            buf += chunk
        return buf

    def _recv_packet(self, idx: int):
        header = self._recv_exact(idx, HEADER_SIZE)
        raw_reward, done_flag = struct.unpack("<fi", header)
        obs_bytes = self._recv_exact(idx, OBS_BYTES)
        obs = np.frombuffer(obs_bytes, dtype=np.float32).copy()
        
        # Scaled reward for Critic stability (100x lower Value MSE loss)
        ppo_reward = float(raw_reward) * REWARD_SCALE
        return ppo_reward, bool(done_flag), obs, float(raw_reward)

    def _send_action(self, idx: int, action_idx: int) -> None:
        self.conns[idx].sendall(struct.pack("<i", int(action_idx)))

    def reset(self):
        obs_list = []
        for i in range(self.num_envs):
            if self._pending_reset_obs[i] is not None:
                obs = self._pending_reset_obs[i]
                self._pending_reset_obs[i] = None
            else:
                log(f"[env {i}] reset(): waiting for initial board packet...")
                _, _, obs, _ = self._recv_packet(i)
            self._episode_count[i] += 1
            self._episode_reward[i] = 0.0
            self._episode_steps[i] = 0
            obs_list.append(obs)
        return np.stack(obs_list)

    def step_async(self, actions) -> None:
        self._actions = actions
        for i in range(self.num_envs):
            self._send_action(i, int(actions[i]))

    def step_wait(self):
        obs_list, reward_list, done_list, infos = [], [], [], []
        for i in range(self.num_envs):
            reward, done, obs, raw_reward = self._recv_packet(i)
            self._global_step += 1
            self._episode_steps[i] += 1
            self._episode_reward[i] += raw_reward

            info = {}

            if SHOW_STEP_LOGS:
                if not LOG_ONLY_NONZERO_STEPS or raw_reward != 0.0:
                    log(
                        f"[env {i}] step(global={self._global_step}) "
                        f"ep={self._episode_count[i]} ep_step={self._episode_steps[i]:>4} "
                        f"action={int(self._actions[i]):>2} reward={raw_reward:+7.1f} done={int(done)}"
                    )

            if done:
                ep_reward = self._episode_reward[i]
                ep_steps = self._episode_steps[i]
                ep_num = self._episode_count[i]

                base_str = f"[env {i}] ep {ep_num:>3} finished | steps: {ep_steps:>4} | TOTAL REWARD: {ep_reward:+.1f}"

                # Persist score to disk on new record
                if ep_reward > self.high_score:
                    self.high_score = ep_reward
                    save_persistent_high_score(self.high_score)
                    self.new_high_score_flag = True
                    log(f"{COLOR_YELLOW_BOLD}🏆 NEW ALL-TIME HIGH SCORE! {base_str}{COLOR_RESET}")

                elif ep_reward > MIN_EPISODE_REWARD_TO_LOG:
                    if ep_reward >= 100.0:
                        log(f"{COLOR_GREEN}🌟 {base_str}{COLOR_RESET}")
                    elif ep_reward >= 50.0:
                        log(f"{COLOR_BLUE}🔹 {base_str}{COLOR_RESET}")
                    else:
                        log(f"🎉 {base_str}")

                info["episode"] = {"r": ep_reward, "l": ep_steps}
                info["terminal_observation"] = obs
                self._send_action(i, 0)
                _, _, next_obs, _ = self._recv_packet(i)
                obs = next_obs
                self._episode_count[i] += 1
                self._episode_reward[i] = 0.0
                self._episode_steps[i] = 0

            obs_list.append(obs)
            reward_list.append(reward)
            done_list.append(done)
            infos.append(info)

        return (
            np.stack(obs_list),
            np.array(reward_list, dtype=np.float32),
            np.array(done_list, dtype=bool),
            infos,
        )

    def close(self) -> None:
        for conn in self.conns:
            try:
                conn.close()
            except OSError:
                pass

    def get_attr(self, attr_name, indices=None):
        indices = self._get_indices(indices)
        return [getattr(self, attr_name, None) for _ in indices]

    def set_attr(self, attr_name, value, indices=None):
        setattr(self, attr_name, value)

    def env_method(self, method_name, *method_args, indices=None, **method_kwargs):
        raise NotImplementedError("TetrisVecEnv has no per-env Python objects to call methods on.")

    def env_is_wrapped(self, wrapper_class, indices=None):
        indices = self._get_indices(indices)
        return [False for _ in indices]

    def seed(self, seed=None):
        return [None for _ in range(self.num_envs)]


class OnnxPolicyWrapper(torch.nn.Module):
    def __init__(self, policy):
        super().__init__()
        self.policy = policy

    def forward(self, obs: torch.Tensor) -> torch.Tensor:
        if obs.dim() == 1:
            obs = obs.unsqueeze(0)
        features = self.policy.extract_features(obs)
        latent_pi = self.policy.mlp_extractor.forward_actor(features)
        logits = self.policy.action_net(latent_pi)
        return logits.squeeze(0)  # Flattens output [1, 80] -> 1D [80]


def export_policy_to_onnx(model: PPO, path: str, silent: bool = False) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    wrapper = OnnxPolicyWrapper(model.policy).eval()

    # 1D input tensor matching GDScript PackedFloat32Array
    dummy_input = torch.randn(OBS_SIZE, device=DEVICE)

    try:
        torch.onnx.export(
            wrapper,
            dummy_input,
            path,
            input_names=["obs"],
            output_names=["action_logits"],
            opset_version=17,
            dynamo=False,
        )
    except TypeError:
        torch.onnx.export(
            wrapper,
            dummy_input,
            path,
            input_names=["obs"],
            output_names=["action_logits"],
            opset_version=17,
        )
    if not silent:
        log(f"📦 Exported 1D ONNX model to {path}")


class CheckpointAndExportCallback(BaseCallback):
    def __init__(self, save_freq: int, silent: bool = True):
        super().__init__(verbose=0)
        self.save_freq = save_freq
        self.silent = silent

    def _on_rollout_end(self) -> None:
        # Retrieves completed episode metrics directly from SB3's buffer
        ep_info_buffer = getattr(self.model, "ep_info_buffer", None)
        
        if ep_info_buffer and len(ep_info_buffer) > 0:
            lengths = [ep["l"] for ep in ep_info_buffer]
            rewards = [ep["r"] for ep in ep_info_buffer]

            avg_steps = float(np.mean(lengths))
            best_steps = int(np.max(lengths))
            worst_steps = int(np.min(lengths))

            avg_score = float(np.mean(rewards))
            best_score = float(np.max(rewards))
            worst_score = float(np.min(rewards))

            print("\n" + "=" * 70, flush=True)
            print("📊 [ROLLOUT METRICS SUMMARY]", flush=True)
            print(f"   Steps -> Avg: {avg_steps:.1f} | Best: {best_steps} | Worst: {worst_steps}", flush=True)
            print(f"   Score -> Avg: {avg_score:.1f} | Best: {best_score:.1f} | Worst: {worst_score:.1f}", flush=True)
            print("=" * 70 + "\n", flush=True)

    def _on_step(self) -> bool:
        # Trigger immediate export on all-time high score
        if getattr(self.training_env, "new_high_score_flag", False):
            self.training_env.new_high_score_flag = False
            export_policy_to_onnx(self.model, ONNX_PATH, silent=False)
            export_policy_to_onnx(self.model, BEST_ONNX_PATH, silent=True)

        # Periodic background save
        if self.n_calls % self.save_freq == 0:
            os.makedirs(MODEL_DIR, exist_ok=True)
            self.model.save(CHECKPOINT_PATH)
            export_policy_to_onnx(self.model, ONNX_PATH, silent=self.silent)
            if not self.silent:
                print(f"💾 Checkpoint + ONNX export at step {self.num_timesteps}")
        return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Tetris PPO Training Server")
    parser.add_argument("--device", type=str, default="auto", choices=["auto", "cuda", "cpu"], help="Compute device (auto/cuda/cpu)")
    parser.add_argument("--reset-to-bc", action="store_true", help="Force starting fresh from Behavior Cloned (BC) weights")
    args = parser.parse_args()

    dev, dev_label = get_device(args.device)

    print("=" * 60)
    print("🤖 PPO Training Server (Always-On High Score Tracking)")
    print(f"   Device selected: {dev_label}")
    print(f"   Episode Log Cutoff: > {MIN_EPISODE_REWARD_TO_LOG} (New High Scores Always Print)")
    print(f"   Show Step Logs: {SHOW_STEP_LOGS}")
    print(f"   Silent Runtime Exports: {SILENT_CHECKPOINTS}")
    print("=" * 60)

    env = TetrisVecEnv(HOST, PORT)
    num_envs = env.num_envs

    custom_hyperparams = {
        "ent_coef": 0.005,
        "learning_rate": 5e-5,
        "gamma": 0.99,
        "n_epochs": 4,
        "target_kl": 0.02,
        "max_grad_norm": 0.5,
    }

    if args.reset_to_bc and os.path.exists(CHECKPOINT_PATH):
        backup_path = os.path.join(MODEL_DIR, "tetris_ppo_stuck_backup.zip")
        try:
            os.replace(CHECKPOINT_PATH, backup_path)
            log(f"📦 Archived previous RL checkpoint to {backup_path}")
        except Exception:
            pass

    if os.path.exists(CHECKPOINT_PATH) and not args.reset_to_bc:
        log("↻ Resuming from existing checkpoint...")
        model = PPO.load(
            CHECKPOINT_PATH,
            env=env,
            device=dev,
            custom_objects=custom_hyperparams,
            tensorboard_log=TENSORBOARD_DIR,
        )
    elif os.path.exists(BC_CHECKPOINT_PATH):
        log(f"🧑‍🏫 Found Behavior-Cloned headstart at {BC_CHECKPOINT_PATH}.")
        log("   Starting PPO fine-tuning with target_kl=0.02, n_epochs=4, and ent_coef=0.005 (skills preserved!)")
        model = PPO.load(
            BC_CHECKPOINT_PATH,
            env=env,
            device=dev,
            custom_objects=custom_hyperparams,
            tensorboard_log=TENSORBOARD_DIR,
        )
        model.num_timesteps = 0
    else:
        log("Creating a fresh PPO model (no checkpoint found).")
        policy_kwargs = dict(
            net_arch=dict(pi=[256, 256, 128], vf=[256, 256, 128]),
            activation_fn=torch.nn.ReLU,
        )
        model = PPO(
            "MlpPolicy",
            env,
            device=dev,
            verbose=1,
            n_steps=N_STEPS,
            batch_size=min(512, N_STEPS * num_envs),
            learning_rate=5e-5,
            gamma=0.99,
            ent_coef=0.005,
            n_epochs=4,
            target_kl=0.02,
            max_grad_norm=0.5,
            policy_kwargs=policy_kwargs,
            tensorboard_log=TENSORBOARD_DIR,
        )

    callback = CheckpointAndExportCallback(save_freq=CHECKPOINT_FREQ_STEPS, silent=SILENT_CHECKPOINTS)

    log("Training started...")
    try:
        model.learn(total_timesteps=50_000_000, callback=callback, tb_log_name="ppo_tetris", reset_num_timesteps=False)
    except KeyboardInterrupt:
        log("⏹️  Stopped manually (Ctrl+C).")
    except (ConnectionError, socket.timeout, BrokenPipeError, ConnectionResetError) as e:
        log(f"⚡ Lost connection to a Godot instance: {e!r}")
    finally:
        os.makedirs(MODEL_DIR, exist_ok=True)
        try:
            model.save(CHECKPOINT_PATH)
            export_policy_to_onnx(model, ONNX_PATH, silent=False)
            log(f"💾 Final model saved to {CHECKPOINT_PATH} and exported to {ONNX_PATH}")
        except Exception:
            traceback.print_exc()
        env.close()

if __name__ == "__main__":
    main()