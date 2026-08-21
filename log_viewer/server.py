import os
import sys
import glob
import time
import json
from http.server import HTTPServer, SimpleHTTPRequestHandler
import urllib.parse

# Ensure UTF-8 output on Windows
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

TB_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tb_logs"))
BEST_SCORE_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "ai_models", "best_score.json"))

def get_event_files():
    pattern = os.path.join(TB_DIR, "**", "events.out.tfevents*")
    files = glob.glob(pattern, recursive=True)
    files = [f for f in files if os.path.isfile(f) and os.path.getsize(f) > 100]
    files.sort(key=os.path.getmtime)
    return files

def parse_run(event_file):
    try:
        ea = EventAccumulator(event_file)
        ea.Reload()
        tags = ea.Tags().get("scalars", [])
        data = {}
        for tag in tags:
            scalars = ea.Scalars(tag)
            data[tag] = [{"step": s.step, "value": float(s.value), "wall_time": s.wall_time} for s in scalars]
        return data
    except Exception as e:
        print(f"Error parsing {event_file}: {e}")
        return {}

def get_dashboard_data():
    files = get_event_files()
    runs_summary = []
    
    for idx, f in enumerate(files):
        rel_path = os.path.relpath(f, TB_DIR)
        run_name = os.path.basename(os.path.dirname(f))
        file_name = os.path.basename(f)
        mtime = os.path.getmtime(f)
        size_kb = os.path.getsize(f) / 1024.0
        
        runs_summary.append({
            "id": idx,
            "file": file_name,
            "rel_path": rel_path,
            "run_name": run_name if run_name != "tb_logs" else file_name,
            "last_updated": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(mtime)),
            "mtime": mtime,
            "size_kb": round(size_kb, 1),
            "full_path": f
        })
        
    best_score = None
    if os.path.exists(BEST_SCORE_FILE):
        try:
            with open(BEST_SCORE_FILE, "r") as bf:
                best_score = json.load(bf)
        except Exception:
            pass
            
    return {
        "runs": runs_summary,
        "best_score": best_score,
        "total_runs": len(files)
    }

class DashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        # Serve static files from the dashboard directory
        directory = os.path.dirname(os.path.abspath(__file__))
        super().__init__(*args, directory=directory, **kwargs)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        
        if parsed.path == "/api/runs":
            data = get_dashboard_data()
            self._send_json(data)
            return
            
        elif parsed.path == "/api/run_details":
            query = urllib.parse.parse_qs(parsed.query)
            run_id = query.get("id", [None])[0]
            files = get_event_files()
            
            if run_id is None:
                # default to latest run
                target_file = files[-1] if files else None
                run_index = len(files) - 1 if files else -1
            else:
                try:
                    idx = int(run_id)
                    target_file = files[idx]
                    run_index = idx
                except Exception:
                    target_file = None
                    run_index = -1
                    
            if not target_file:
                self._send_json({"error": "Run not found"}, status=404)
                return
                
            metrics = parse_run(target_file)
            file_meta = {
                "id": run_index,
                "file": os.path.basename(target_file),
                "run_name": os.path.basename(os.path.dirname(target_file)),
                "size_kb": round(os.path.getsize(target_file) / 1024.0, 1),
                "last_updated": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(target_file)))
            }
            
            best_score = None
            if os.path.exists(BEST_SCORE_FILE):
                try:
                    with open(BEST_SCORE_FILE, "r") as bf:
                        best_score = json.load(bf)
                except Exception:
                    pass

            self._send_json({
                "meta": file_meta,
                "metrics": metrics,
                "best_score": best_score
            })
            return
            
        return super().do_GET()

    def _send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

def main():
    port = 8080
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        port = int(sys.argv[1])
        
    server = HTTPServer(("0.0.0.0", port), DashboardHandler)
    print("=" * 65)
    print(f"🚀 Tetris AI Training Logs Dashboard Server Running!")
    print(f"👉 Local Web URL: http://localhost:{port}")
    print(f"📁 TensorBoard Source Directory: {TB_DIR}")
    print("=" * 65)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard server...")
        server.server_close()

if __name__ == "__main__":
    main()
