#!/usr/bin/env bash
# Dragon Shell Installer
# Supports: Arch, Garuda, EndeavourOS, CachyOS, Fedora, Debian, Ubuntu

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/share/dragon-shell"
SERVICE_FILE="$HOME/.config/systemd/user/dragon-shell-server.service"
PLASMOID_DIR="$HOME/.local/share/plasma/plasmoids/com.dragonshell.widget"

echo ""
echo "🐉 Dragon Shell Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Detect distro ────────────────────────────────────────────────────
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

DISTRO=$(detect_distro)
case "$DISTRO" in
    garuda)       PKG_MANAGER="paru"; DISTRO_NAME="Garuda Linux" ;;
    arch)         PKG_MANAGER="paru"; DISTRO_NAME="Arch Linux" ;;
    endeavouros)  PKG_MANAGER="paru"; DISTRO_NAME="EndeavourOS" ;;
    cachyos)      PKG_MANAGER="paru"; DISTRO_NAME="CachyOS" ;;
    fedora)       PKG_MANAGER="dnf";  DISTRO_NAME="Fedora" ;;
    debian|ubuntu|linuxmint) PKG_MANAGER="apt"; DISTRO_NAME="$PRETTY_NAME" ;;
    *)            PKG_MANAGER="apt"; DISTRO_NAME="$DISTRO" ;;
esac

echo "Detected OS: $DISTRO_NAME"
echo ""

# ── Shell detection ──────────────────────────────────────────────────
CURRENT_SHELL=$(basename "$SHELL")
echo "Detected shell: $CURRENT_SHELL"
echo ""

# ── GPU detection ────────────────────────────────────────────────────
detect_gpu() {
    if lspci 2>/dev/null | grep -qi "radeon\|amd.*vga\|advanced micro.*vga"; then
        echo "AMD"
    elif lspci 2>/dev/null | grep -qi "nvidia"; then
        echo "Nvidia"
    elif lspci 2>/dev/null | grep -qi "intel.*vga\|intel.*graphics"; then
        echo "Intel"
    else
        echo "Unknown"
    fi
}

GPU_VENDOR=$(detect_gpu)
echo "Detected GPU: $GPU_VENDOR"
echo ""

# ── Desktop detection ────────────────────────────────────────────────
DESKTOP="${XDG_CURRENT_DESKTOP:-Unknown}"
echo "Detected desktop: $DESKTOP"
echo ""

# ── Check Ollama ────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Checking Ollama"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if ! command -v ollama &>/dev/null; then
    echo "Ollama not found. Installing..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    echo "✓ Ollama is installed ($(ollama --version))"
fi
echo ""

# ── Model selection ──────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Choose AI model"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  1) qwen2.5-coder:14b  — Best for commands (recommended, ~9GB)"
echo "  2) qwen2.5-coder:7b   — Faster, less accurate (~4GB)"
echo "  3) qwen2.5:14b        — General purpose (~9GB)"
echo "  4) I already have a model I want to use"
echo ""
read -p "Choose [1-4, default=1]: " MODEL_CHOICE
case "$MODEL_CHOICE" in
    2) SELECTED_MODEL="qwen2.5-coder:7b" ;;
    3) SELECTED_MODEL="qwen2.5:14b" ;;
    4)
        read -p "Enter model name (e.g. mistral:7b): " SELECTED_MODEL
        ;;
    *) SELECTED_MODEL="qwen2.5-coder:14b" ;;
esac

echo ""
echo "Checking if $SELECTED_MODEL is already downloaded..."
if ollama list 2>/dev/null | grep -q "^${SELECTED_MODEL}"; then
    echo "✓ Model already installed"
else
    echo "Pulling $SELECTED_MODEL (this may take a few minutes)..."
    ollama pull "$SELECTED_MODEL"
fi
echo ""

# ── AMD ROCm env vars ────────────────────────────────────────────────
OLLAMA_ENV_VARS=""
if [ "$GPU_VENDOR" = "AMD" ]; then
    echo "AMD GPU detected — configuring ROCm environment..."
    OLLAMA_ENV_VARS='Environment="HSA_OVERRIDE_GFX_VERSION=10.3.0"
