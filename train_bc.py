"""
Behavior Cloning Pretrainer — learn from recorded human play
==============================================================
Reads (observation, action) pairs recorded while a human played the
game, and trains a policy via straightforward supervised learning
(cross-entropy: "given this board, predict the human's chosen
action") — i.e. imitation learning, not reinforcement learning. No
Godot connection needed for this step at all.

Produces two things:
  1. ai_models/tetris_bot_bc.zip   — a real SB3 checkpoint. Once you're
     happy with how it plays, train.py will automatically load this as
     its starting point (instead of random weights) the next time you
     run it, AS LONG AS ai_models/tetris_ppo.zip doesn't exist yet.
  2. ai_models/tetris_bot_bc_test.onnx — a separately-named ONNX file,
     just for testing this model in OnnxBotBoard before you trust it
     enough to use as a headstart. This does NOT touch or overwrite
     the main tetris_bot.onnx that the real training pipeline uses.

Expected input format (see DEMO_DIR below): one or more `*.bin` files,
each a flat concatenation of fixed-size samples:
    [ 413 x float32 observation ][ 1 x int32 action_idx (0-79) ]
    =  1652 bytes               +  4 bytes  = 1656 bytes / sample
This exactly mirrors the obs layout already used over the TCP
protocol, just paired with the action that followed instead of a
reward/done header — should be straightforward for a Godot recorder
script to write directly to disk with FileAccess.

Usage:
    python train_bc.py
"""

import glob
import os
import struct
import time

import numpy as np
import torch
import gymnasium as gym
from gymnasium import spaces
from stable_baselines3 import PPO
from stable_baselines3.common.vec_env import DummyVecEnv

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

OBS_SIZE = 413
OBS_BYTES = OBS_SIZE * 4
ACTION_SPACE_SIZE = 80
SAMPLE_BYTES = OBS_BYTES + 4  # obs + int32 action

DEMO_DIR = "demos"
MODEL_DIR = "ai_models"
BC_CHECKPOINT_PATH = os.path.join(MODEL_DIR, "tetris_bot_bc.zip")
BC_TEST_ONNX_PATH = os.path.join(MODEL_DIR, "tetris_bot_bc_test.onnx")

EPOCHS = 30
BATCH_SIZE = 256
LEARNING_RATE = 1e-4
VAL_SPLIT = 0.1


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def load_demo_dataset(demo_dir: str):
    files = sorted(glob.glob(os.path.join(demo_dir, "*.bin")))
    if not files:
        raise FileNotFoundError(
            f"No .bin demo files found in '{demo_dir}/'. Record some human "
            "play first (see the recorder script) before running this."
        )

    obs_list, action_list = [], []
    for path in files:
        with open(path, "rb") as f:
            data = f.read()
        n_samples = len(data) // SAMPLE_BYTES
        leftover = len(data) % SAMPLE_BYTES
        if leftover != 0:
            log(
                f"⚠️  {path}: {leftover} trailing bytes don't fill a full "
                "sample — ignoring them (file may have been cut off mid-write)."
            )
        for i in range(n_samples):
            chunk = data[i * SAMPLE_BYTES : (i + 1) * SAMPLE_BYTES]
            obs = np.frombuffer(chunk[:OBS_BYTES], dtype=np.float32)
            action = struct.unpack("<i", chunk[OBS_BYTES:])[0]
            obs_list.append(obs)
            action_list.append(action)
        log(f"  loaded {n_samples} samples from {path}")

    obs_arr = np.stack(obs_list).astype(np.float32)
    action_arr = np.array(action_list, dtype=np.int64)

    bad = (action_arr < 0) | (action_arr >= ACTION_SPACE_SIZE)
    if bad.any():
        raise ValueError(
            f"{bad.sum()} recorded actions are outside 0..{ACTION_SPACE_SIZE - 1} — "
            "the recorder's action encoding likely doesn't match decode_action(). "
            "Fix that before training on this data."
        )

    log(f"Total demo samples: {len(action_arr)} from {len(files)} file(s)")
    return obs_arr, action_arr


