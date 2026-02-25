#!/bin/sh
# Install opty systemd user services
# Usage: ./install.sh [--uninstall]

set -e

OPTY_BIN="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/opty"
SERVICE_DIR="$(dirname "$0")"
SYSTEMD_DIR="$HOME/.config/systemd/user"

if [ "$1" = "--uninstall" ]; then
    echo "Stopping opty services..."
    systemctl --user stop opty-daemon.service 2>/dev/null || true
    systemctl --user disable opty-daemon.service 2>/dev/null || true

    echo "Removing service files..."
    rm -f "$SYSTEMD_DIR/opty-daemon.service"
    rm -f "$SYSTEMD_DIR/opty-daemon@.service"
    systemctl --user daemon-reload

    echo "Uninstalled. Binary at $HOME/.local/bin/opty left in place."
    exit 0
fi

# Install binary
echo "Installing opty binary..."
if [ ! -f "$OPTY_BIN" ]; then
    echo "Error: opty binary not found at $OPTY_BIN"
    echo "Run 'zig build' first."
    exit 1
fi
mkdir -p "$HOME/.local/bin"
cp "$OPTY_BIN" "$HOME/.local/bin/opty"
chmod +x "$HOME/.local/bin/opty"
echo "  -> $HOME/.local/bin/opty"

# Install service files
echo "Installing systemd user services..."
mkdir -p "$SYSTEMD_DIR"
cp "$SERVICE_DIR/opty-daemon.service" "$SYSTEMD_DIR/"
cp "$SERVICE_DIR/opty-daemon@.service" "$SYSTEMD_DIR/"
echo "  -> $SYSTEMD_DIR/opty-daemon.service"
echo "  -> $SYSTEMD_DIR/opty-daemon@.service"

systemctl --user daemon-reload
echo ""
echo "Installed! Usage:"
echo ""
echo "  # Watch your home Development directory (default):"
echo "  systemctl --user enable --now opty-daemon"
echo ""
echo "  # Watch a specific directory (template instance):"
echo "  systemctl --user enable --now 'opty-daemon@/home/you/projects/myapp.service'"
echo ""
echo "  # Check status / logs:"
echo "  systemctl --user status opty-daemon"
echo "  journalctl --user -u opty-daemon -f"
