#!/bin/bash
#
# ORDER Uninstallation Script v2.0.0
#
# Removes ORDER and restores CHAOS v2 to standalone developer mode.
#
# Usage:
#   ~/order/uninstall.sh
#
# Options:
#   --force    Skip confirmation prompts (for CI/scripts)
#

set -e

# Parse arguments
FORCE_MODE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force]"
            exit 1
            ;;
    esac
done

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
if [ ! -d ".chaos/framework/order" ]; then
    echo -e "${RED}ERROR: ORDER is not installed in this project.${NC}"
    exit 1
fi

# Show what will be removed
echo "This will remove:"
echo "  - ORDER skills (plan-work, loop, parallel, work-wrapper, order-status,"
echo "    order-oracle, order-arbiter, parse-roadmap, create-spec, review-spec,"
echo "    verify-completion, handoff, order-resume, order-run)"
echo "  - ORDER scripts (sentinel-check.sh, post-task-hook.sh, order-run-loop.sh)"
echo "  - ORDER configuration (.chaos/framework/order/)"
echo "  - ORDER handoffs (.chaos/framework/order/handoffs/)"
echo "  - ORDER state (.chaos/framework/order/state.json)"
echo "  - ORDER skill index entries"
echo ""

# Confirm
if [ "$FORCE_MODE" = true ]; then
    echo "Removing ORDER (--force mode)..."
else
    read -p "Remove ORDER from this project? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Step 1: Remove ORDER skills
echo -n "Removing ORDER skills... "

rm -rf .claude/skills/plan-work
rm -rf .claude/skills/loop
rm -rf .claude/skills/parallel
rm -rf .claude/skills/work-wrapper
rm -rf .claude/skills/order-status
rm -rf .claude/skills/order-oracle
rm -rf .claude/skills/order-arbiter
rm -rf .claude/skills/parse-roadmap
rm -rf .claude/skills/create-spec
rm -rf .claude/skills/review-spec
rm -rf .claude/skills/verify-completion
rm -rf .claude/skills/handoff
rm -rf .claude/skills/order-resume
rm -rf .claude/skills/order-run
echo -e "${GREEN}OK${NC}"

# Step 2: Remove ORDER scripts
echo -n "Removing ORDER scripts... "
rm -f .claude/scripts/sentinel-check.sh
rm -f .claude/scripts/post-task-hook.sh
rm -f .claude/scripts/order-run-loop.sh
echo -e "${GREEN}OK${NC}"

# Step 3: Clean up index files (remove ORDER sections using start/end markers)
echo -n "Cleaning up index files... "

# Cross-platform sed -i (BSD/macOS vs GNU)
sedi() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# Remove leftover agent files from prior installs
rm -f .claude/agents/order-arbiter.md
rm -f .claude/agents/order-oracle.md
rm -f .claude/agents/order-sentinel.md
if [ -d ".claude/agents" ]; then
    remaining=$(find .claude/agents -type f 2>/dev/null | wc -l)
    if [ "$remaining" -eq 0 ]; then
        rm -rf .claude/agents
    fi
fi

# Remove ORDER section from skills index (between markers only)
if [ -f ".claude/skills/index.yml" ]; then
    if grep -q "# ORDER-START" .claude/skills/index.yml 2>/dev/null; then
        sedi '/# ORDER-START/,/# ORDER-END/d' .claude/skills/index.yml
    fi
fi
echo -e "${GREEN}OK${NC}"

# Step 4: Remove ORDER directory (preserve queue if non-empty)
echo -n "Removing ORDER configuration... "
if [ -f ".chaos/framework/order/queue.txt" ] && [ -s ".chaos/framework/order/queue.txt" ]; then
    # Check if queue has actual content (not just comments)
    has_tasks=$(grep -v '^#' .chaos/framework/order/queue.txt | grep -v '^$' | wc -l)
    if [ "$has_tasks" -gt 0 ]; then
        echo -e "${YELLOW}Preserving non-empty queue.txt${NC}"
        mv .chaos/framework/order/queue.txt .chaos/framework/order-queue-backup.txt
    fi
fi
rm -rf .chaos/framework/order
echo -e "${GREEN}OK${NC}"

# Done
echo ""
echo "================================"
echo -e "  ${GREEN}ORDER Uninstalled${NC}"
echo "================================"
echo ""
echo "ORDER has been removed. CHAOS v2 will continue operating"
echo "as a standalone single-developer framework."
echo ""
if [ -f ".chaos/framework/order-queue-backup.txt" ]; then
    echo "Note: Your task queue was preserved at:"
    echo "  .chaos/framework/order-queue-backup.txt"
    echo ""
fi
