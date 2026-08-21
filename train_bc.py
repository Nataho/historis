import argparse
import glob
import os
import time

import numpy as np
import torch
import gymnasium as gym
from gymnasium import spaces
from stable_baselines3 import PPO
from stable_baselines3.common.vec_env import DummyVecEnv

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
OBS_BYTES = OBS_SIZE * 4
ACTION_SPACE_SIZE = 80
SAMPLE_BYTES = OBS_BYTES + 4

DEMO_DIR = "demos"
MODEL_DIR = "ai_models"
BC_CHECKPOINT_PATH = os.path.join(MODEL_DIR, "tetris_bot_bc.zip")
BC_TEST_ONNX_PATH = os.path.join(MODEL_DIR, "tetris_bot_bc_test.onnx")

EPOCHS = 1000
BATCH_SIZE = 128
LEARNING_RATE = 3e-4
PATIENCE = 25
VAL_SPLIT = 0.1


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def load_demo_dataset(demo_dir: str):
    files = sorted(glob.glob(os.path.join(demo_dir, "**/*.bin"), recursive=True))
    if not files:
        raise FileNotFoundError(f"No .bin demo files found in '{demo_dir}/'.")

    sample_dtype = np.dtype([
        ('obs', np.float32, (OBS_SIZE,)),
        ('action', np.int32)
    ])

    obs_list, action_list = [], []
    skipped_legacy, skipped_bad = 0, 0
    for path in files:
        with open(path, "rb") as f:
            data = f.read()

        # Reject empty files or files not strictly aligned to current OBS_SIZE (1656 bytes/sample)
        if len(data) == 0 or len(data) % SAMPLE_BYTES != 0:
            skipped_legacy += 1
            continue

        # Fast vectorized byte parsing without Python loops
        samples = np.frombuffer(data, dtype=sample_dtype)
        actions = samples['action']

        bad = (actions < 0) | (actions >= ACTION_SPACE_SIZE)
        if bad.any():
            skipped_bad += 1
            continue

        obs_list.append(samples['obs'])
        action_list.append(actions)
        log(f"  loaded {len(samples)} samples from {path}")

    if not obs_list:
        raise ValueError(f"No valid demo samples matching OBS_SIZE={OBS_SIZE} found in '{demo_dir}/'.")

    obs_arr = np.concatenate(obs_list, axis=0)
    action_arr = np.concatenate(action_list, axis=0).astype(np.int64)

    log(f"Total valid demo samples: {len(action_arr)} from {len(obs_list)} valid file(s) (skipped {skipped_legacy} legacy files)")
    return obs_arr, action_arr


class _DummySpaceEnv(gym.Env):
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
        return logits.squeeze(0)


def export_policy_to_onnx(model: PPO, path: str, silent: bool = False) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    wrapper = OnnxPolicyWrapper(model.policy).eval()
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

    best_val_loss = float("inf")
    patience_counter = 0

    for epoch in range(1, EPOCHS + 1):
        policy.train()
        rng.shuffle(train_idx)
        total_loss, correct = 0.0, 0

        for start in range(0, len(train_idx), BATCH_SIZE):
            batch_idx = train_idx[start : start + BATCH_SIZE]
            obs_b, act_b = obs_t[batch_idx], act_t[batch_idx]

            optimizer.zero_grad(set_to_none=True)
            logits = forward_logits(obs_b)
            loss = torch.nn.functional.cross_entropy(logits, act_b)

            loss.backward()
            optimizer.step()

            total_loss += loss.item() * len(batch_idx)
            correct += (logits.argmax(dim=1) == act_b).sum().item()

        train_loss = total_loss / len(train_idx)
        train_acc = correct / len(train_idx)

        policy.eval()
        with torch.no_grad():
            val_logits = forward_logits(obs_t[val_idx])
            val_loss = torch.nn.functional.cross_entropy(val_logits, act_t[val_idx]).item()
            val_acc = (val_logits.argmax(dim=1) == act_t[val_idx]).float().mean().item()

        log(
            f"epoch {epoch:>3}/{EPOCHS}  train_loss={train_loss:.4f} "
            f"train_acc={train_acc:.3f}  val_loss={val_loss:.4f} val_acc={val_acc:.3f}"
        )

        if val_loss < best_val_loss:
            best_val_loss = val_loss
            patience_counter = 0
        else:
            patience_counter += 1
            if patience_counter >= PATIENCE:
                log(f"🛑 Early stopping triggered at epoch {epoch}. Best val_loss: {best_val_loss:.4f}")
                break

    policy.eval()


def main() -> None:
    parser = argparse.ArgumentParser(description="Tetris Behavior Cloning Pretrainer")
    parser.add_argument("--device", type=str, default="auto", choices=["auto", "cuda", "cpu"], help="Compute device (auto/cuda/cpu)")
    args = parser.parse_args()

    dev, dev_label = get_device(args.device)

    print("=" * 60)
    print("🧑‍🏫 Behavior Cloning Pretrainer")
    print(f"   Device selected: {dev_label}")
    print(f"   Batch Size: {BATCH_SIZE}")
    print("=" * 60)

    obs_arr, action_arr = load_demo_dataset(DEMO_DIR)

    policy_kwargs = dict(
        net_arch=dict(pi=[256, 256, 128], vf=[256, 256, 128]),
        activation_fn=torch.nn.ReLU,
    )
    dummy_env = DummyVecEnv([lambda: _DummySpaceEnv()])
    model = PPO("MlpPolicy", dummy_env, device=dev, policy_kwargs=policy_kwargs, verbose=0)

    train_behavior_cloning(model, obs_arr, action_arr)

    os.makedirs(MODEL_DIR, exist_ok=True)
    model.save(BC_CHECKPOINT_PATH)
    log(f"💾 Saved behavior-cloned checkpoint to {BC_CHECKPOINT_PATH}")
    export_policy_to_onnx(model, BC_TEST_ONNX_PATH)


if __name__ == "__main__":
    main()