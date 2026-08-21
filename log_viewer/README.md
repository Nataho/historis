# Tetris AI Training Log Viewer Dashboard

An interactive real-time web interface and telemetry dashboard for monitoring reinforcement learning runs.

## 🚀 How to Run the Dashboard

In your terminal, navigate to the project directory and run:

```bash
python log_viewer/server.py
```

Or specify a custom port:
```bash
python log_viewer/server.py 8080
```

Then open your browser to **http://localhost:8080** (or http://127.0.0.1:8080).

---

## ✨ Features

1. **Auto-Polling (Live Updates every 5s):** Automatically detects new steps logged in `tb_logs/` while `train.py` runs.
2. **Interactive Chart.js Visualizations:**
   * **Survival Trend:** `rollout/ep_len_mean` (steps/episode survival)
   * **Reward Progression:** `rollout/ep_rew_mean`
   * **Exploration Health:** `train/entropy_loss`
   * **Critic & Policy Stability:** `train/value_loss` and `train/approx_kl`
3. **Run Selector:** Switch between any past or current TensorBoard run in `tb_logs/`.
4. **Curriculum & Stage 2 Readiness Diagnostic:** Automatic health checks indicating whether your bot is ready to move to Stage 2 (`STAGE_2_CLEAN_BUILDER`).
5. **Full Iteration History Table:** Complete searchable/scrollable telemetry log table.
