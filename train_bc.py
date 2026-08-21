import glob
import os
import time

import numpy as np
import torch
import gymnasium as gym
from gymnasium import spaces
from stable_baselines3 import PPO
from stable_baselines3.common.vec_env import DummyVecEnv

# --- CPU OPTIMIZATION CONFIG ---
DEVICE = "cpu"
# Set PyTorch to match the 4 physical cores of the i5-10210U
torch.set_num_threads(4)

OBS_SIZE = 413
OBS_BYTES = OBS_SIZE * 4
ACTION_SPACE_SIZE = 80
SAMPLE_BYTES = OBS_BYTES + 4

DEMO_DIR = "demos"
MODEL_DIR = "ai_models"
BC_CHECKPOINT_PATH = os.path.join(MODEL_DIR, "tetris_bot_bc.zip")
BC_TEST_ONNX_PATH = os.path.join(MODEL_DIR, "tetris_bot_bc_test.onnx")

EPOCHS = 1000
BATCH_SIZE = 128       # Optimized for 6MB CPU L3 cache
LEARNING_RATE = 3e-4   # Balanced LR for CPU batches
PATIENCE = 25          # Early stopping limit
VAL_SPLIT = 0.1


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def load_demo_dataset(demo_dir: str):
    files = sorted(glob.glob(os.path.join(demo_dir, "*.bin")))
    if not files:
        raise FileNotFoundError(f"No .bin demo files found in '{demo_dir}/'.")

    sample_dtype = np.dtype([
        ('obs', np.float32, (OBS_SIZE,)),
        ('action', np.int32)
    ])

    obs_list, action_list = [], []
    for path in files:
        with open(path, "rb") as f:
            data = f.read()
            
        n_samples = len(data) // SAMPLE_BYTES
        if n_samples == 0:
            continue
            
        # Fast vectorized byte parsing without Python loops
        samples = np.frombuffer(data[:n_samples * SAMPLE_BYTES], dtype=sample_dtype)
        obs_list.append(samples['obs'])
        action_list.append(samples['action'])
        log(f"  loaded {n_samples} samples from {path}")

    obs_arr = np.concatenate(obs_list, axis=0)
    action_arr = np.concatenate(action_list, axis=0).astype(np.int64)

    bad = (action_arr < 0) | (action_arr >= ACTION_SPACE_SIZE)
    if bad.any():
        raise ValueError(f"Recorded actions outside valid range 0..{ACTION_SPACE_SIZE - 1}")

    log(f"Total demo samples: {len(action_arr)} from {len(files)} file(s)")
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
    print("=" * 60)
    print("🧑‍🏫 Behavior Cloning Pretrainer (CPU Mode - Intel i5 Optimizations)")
    print(f"   Threads: {torch.get_num_threads()} | Batch Size: {BATCH_SIZE}")
    print("=" * 60)

    obs_arr, action_arr = load_demo_dataset(DEMO_DIR)

    policy_kwargs = dict(
        net_arch=dict(pi=[256, 256, 128], vf=[256, 256, 128]),
        activation_fn=torch.nn.ReLU,
    )
    dummy_env = DummyVecEnv([lambda: _DummySpaceEnv()])
    model = PPO("MlpPolicy", dummy_env, device=DEVICE, policy_kwargs=policy_kwargs, verbose=0)

    train_behavior_cloning(model, obs_arr, action_arr)

    os.makedirs(MODEL_DIR, exist_ok=True)
    model.save(BC_CHECKPOINT_PATH)
    log(f"💾 Saved behavior-cloned checkpoint to {BC_CHECKPOINT_PATH}")
    export_policy_to_onnx(model, BC_TEST_ONNX_PATH)


if __name__ == "__main__":
    main()