"""
Dragon Shell backend — command database, confidence scoring, web search fallback.
"""
import json
import os
import re
import subprocess
import requests
from pathlib import Path
from datetime import datetime
from difflib import SequenceMatcher

SCRIPT_DIR = Path(__file__).parent
DB_FILE = SCRIPT_DIR / "config" / "command_db.json"


def load_db():
    if DB_FILE.exists():
        with open(DB_FILE) as f:
            return json.load(f)
    return {"entries": []}


def save_db(db):
    with open(DB_FILE, "w") as f:
        json.dump(db, f, indent=2)


def similarity(a, b):
    return SequenceMatcher(None, a.lower(), b.lower()).ratio()


def db_lookup(question, threshold=0.72):
    """
    Search the command database for a similar past question.
    Returns the best matching entry or None.
    """
    db = load_db()
    best = None
    best_score = 0.0
    for entry in db["entries"]:
        score = similarity(question, entry["question"])
        if score > best_score:
            best_score = score
            best = entry
    if best and best_score >= threshold:
        return best, best_score
    return None, 0.0


def db_save(question, command, explanation, risk, risk_reason, undo):
    """Save a confirmed working command to the database."""
    db = load_db()
    # Update if same question exists, otherwise append
    for entry in db["entries"]:
        if similarity(question, entry["question"]) > 0.95:
            entry.update({
                "command": command,
                "explanation": explanation,
                "risk": risk,
                "risk_reason": risk_reason,
                "undo": undo,
                "confirmed_at": datetime.now().isoformat(),
                "use_count": entry.get("use_count", 0) + 1
            })
            save_db(db)
            return
    db["entries"].append({
        "question": question,
        "command": command,
        "explanation": explanation,
        "risk": risk,
        "risk_reason": risk_reason,
        "undo": undo,
        "confirmed_at": datetime.now().isoformat(),
        "use_count": 1
    })
    save_db(db)


def filesystem_search(keyword, extra_roots=None):
    """
    Run a real, safe, scoped filesystem search for a keyword.
    Returns a list of matching paths (deduplicated, capped).
    """
    roots = [
        os.path.expanduser("~/.local/share/Steam/steamapps/common"),
        os.path.expanduser("~/.steam/steam/steamapps/common"),
        os.path.expanduser("~/.local/share"),
        os.path.expanduser("~/.config"),
        os.path.expanduser("~"),
    ]
    if extra_roots:
        roots = extra_roots + roots

    skip_terms = {
        "steamlinuxruntime", "proton", "steamworks", "pressure_vessel",
        "__pycache__", "workshop", ".cache/mozilla", ".cache/librewolf"
    }

    found = []
    for root in roots:
        if not os.path.exists(root):
            continue
        try:
            r = subprocess.run(
                ["find", root, "-maxdepth", "6", "-iname", f"*{keyword}*"],
                capture_output=True, text=True, timeout=8
            )
            for line in r.stdout.strip().splitlines():
                if not any(s in line.lower() for s in skip_terms):
                    found.append(line)
        except Exception:
            continue
        if len(found) >= 15:
            break

    # Dedup, cap
    seen = set()
    unique = []
    for f in found:
        if f not in seen:
            seen.add(f)
            unique.append(f)
    return unique[:15]


def extract_search_keyword(question):
    """
    Pull the most likely search keyword out of a natural language question.
    Strips filler words, keeps the most distinctive token(s).
    """
    skip = {
        "find", "where", "is", "the", "a", "an", "my", "for", "what", "how",
        "show", "me", "locate", "get", "path", "to", "of", "executable",
        "exe", "file", "install", "installed", "directory", "folder"
    }
    words = [w.strip("?.,!'\"") for w in question.lower().split()]
    keywords = [w for w in words if w not in skip and len(w) > 2]
    return keywords[0] if keywords else None


def looks_like_file_search(question):
    """Heuristic: does this question look like it's asking to locate a file/app/game?"""
    q = question.lower()
    triggers = ["find", "where", "locate", "exe", "executable", "installed",
                "path to", "directory for", "folder for"]
    return any(t in q for t in triggers)
