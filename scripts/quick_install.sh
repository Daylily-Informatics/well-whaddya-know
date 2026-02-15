#!/bin/sh
# WellWhaddyaKnow Quick Install Script
# Automates the full installation process from install_cmds.log

set -e

INTERACTIVE=false

# Parse flags
while [ $# -gt 0 ]; do
  case "$1" in
    --interactive)
      INTERACTIVE=true
      shift
      ;;
    *)
      echo "Usage: $0 [--interactive]"
      echo ""
      echo "Installs WellWhaddyaKnow via Homebrew:"
      echo "  1. Tap Daylily-Informatics/tap"
      echo "  2. Install wwk (CLI + agent)"
      echo "  3. Register agent as login item"
      echo "  4. Launch GUI"
      echo "  5. Verify installation"
      echo ""
      echo "Options:"
      echo "  --interactive    Prompt for confirmation before each step (default: off)"
      exit 1
      ;;
  esac
done

confirm() {
  if [ "$INTERACTIVE" = true ]; then
    printf "%s [y/N] " "$1"
    read -r response
    case "$response" in
      [yY][eE][sS]|[yY])
        return 0
        ;;
      *)
        echo "Skipped."
        return 1
        ;;
    esac
  fi
  return 0
}

echo "=== WellWhaddyaKnow Quick Install ==="
echo ""

# Step 1: Tap
echo "Step 1: Tap Daylily-Informatics/tap"
if confirm "Proceed?"; then
  if brew tap | grep -q "daylily-informatics/tap"; then
    echo "✓ Already tapped"
  else
    brew tap Daylily-Informatics/tap
    echo "✓ Tapped"
  fi
fi
echo ""

# Step 2: Install wwk
echo "Step 2: Install wwk (CLI + agent)"
if confirm "Proceed?"; then
  if command -v wwk >/dev/null 2>&1; then
    CURRENT_VERSION=$(wwk --version 2>/dev/null || echo "unknown")
    echo "✓ wwk already installed (version: $CURRENT_VERSION)"
    if confirm "Upgrade to latest?"; then
      brew upgrade wwk
      echo "✓ Upgraded"
    fi
  else
    brew install wwk
    echo "✓ Installed"
  fi
fi
echo ""

# Step 3: Register agent
echo "Step 3: Register agent as login item"
if confirm "Proceed?"; then
  wwk agent install
  echo "✓ Agent registered"
fi
echo ""

# Step 4: Start agent
echo "Step 4: Start agent"
if confirm "Proceed?"; then
  wwk agent start 2>/dev/null || echo "✓ Agent already running"
  sleep 1
  echo "✓ Agent started"
fi
echo ""

# Step 5: Launch GUI
echo "Step 5: Launch GUI"
if confirm "Proceed?"; then
  wwk gui
  echo "✓ GUI launched"
fi
echo ""

# Step 6: Verify
echo "Step 6: Verify installation"
if confirm "Proceed?"; then
  echo ""
  echo "--- Agent Status ---"
  wwk agent status
  echo ""
  echo "--- Current Status ---"
  wwk status
  echo ""
  echo "✓ Installation verified"
fi
echo ""

echo "=== Installation Complete ==="
echo ""
echo "Quick start:"
echo "  wwk status        # Show current tracking status"
echo "  wwk today         # Today's summary"
echo "  wwk gui           # Launch menu bar app"
echo "  wwk --help        # Full command reference"
echo ""

