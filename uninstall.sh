#!/bin/bash
#
# ORDER Uninstallation Script
#
# Removes ORDER and restores original CHAOS behavior.
#
# Usage:
#   ~/order/uninstall.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "================================"
echo "  ORDER Uninstallation"
echo "================================"
echo ""

# Check if ORDER is installed
if [ ! -d ".CHAOS/order" ]; then
    echo -e "${RED}ERROR: ORDER is not installed in this project.${NC}"
    exit 1
fi

# Confirm
read -p "Remove ORDER from this project? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Step 1: Remove ORDER agents
echo -n "Removing ORDER agents... "
rm -f .claude/agents/order-arbiter.md
rm -f .claude/agents/order-oracle.md
rm -f .claude/agents/order-sentinel.md
echo -e "${GREEN}OK${NC}"

# Step 2: Restore dispute-resolver backup
echo -n "Restoring dispute-resolver... "
if [ -f ".claude/agents/dispute-resolver.md.chaos-backup" ]; then
    mv .claude/agents/dispute-resolver.md.chaos-backup .claude/agents/dispute-resolver.md
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}SKIP (no backup found)${NC}"
fi

# Step 3: Remove ORDER skills
echo -n "Removing ORDER skills... "
rm -rf .claude/skills/loop
rm -rf .claude/skills/order-status
echo -e "${GREEN}OK${NC}"

# Step 4: Clean up index files (remove ORDER sections)
echo -n "Cleaning up index files... "
# Cross-platform sed -i (BSD/macOS vs GNU)
sedi() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

if [ -f ".claude/agents/index.yml" ]; then
    # Remove ORDER section from agent index
    sedi '/# ORDER Agents/,$d' .claude/agents/index.yml 2>/dev/null || true
fi
if [ -f ".claude/skills/index.yml" ]; then
    # Remove ORDER section from skills index
    sedi '/# ORDER Skills/,$d' .claude/skills/index.yml 2>/dev/null || true
fi
echo -e "${GREEN}OK${NC}"

# Step 5: Remove ORDER directory (but keep queue for reference)
echo -n "Removing ORDER configuration... "
if [ -f ".CHAOS/order/queue.txt" ] && [ -s ".CHAOS/order/queue.txt" ]; then
    echo -e "${YELLOW}Preserving non-empty queue.txt${NC}"
    mv .CHAOS/order/queue.txt .CHAOS/order-queue-backup.txt
fi
rm -rf .CHAOS/order
echo -e "${GREEN}OK${NC}"

# Done
echo ""
echo "================================"
echo -e "  ${GREEN}ORDER Uninstalled${NC}"
echo "================================"
echo ""
echo "ORDER has been removed. CHAOS will now operate in"
echo "human-in-the-loop mode (default behavior)."
echo ""
if [ -f ".CHAOS/order-queue-backup.txt" ]; then
    echo "Note: Your spec queue was preserved at:"
    echo "  .CHAOS/order-queue-backup.txt"
    echo ""
fi