class _DummySpaceEnv(gym.Env):
    """Just here so PPO() can build a correctly-shaped policy network
    without needing a real Godot connection. Never actually stepped."""

    def __init__(self):
        super().__init__()
        self.observation_space = spaces.Box(
            low=0.0, high=999.0, shape=(OBS_SIZE,), dtype=np.float32
        )
        self.action_space = spaces.Discrete(ACTION_SPACE_SIZE)

    def reset(self, *, seed=None, options=None):
        return np.zeros(OBS_SIZE, dtype=np.float32), {}

    def step(self, action):
        return np.zeros(OBS_SIZE, dtype=np.float32), 0.0, True, False, {}


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

def train_behavior_cloning(model: PPO, obs_arr: np.ndarray, action_arr: np.ndarray) -> None:
    n = len(action_arr)
    rng = np.random.default_rng()
    idx = rng.permutation(n)
    n_val = max(1, int(n * VAL_SPLIT))
    val_idx, train_idx = idx[:n_val], idx[n_val:]

    obs_t = torch.tensor(obs_arr, dtype=torch.float32, device=DEVICE)
    act_t = torch.tensor(action_arr, dtype=torch.long, device=DEVICE)

    policy = model.policy
    policy.train()
    optimizer = torch.optim.Adam(policy.parameters(), lr=LEARNING_RATE)

    def forward_logits(obs_batch: torch.Tensor) -> torch.Tensor:
        features = policy.extract_features(obs_batch)
        latent_pi = policy.mlp_extractor.forward_actor(features)
        return policy.action_net(latent_pi)

    for epoch in range(1, EPOCHS + 1):
        rng.shuffle(train_idx)
        total_loss, correct = 0.0, 0
        for start in range(0, len(train_idx), BATCH_SIZE):
            batch_idx = train_idx[start : start + BATCH_SIZE]
            obs_b, act_b = obs_t[batch_idx], act_t[batch_idx]

            logits = forward_logits(obs_b)
            loss = torch.nn.functional.cross_entropy(logits, act_b)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            total_loss += loss.item() * len(batch_idx)
            correct += (logits.argmax(dim=1) == act_b).sum().item()

        train_loss = total_loss / len(train_idx)
        train_acc = correct / len(train_idx)

        policy.eval()
        with torch.no_grad():
            logits = forward_logits(obs_t[val_idx])
            val_loss = torch.nn.functional.cross_entropy(logits, act_t[val_idx]).item()
            val_acc = (logits.argmax(dim=1) == act_t[val_idx]).float().mean().item()
        policy.train()

        log(
            f"epoch {epoch:>3}/{EPOCHS}  train_loss={train_loss:.4f} "
            f"train_acc={train_acc:.3f}  val_loss={val_loss:.4f} val_acc={val_acc:.3f}"
        )

    policy.eval()


def main() -> None:
    print("=" * 60)
    print("🧑‍🏫 Behavior Cloning Pretrainer (learn from recorded human play)")
    print(f"   Device: {DEVICE.upper()}")
    print("=" * 60)

    obs_arr, action_arr = load_demo_dataset(DEMO_DIR)

    dummy_env = DummyVecEnv([lambda: _DummySpaceEnv()])
    model = PPO("MlpPolicy", dummy_env, device=DEVICE, verbose=0)

    train_behavior_cloning(model, obs_arr, action_arr)

    os.makedirs(MODEL_DIR, exist_ok=True)
    model.save(BC_CHECKPOINT_PATH)
    log(f"💾 Saved behavior-cloned checkpoint to {BC_CHECKPOINT_PATH}")
    export_policy_to_onnx(model, BC_TEST_ONNX_PATH)
    log("Try tetris_bot_bc_test.onnx in OnnxBotBoard before trusting it.")
    log(
        f"When you're happy with it: as long as ai_models/tetris_ppo.zip "
        f"doesn't exist yet, train.py will automatically start from "
        f"{BC_CHECKPOINT_PATH} instead of random weights next time you run it."
    )


if __name__ == "__main__":
    main()