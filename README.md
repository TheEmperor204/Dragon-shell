# 🐉 Dragon Shell

A local, offline AI terminal assistant for Linux. Lives in your KDE Plasma panel as a native widget. Answers your terminal questions with commands, risk scores, and confidence ratings — all running on your own hardware with no cloud, no API keys, and no data leaving your machine.

![Dragon Shell Screenshot](docs/screenshot.png)

## Features

- **Native KDE Plasma 6 widget** — lives in your panel, opens as a dropdown
- **Three-layer intelligence:**
  - ✅ Personal command database (instant, verified by you)
  - 🤖 Local AI via Ollama (offline, private)
  - 🌐 Web search fallback when AI confidence is low
- **Risk scoring** — LOW / MODERATE / HIGH / EXTREME with color-coded bar
- **Btrfs snapshot suggestions** before high-risk commands
- **"✓ This worked" button** — saves verified commands to your personal database
- **History tab** — scroll through past queries
- **Ollama lazy-start** — only runs when you need it, shuts down when you close
- **VRAM-friendly** — model unloads from GPU on close
- **Shell-aware** — Fish, Bash, Zsh
- **Distro-aware** — Arch, Garuda, EndeavourOS, Fedora, Ubuntu and more

## Requirements

- Linux with KDE Plasma 6 (for the panel widget)
- [Ollama](https://ollama.com) (installed automatically if missing)
- Python 3.10+
- `python-requests` (`pip install requests`)

## Quick Install

```bash
git clone https://github.com/YOUR_USERNAME/dragon-shell.git
cd dragon-shell
bash install.sh
```

The installer will:
1. Detect your distro, shell, GPU, and desktop
2. Install Ollama if not present
3. Ask which AI model you want (with download)
4. Install the Plasma widget
5. Set up the background service (auto-starts on login)

Then right-click your panel → **Add Widgets** → search **Dragon Shell**.

## Supported Distros

| Distro | Package Manager | Status |
|--------|----------------|--------|
| Garuda Linux | paru | ✅ Flagship |
| Arch Linux | paru/yay | ✅ Supported |
| EndeavourOS | paru | ✅ Supported |
| CachyOS | paru | ✅ Supported |
| Fedora | dnf | ✅ Supported |
| Ubuntu/Debian | apt | ✅ Supported |

## Recommended Models

| Model | VRAM | Speed | Quality |
|-------|------|-------|---------|
| qwen2.5-coder:14b | ~9GB | Medium | ⭐⭐⭐⭐⭐ |
| qwen2.5-coder:7b | ~4GB | Fast | ⭐⭐⭐⭐ |
| qwen2.5:14b | ~9GB | Medium | ⭐⭐⭐⭐ |

## How It Works

```
You type a question
       ↓
1. Check personal command database (instant)
       ↓ (no match)
2. Ask local AI model via Ollama
       ↓ (low confidence)
3. Search DuckDuckGo for verification
       ↓
Show command + risk score + confidence
       ↓
Click "✓ This worked" → saved to database forever
```

## File Structure

```
~/.local/share/dragon-shell/
├── server.py          — HTTP server (port 29156)
├── backend.py         — DB, search, AI logic
├── prompts/
│   └── system.txt     — AI system prompt (auto-configured for your system)
├── config/
│   ├── settings.json  — Model and config
│   ├── command_db.json — Your personal verified commands
│   └── history.json   — Query history
└── journal.log        — Audit log

~/.local/share/plasma/plasmoids/com.dragonshell.widget/
└── contents/ui/main.qml — The panel widget UI
```

## Troubleshooting

**Widget shows error:**
```bash
plasmashell --replace &  # watch terminal for QML errors
```

**Server not running:**
```bash
systemctl --user status dragon-shell-server
journalctl --user -u dragon-shell-server -n 30
```

**Port already in use:**
```bash
pkill -f "python3.*server.py"
systemctl --user restart dragon-shell-server
```

## Privacy

Dragon Shell is fully local and offline:
- No data is sent to any external server
- Your command history stays on your machine
- The AI model runs locally via Ollama
- Web search (DuckDuckGo) is only used when AI confidence is low, and only queries the command syntax — no personal info

## License

GPL-2.0 — see [LICENSE](LICENSE)
