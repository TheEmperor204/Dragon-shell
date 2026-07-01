"""
Dragon Shell local HTTP server — bridges the Plasma QML widget to the Python backend.
Runs on localhost:29156
"""
import json
import os
import sys
import time
import subprocess
import requests as req
from pathlib import Path
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread

SCRIPT_DIR = Path(__file__).parent
SETTINGS_FILE = SCRIPT_DIR / "config" / "settings.json"
HISTORY_FILE = SCRIPT_DIR / "config" / "history.json"
HISTORY_MAX = 20
SYSTEM_PROMPT_FILE = SCRIPT_DIR / "prompts" / "system.txt"

with open(SETTINGS_FILE) as f:
    SETTINGS = json.load(f)

with open(SYSTEM_PROMPT_FILE) as f:
    SYSTEM_PROMPT = f.read()

# Import shared backend
sys.path.insert(0, str(SCRIPT_DIR))
from backend import db_lookup, db_save, filesystem_search, extract_search_keyword, looks_like_file_search

OLLAMA_ENV = {
    **os.environ,
    "HSA_OVERRIDE_GFX_VERSION": "10.3.0",
    "OLLAMA_VULKAN": "false"
}

CONF_THRESHOLD = 0.65

# Build system snapshot
def build_snapshot():
    parts = []
    try:
        r = subprocess.run(["pacman", "-Qq"], capture_output=True, text=True, timeout=5)
        pkgs = r.stdout.strip().splitlines()
        parts.append(f"INSTALLED PACKAGES ({len(pkgs)} total):\n" + "\n".join(pkgs[:300]))
    except Exception:
        pass
    try:
        r = subprocess.run(
            ["find", os.path.expanduser("~/.local/share/Steam/steamapps/common"),
             "-maxdepth", "1", "-mindepth", "1", "-type", "d"],
            capture_output=True, text=True, timeout=8
        )
        if r.stdout.strip():
            skip = {"steamlinuxruntime", "proton", "steamworks", "pressure_vessel"}
            games = [os.path.basename(p) for p in r.stdout.strip().splitlines()
                     if not any(s in p.lower() for s in skip)]
            parts.append("STEAM GAMES:\n" + "\n".join(games))
    except Exception:
        pass
    return "\n\n".join(parts)

def ollama_is_running():
    try:
        req.get("http://localhost:11434", timeout=2)
        return True
    except Exception:
        return False

