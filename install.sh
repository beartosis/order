#!/bin/bash
#
# ORDER Installation Script
#
# Installs ORDER on top of an existing CHAOS installation.
# ORDER enables autonomous, human-free operation.
#
# Usage:
#   cd ~/my-project
#   ~/order/install.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script lives
ORDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================"
echo "  ORDER Installation"
echo "  Autonomous Operation for CHAOS"
echo "================================"
echo ""

# Step 0: Check tool dependencies
echo -n "Checking dependencies... "
missing_deps=()

if ! command -v jq &>/dev/null; then
    missing_deps+=("jq")
fi

if ! command -v bc &>/dev/null; then
    missing_deps+=("bc")
fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo -e "${RED}FAILED${NC}"
    echo ""
    echo "ERROR: Missing required tools: ${missing_deps[*]}"
    echo ""
    echo "Install them with:"
    echo "  # macOS"
    echo "  brew install ${missing_deps[*]}"
    echo ""
    echo "  # Ubuntu/Debian"
    echo "  sudo apt-get install ${missing_deps[*]}"
    echo ""
    echo "  # Fedora/RHEL"
    echo "  sudo dnf install ${missing_deps[*]}"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Step 1: Verify CHAOS is installed
echo -n "Checking for CHAOS installation... "
if [ ! -f ".CHAOS/version" ]; then
    echo -e "${RED}FAILED${NC}"
    echo ""
    echo "ERROR: CHAOS is not installed in this project."
    echo "Please install CHAOS first:"
    echo "  ~/chaos/install.sh"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Step 2: Check for existing ORDER installation
if [ -d ".CHAOS/order" ]; then
    echo -e "${YELLOW}WARNING: ORDER is already installed.${NC}"
    read -p "Reinstall? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Step 3: Backup existing dispute-resolver
echo -n "Backing up dispute-resolver... "
if [ -f ".claude/agents/dispute-resolver.md" ]; then
    cp .claude/agents/dispute-resolver.md .claude/agents/dispute-resolver.md.chaos-backup
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}SKIP (not found)${NC}"
fi

# Step 4: Install ORDER agents
echo -n "Installing ORDER agents... "
cp "$ORDER_DIR/templates/.claude/agents/"*.tmpl .claude/agents/ 2>/dev/null || true
# Remove .tmpl extension
for f in .claude/agents/*.tmpl; do
    [ -f "$f" ] && mv "$f" "${f%.tmpl}"
done

# Copy agent index (merge with existing, idempotent)
if [ -f "$ORDER_DIR/templates/.claude/agents/index.yml" ]; then
    if ! grep -q "# ORDER Agents" .claude/agents/index.yml 2>/dev/null; then
        echo "" >> .claude/agents/index.yml
        echo "# ORDER Agents (added by ORDER installer)" >> .claude/agents/index.yml
        cat "$ORDER_DIR/templates/.claude/agents/index.yml" >> .claude/agents/index.yml
    fi
fi
echo -e "${GREEN}OK${NC}"

# Step 5: Install ORDER skills
echo -n "Installing ORDER skills... "
mkdir -p .claude/skills/loop
mkdir -p .claude/skills/order-status
cp "$ORDER_DIR/templates/.claude/skills/loop/"* .claude/skills/loop/ 2>/dev/null || true
cp "$ORDER_DIR/templates/.claude/skills/order-status/"* .claude/skills/order-status/ 2>/dev/null || true
# Remove .tmpl extension
for f in .claude/skills/loop/*.tmpl .claude/skills/order-status/*.tmpl; do
    [ -f "$f" ] && mv "$f" "${f%.tmpl}"
done

# Merge skill index (idempotent)
if [ -f "$ORDER_DIR/templates/.claude/skills/index.yml" ]; then
    if ! grep -q "# ORDER Skills" .claude/skills/index.yml 2>/dev/null; then
        echo "" >> .claude/skills/index.yml
        echo "# ORDER Skills (added by ORDER installer)" >> .claude/skills/index.yml
        cat "$ORDER_DIR/templates/.claude/skills/index.yml" >> .claude/skills/index.yml
    fi
fi
echo -e "${GREEN}OK${NC}"

# Step 6: Create ORDER directory and config
echo -n "Creating ORDER configuration... "
mkdir -p .CHAOS/order
cp "$ORDER_DIR/templates/.CHAOS/order/"*.tmpl .CHAOS/order/ 2>/dev/null || true
# Remove .tmpl extension
for f in .CHAOS/order/*.tmpl; do
    [ -f "$f" ] && mv "$f" "${f%.tmpl}"
done
echo -e "${GREEN}OK${NC}"

# Step 7: Record installation
echo -n "Recording installation... "
echo "$(date -Iseconds)" > .CHAOS/order/installed
echo "$ORDER_DIR" > .CHAOS/order/framework_path
echo -e "${GREEN}OK${NC}"

# Done
echo ""
echo "================================"
echo -e "  ${GREEN}ORDER Installed Successfully${NC}"
echo "================================"
echo ""
echo "ORDER is now installed. Available commands:"
echo ""
echo "  /loop [spec-name]     Process a spec autonomously"
echo "  /loop --queue         Process all specs in queue"
echo "  /loop --auto          Generate and execute specs"
echo "  /order-status         Check execution status"
echo ""
echo "Configuration: .CHAOS/order/config.yml"
echo "Spec queue:    .CHAOS/order/queue.txt"
echo ""
echo "To uninstall ORDER:"
echo "  $ORDER_DIR/uninstall.sh"
echo ""