Environment="OLLAMA_VULKAN=false"'
fi

# ── Install files ────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Installing Dragon Shell"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "$INSTALL_DIR/config"
mkdir -p "$INSTALL_DIR/prompts"
mkdir -p "$HOME/.config/systemd/user"

# Copy main files
cp "$REPO_DIR/server.py" "$INSTALL_DIR/server.py"
cp "$REPO_DIR/backend.py" "$INSTALL_DIR/backend.py"

# Generate settings.json with detected values
cat > "$INSTALL_DIR/config/settings.json" << SETTINGS
{
  "model": "$SELECTED_MODEL",
  "ollama_url": "http://localhost:11434",
  "journal_path": "$INSTALL_DIR/journal.log",
  "ollama_timeout": 60,
  "window_width": 760
}
SETTINGS

# Initialize empty DB and history if not already present
[ -f "$INSTALL_DIR/config/command_db.json" ] || echo '{"entries":[]}' > "$INSTALL_DIR/config/command_db.json"
[ -f "$INSTALL_DIR/config/history.json" ]    || echo '[]' > "$INSTALL_DIR/config/history.json"

# Generate system prompt with detected system info
sed \
    -e "s/{{DISTRO}}/$DISTRO_NAME/g" \
    -e "s/{{SHELL}}/$CURRENT_SHELL/g" \
    -e "s/{{PKG_MANAGER}}/$PKG_MANAGER/g" \
    -e "s/{{DESKTOP}}/$DESKTOP/g" \
    -e "s/{{GPU_VENDOR}}/$GPU_VENDOR/g" \
    "$REPO_DIR/prompts/system.txt" > "$INSTALL_DIR/prompts/system.txt"

echo "✓ Files installed to $INSTALL_DIR"

# ── Install Plasma widget ────────────────────────────────────────────
if command -v kpackagetool6 &>/dev/null; then
    echo ""
    echo "Installing KDE Plasma widget..."
    mkdir -p "$PLASMOID_DIR/contents/ui"
    cp "$REPO_DIR/plasmoid/metadata.json" "$PLASMOID_DIR/metadata.json"
    cp "$REPO_DIR/plasmoid/contents/ui/main.qml" "$PLASMOID_DIR/contents/ui/main.qml"
    kpackagetool6 --remove com.dragonshell.widget 2>/dev/null || true
    kpackagetool6 --install "$PLASMOID_DIR"
    echo "✓ Plasma widget installed"
    echo "  → Right-click your panel → Add Widgets → search 'Dragon Shell'"
else
    echo "⚠  KDE Plasma not detected — skipping widget install"
    echo "   You can still run Dragon Shell manually: python3 $INSTALL_DIR/server.py"
fi

# ── Install systemd service ──────────────────────────────────────────
echo ""
echo "Installing systemd service..."
cat > "$SERVICE_FILE" << SERVICE
[Unit]
Description=Dragon Shell HTTP Server
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/server.py
$OLLAMA_ENV_VARS
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
SERVICE

systemctl --user daemon-reload
systemctl --user enable --now dragon-shell-server
echo "✓ Service installed and started"

# ── Install Python deps ──────────────────────────────────────────────
echo ""
echo "Checking Python dependencies..."
python3 -c "import requests" 2>/dev/null || pip install requests --break-system-packages
python3 -c "import difflib" 2>/dev/null && echo "✓ Python dependencies OK"

# ── Done ─────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Dragon Shell installed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Add the widget to your panel:"
echo "     Right-click panel → Add Widgets → 'Dragon Shell'"
if [ "$DESKTOP" = "KDE" ] || [ "$DESKTOP" = "KDE Plasma" ]; then
    echo "     Then: plasmashell --replace & (to reload Plasma)"
fi
echo ""
echo "  2. Click the widget to open Dragon Shell"
echo "     (Ollama starts automatically on first query)"
echo ""
echo "  3. After each working command, click '✓ This worked'"
echo "     to save it to your personal database"
echo ""
echo "  Installed to: $INSTALL_DIR"
echo "  Service:      systemctl --user status dragon-shell-server"
echo "  Logs:         journalctl --user -u dragon-shell-server -f"
echo ""