def start_ollama():
    if ollama_is_running():
        print("Dragon Shell server: Ollama already running")
        return
    print("Dragon Shell server: starting Ollama...")
    subprocess.Popen(
        ["ollama", "serve"],
        env={**os.environ, "HSA_OVERRIDE_GFX_VERSION": "10.3.0", "OLLAMA_VULKAN": "false"},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    for _ in range(20):
        time.sleep(0.5)
        if ollama_is_running():
            print("Dragon Shell server: Ollama ready")
            return
    print("Dragon Shell server: Ollama failed to start")

print("Dragon Shell server: building snapshot...")
SNAPSHOT = build_snapshot()
print(f"Dragon Shell server: ready ({len(SNAPSHOT)} chars snapshot)")

# Cache last result for mark_worked
last_result = {}


def load_history():
    if HISTORY_FILE.exists():
        try:
            with open(HISTORY_FILE) as f:
                return json.load(f)
        except Exception:
            return []
    return []


def save_history(history):
    with open(HISTORY_FILE, "w") as f:
        json.dump(history, f, indent=2)


def append_history(entry):
    """Add a new entry to history, capped at HISTORY_MAX, newest first."""
    history = load_history()
    entry["id"] = datetime.now().strftime("%Y%m%d%H%M%S%f")
    entry["timestamp"] = datetime.now().isoformat()
    entry["feedback"] = None  # None = unconfirmed, "worked", "failed"
    history.insert(0, entry)
    history = history[:HISTORY_MAX]
    save_history(history)
    return entry["id"]


def update_history_feedback(entry_id, feedback):
    history = load_history()
    for entry in history:
        if entry.get("id") == entry_id:
            entry["feedback"] = feedback
            save_history(history)
            return True
    return False


AVAILABLE_MODELS = [
    {"id": "qwen2.5-coder:14b", "label": "Qwen 2.5 Coder 14B (recommended)", "size_gb": 9},
    {"id": "qwen2.5:14b", "label": "Qwen 2.5 14B", "size_gb": 9},
    {"id": "qwen2.5:7b", "label": "Qwen 2.5 7B (faster, less accurate)", "size_gb": 4.7},
    {"id": "deepseek-coder-v2:16b", "label": "DeepSeek Coder V2 16B", "size_gb": 10},
    {"id": "gemma2:9b", "label": "Gemma 2 9B", "size_gb": 5.5},
]


def get_installed_models():
    """Check installed models without requiring Ollama to be running."""
    try:
        r = req.get(f"{SETTINGS['ollama_url']}/api/tags", timeout=2)
        return [m["name"] for m in r.json().get("models", [])]
    except Exception:
        pass
    try:
        manifest_dir = os.path.expanduser("~/.ollama/models/manifests/registry.ollama.ai/library")
        if not os.path.exists(manifest_dir):
            return []
        models = []
        for model_name in os.listdir(manifest_dir):
            tag_dir = os.path.join(manifest_dir, model_name)
            if os.path.isdir(tag_dir):
                for tag in os.listdir(tag_dir):
                    models.append(f"{model_name}:{tag}")
        return models
    except Exception:
        return []
        return []


def pull_model_background(model_id, progress_dict):
    """Run ollama pull and track progress for polling."""
    try:
        progress_dict["status"] = "downloading"
        proc = subprocess.Popen(
            ["ollama", "pull", model_id],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        for line in proc.stdout:
            progress_dict["last_line"] = line.strip()
        proc.wait()
        progress_dict["status"] = "done" if proc.returncode == 0 else "error"
    except Exception as e:
        progress_dict["status"] = "error"
        progress_dict["last_line"] = str(e)


PULL_PROGRESS = {"status": "idle", "last_line": ""}
PENDING_SHUTDOWN = None


def query_ollama(question):
    global last_result

    # Layer 1: DB
    entry, score = db_lookup(question)
    if entry:
        result = {
            "command": entry["command"],
            "explanation": entry["explanation"],
            "risk": entry["risk"],
            "risk_reason": entry["risk_reason"],
            "undo": entry.get("undo"),
            "confidence": 1.0,
            "db_score": round(score, 2),
            "_source": "db"
        }
        last_result = {"question": question, **result}
        hist_id = append_history({"question": question, **result})
        result["history_id"] = hist_id
        return result

    # Start Ollama if not running (lazy start)
    start_ollama()

    # Layer 2: AI
    payload = {
        "model": SETTINGS["model"],
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT + "\n\n" + SNAPSHOT},
            {"role": "user", "content": question}
        ],
        "stream": False,
        "format": "json"
    }
    resp = req.post(
        f"{SETTINGS['ollama_url']}/api/chat",
        json=payload,
        timeout=SETTINGS["ollama_timeout"]
    )
    resp.raise_for_status()
    data = json.loads(resp.json()["message"]["content"])
    confidence = float(data.get("confidence", 0.5))

    # Layer 3: Real filesystem search if low confidence and looks like a file search
    if confidence < CONF_THRESHOLD and looks_like_file_search(question):
        keyword = extract_search_keyword(question)
        if keyword:
            matches = filesystem_search(keyword)
            if matches:
                # Ask the AI to pick the best match and build the right command
                verify_payload = {
                    "model": SETTINGS["model"],
                    "messages": [
                        {"role": "system", "content": SYSTEM_PROMPT},
                        {"role": "user", "content": (
                            f"Original question: {question}\n\n"
                            f"A real filesystem search found these actual paths:\n"
                            + "\n".join(matches) +
                            "\n\nPick the single best matching path and build the correct "
                            "command. Set confidence to 0.95 since this is a verified real path."
                        )}
                    ],
                    "stream": False,
                    "format": "json"
                }
                try:
                    vresp = req.post(
                        f"{SETTINGS['ollama_url']}/api/chat",
                        json=verify_payload,
                        timeout=SETTINGS["ollama_timeout"]
                    )
                    vresp.raise_for_status()
                    vdata = json.loads(vresp.json()["message"]["content"])
                    data = vdata
                    data["web_verified"] = True
                    confidence = float(data.get("confidence", 0.9))
                except Exception:
                    pass

    data["confidence"] = confidence
    data["_source"] = "ai"
    last_result = {"question": question, **data}
    hist_id = append_history({"question": question, **data})
    data["history_id"] = hist_id
    return data


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Silence default logging

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/get_settings":
            installed = get_installed_models()
            models_with_status = []
            for m in AVAILABLE_MODELS:
                models_with_status.append({
                    **m,
                    "installed": any(m["id"] in inst for inst in installed)
                })
            self._respond(200, {
                "current_model": SETTINGS["model"],
                "models": models_with_status,
                "unload_delay": SETTINGS.get("unload_delay_seconds", 0)
            })
        elif self.path == "/pull_status":
            self._respond(200, PULL_PROGRESS)
        elif self.path == "/history":
            self._respond(200, {"history": load_history()})
        else:
            self._respond(404, {"error": "not found"})

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        if self.path == "/query":
            try:
                result = query_ollama(body["question"])
                self._respond(200, result)
            except Exception as e:
                self._respond(500, {"error": str(e)})

        elif self.path == "/copy":
            text = body.get("text", "")
            try:
                subprocess.run(["wl-copy"], input=text.encode(), check=True)
            except Exception:
                try:
                    subprocess.run(["xclip", "-selection", "clipboard"],
                                   input=text.encode(), check=True)
                except Exception:
                    pass
            self._respond(200, {"ok": True})

        elif self.path == "/shutdown_ollama":
            global PENDING_SHUTDOWN
            delay = SETTINGS.get("unload_delay_seconds", 0)
            if delay == -1:
                self._respond(200, {"ok": True, "delay": -1})
                return
            shutdown_token = {"cancelled": False}
            PENDING_SHUTDOWN = shutdown_token

            def do_shutdown():
                time.sleep(delay)
                if shutdown_token["cancelled"]:
                    return
                try:
                    req.post(
                        f"{SETTINGS['ollama_url']}/api/generate",
                        json={"model": SETTINGS["model"], "keep_alive": 0},
                        timeout=3
                    )
                except Exception:
                    pass
                result = subprocess.run(["ss", "-tnp"], capture_output=True, text=True)
                our_pid = str(os.getpid())
                other_clients = any(
                    ":11434" in line and "ESTAB" in line and our_pid not in line
                    for line in result.stdout.splitlines()
                )
                if not other_clients:
                    subprocess.run(["pkill", "-f", "ollama serve"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    print("Dragon Shell server: Ollama stopped")
                else:
                    print("Dragon Shell server: Ollama kept running (other clients connected)")

            t = Thread(target=do_shutdown)
            t.daemon = True
            t.start()
            self._respond(200, {"ok": True, "delay": delay})

        elif self.path == "/cancel_shutdown":
            if PENDING_SHUTDOWN:
                PENDING_SHUTDOWN["cancelled"] = True
            self._respond(200, {"ok": True})

        elif self.path == "/set_model":
            model_id = body.get("model_id", "")
            if model_id:
                SETTINGS["model"] = model_id
                with open(SETTINGS_FILE, "w") as f:
                    json.dump(SETTINGS, f, indent=2)
            self._respond(200, {"ok": True})

        elif self.path == "/set_unload_delay":
            delay = body.get("seconds", 0)
            SETTINGS["unload_delay_seconds"] = int(delay)
            with open(SETTINGS_FILE, "w") as f:
                json.dump(SETTINGS, f, indent=2)
            self._respond(200, {"ok": True})

        elif self.path == "/pull_model":
            model_id = body.get("model_id", "")
            if model_id and PULL_PROGRESS["status"] != "downloading":
                PULL_PROGRESS["status"] = "starting"
                PULL_PROGRESS["last_line"] = ""
                t = Thread(target=pull_model_background, args=(model_id, PULL_PROGRESS))
                t.daemon = True
                t.start()
            self._respond(200, {"ok": True})

        elif self.path == "/retry":
            try:
                question = body.get("question", "")
                failed_cmd = body.get("failed_command", "")

                retry_payload = {
                    "model": SETTINGS["model"],
                    "messages": [
                        {"role": "system", "content": SYSTEM_PROMPT + "\n\n" + SNAPSHOT},
                        {"role": "user", "content": (
                            f"Original question: {question}\n\n"
                            f"This command was already tried and DID NOT WORK: {failed_cmd}\n\n"
                            "Give a different, better command. Do not repeat the failed command. "
                            "If the failure was likely due to a wrong file/folder name, use a "
                            "broader wildcard search instead of guessing another exact name."
                        )}
                    ],
                    "stream": False,
                    "format": "json"
                }
                resp = req.post(
                    f"{SETTINGS['ollama_url']}/api/chat",
                    json=retry_payload,
                    timeout=SETTINGS["ollama_timeout"]
                )
                resp.raise_for_status()
                data = json.loads(resp.json()["message"]["content"])
                data["confidence"] = float(data.get("confidence", 0.5))
                data["_source"] = "ai"
                global last_result
                last_result = {"question": question, **data}
                # Mark the previous failed attempt in history
                old_id = body.get("history_id")
                if old_id:
                    update_history_feedback(old_id, "failed")
                hist_id = append_history({"question": question, **data})
                data["history_id"] = hist_id
                self._respond(200, data)
            except Exception as e:
                self._respond(500, {"error": str(e)})

        elif self.path == "/history_feedback":
            entry_id = body.get("id", "")
            feedback = body.get("feedback", "")  # "worked" or "failed"
            ok = update_history_feedback(entry_id, feedback)
            # If marked as worked, also save to the command database
            if feedback == "worked" and ok:
                history = load_history()
                for entry in history:
                    if entry.get("id") == entry_id:
                        db_save(
                            question=entry.get("question", ""),
                            command=entry.get("command", ""),
                            explanation=entry.get("explanation", ""),
                            risk=entry.get("risk", "LOW"),
                            risk_reason=entry.get("risk_reason", ""),
                            undo=entry.get("undo")
                        )
                        break
            self._respond(200, {"ok": ok})

        elif self.path == "/mark_worked":
            q = body.get("question", "")
            cmd = body.get("command", "")
            hist_id = body.get("history_id", "")
            if q and cmd and last_result:
                db_save(
                    question=q,
                    command=cmd,
                    explanation=last_result.get("explanation", ""),
                    risk=last_result.get("risk", "LOW"),
                    risk_reason=last_result.get("risk_reason", ""),
                    undo=last_result.get("undo")
                )
            if hist_id:
                update_history_feedback(hist_id, "worked")
            self._respond(200, {"ok": True})

        else:
            self._respond(404, {"error": "not found"})

    def _respond(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 29156), Handler)
    print("Dragon Shell server listening on http://127.0.0.1:29156")
    server.serve_forever()
