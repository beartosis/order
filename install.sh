#!/bin/bash
#
# ORDER Installation Script v2.0.0
#
# Installs ORDER on top of an existing CHAOS v2 installation.
# ORDER acts as Engineering Lead, decomposing specs into tasks,
# spawning CHAOS /work instances, and managing the PR lifecycle.
#
# Usage:
#   cd ~/my-project
#   ~/order/install.sh
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

# Get the directory where this script lives
ORDER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-platform sed -i (BSD/macOS vs GNU)
sedi() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

echo "================================"
echo "  ORDER v2.0.0 Installation"
echo "  Engineering Lead for CHAOS"
echo "================================"
echo ""

# Step 0: Check tool dependencies
echo -n "Checking dependencies... "
missing_deps=()

if ! command -v jq &>/dev/null; then
    missing_deps+=("jq")
fi

if ! command -v bd &>/dev/null; then
    missing_deps+=("bd (Beads)")
fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo -e "${RED}FAILED${NC}"
    echo ""
    echo "ERROR: Missing required tools: ${missing_deps[*]}"
    echo ""
    echo "Install them with:"
    echo "  # jq"
    echo "  brew install jq          # macOS"
    echo "  sudo apt-get install jq  # Ubuntu/Debian"
    echo ""
    echo "  # Beads (bd)"
    echo "  go install github.com/steveyegge/beads/cmd/bd@latest"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Check for gh CLI (advisory)
echo -n "Checking for GitHub CLI... "
if ! command -v gh &>/dev/null; then
    echo -e "${YELLOW}NOT FOUND (advisory)${NC}"
    echo "  gh CLI is recommended for PR workflow."
    echo "  Install: https://cli.github.com/"
else
    echo -e "${GREEN}OK${NC}"
fi

# Step 1: Verify CHAOS v2 is installed and compatible
echo -n "Checking for CHAOS v2 installation... "
if [ ! -f ".chaos/framework/version" ]; then
    echo -e "${RED}FAILED${NC}"
    echo ""
    echo "ERROR: CHAOS is not installed in this project."
    echo "Please install CHAOS first:"
    echo "  ~/chaos/install.sh"
    exit 1
fi

# Check CHAOS version is v2
chaos_version=$(cat .chaos/framework/version)
if [[ ! "$chaos_version" == *"2."* ]]; then
    echo -e "${RED}FAILED${NC}"
    echo ""
    echo "ERROR: ORDER v2 requires CHAOS v2."
    echo "Found: $chaos_version"
    echo "Please upgrade CHAOS first."
    exit 1
fi

# Verify CHAOS v2 required files exist
if [ ! -f ".claude/skills/work/SKILL.md" ]; then
    echo -e "${RED}FAILED${NC}"
    echo ""
    echo "ERROR: CHAOS v2 /work skill not found."
    echo "ORDER requires CHAOS v2 with the /work skill installed."
    echo "Please reinstall CHAOS: ~/chaos/install.sh"
    exit 1
fi

if [ ! -d ".claude/skills" ]; then
    echo -e "${RED}FAILED${NC}"
    echo ""
    echo "ERROR: CHAOS installation appears incomplete."
    echo "Missing .claude/skills directory."
    echo "Please reinstall CHAOS: ~/chaos/install.sh"
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Migration cleanup: remove leftover agent files from prior installs
if [ -d ".claude/agents" ]; then
    rm -f .claude/agents/order-arbiter.md
    rm -f .claude/agents/order-oracle.md
    rm -f .claude/agents/order-sentinel.md
    if [ -f ".claude/agents/index.yml" ] && grep -q "# ORDER-START" .claude/agents/index.yml 2>/dev/null; then
        sedi '/# ORDER-START/,/# ORDER-END/d' .claude/agents/index.yml
    fi
    # Remove agents dir if empty
    remaining=$(find .claude/agents -type f 2>/dev/null | wc -l)
    if [ "$remaining" -eq 0 ]; then
        rm -rf .claude/agents
    fi
fi

# Step 2: Check for existing ORDER installation
if [ -d ".chaos/framework/order" ]; then
    echo -e "${YELLOW}WARNING: ORDER is already installed.${NC}"
    if [ "$FORCE_MODE" = true ]; then
        echo "Reinstalling (--force mode)..."
    else
        read -p "Reinstall? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
fi

# Step 3: Install ORDER skills
echo -n "Installing ORDER skills... "

# Verify skill templates exist
if [ ! -d "$ORDER_DIR/templates/.claude/skills" ]; then
    echo -e "${RED}FAILED${NC}"
    echo "ERROR: ORDER skill templates not found"
    exit 1
fi

skill_count=0
for skill_dir in "$ORDER_DIR/templates/.claude/skills"/*; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    mkdir -p ".claude/skills/$skill_name"

    # Copy and rename .tmpl files
    for tmpl in "$skill_dir"/*.tmpl; do
        [ -f "$tmpl" ] || continue
        filename=$(basename "$tmpl" .tmpl)
        cp "$tmpl" ".claude/skills/$skill_name/$filename"
    done

    # Copy non-template files
    for file in "$skill_dir"/*; do
        [ -f "$file" ] || continue
        [[ "$file" == *.tmpl ]] && continue
        cp "$file" ".claude/skills/$skill_name/"
    done

    skill_count=$((skill_count + 1))
done

# Merge skill index with start/end markers (idempotent)
if [ -f "$ORDER_DIR/templates/.claude/skills/index.yml" ]; then
    if ! grep -q "# ORDER-START" .claude/skills/index.yml 2>/dev/null; then
        {
            echo ""
            echo "# ORDER-START (do not edit this line)"
            cat "$ORDER_DIR/templates/.claude/skills/index.yml"
            echo "# ORDER-END (do not edit this line)"
        } >> .claude/skills/index.yml
    fi
fi
echo -e "${GREEN}OK${NC} ($skill_count skills)"

# Step 4: Install ORDER scripts
echo -n "Installing ORDER scripts... "
if [ -d "$ORDER_DIR/templates/.claude/scripts" ]; then
    mkdir -p .claude/scripts
    for script in "$ORDER_DIR/templates/.claude/scripts/"*; do
        [ -f "$script" ] || continue
        filename=$(basename "$script")
        cp "$script" ".claude/scripts/$filename"
        chmod +x ".claude/scripts/$filename"
    done
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}SKIPPED (no scripts found)${NC}"
fi

# Step 5: Create ORDER directory and config
echo -n "Creating ORDER configuration... "
mkdir -p .chaos/framework/order

if [ ! -d "$ORDER_DIR/templates/.chaos/framework/order" ]; then
    echo -e "${RED}FAILED${NC}"
    echo "ERROR: ORDER config templates not found"
    exit 1
fi

config_count=0
for tmpl in "$ORDER_DIR/templates/.chaos/framework/order/"*.tmpl; do
    [ -f "$tmpl" ] || continue
    filename=$(basename "$tmpl" .tmpl)
    cp "$tmpl" ".chaos/framework/order/$filename"
    config_count=$((config_count + 1))
done

# Copy non-template files
for file in "$ORDER_DIR/templates/.chaos/framework/order/"*; do
    [ -f "$file" ] || continue
    [[ "$file" == *.tmpl ]] && continue
    cp "$file" ".chaos/framework/order/"
done
echo -e "${GREEN}OK${NC}"

# Create handoff directory
mkdir -p .chaos/framework/order/handoffs

# Initialize state file if not exists
if [ ! -f ".chaos/framework/order/state.json" ]; then
    echo '{"current_state":"INIT"}' > .chaos/framework/order/state.json
fi

# Step 6: Record installation
echo -n "Recording installation... "
echo "ORDER_VERSION=2.0.0" > .chaos/framework/order/version
echo "$(date -Iseconds)" > .chaos/framework/order/installed
echo "$ORDER_DIR" > .chaos/framework/order/framework_path
echo -e "${GREEN}OK${NC}"

# Done
echo ""
echo "================================"
echo -e "  ${GREEN}ORDER v2.0.0 Installed${NC}"
echo "================================"
echo ""
echo "ORDER is now installed as Engineering Lead."
echo ""
echo "Available commands:"
echo ""
echo "  Orchestration (autonomous):"
echo "    .claude/scripts/order-run-loop.sh              Run full lifecycle"
echo "    .claude/scripts/order-run-loop.sh --max-steps 3   Limit steps"
echo "    claude /order-run                              Run from interactive session"
echo ""
echo "  Roadmap:"
echo "    /parse-roadmap        Extract next roadmap step"
echo "    /create-spec <step>   Create Spec Contract from roadmap step"
echo "    /review-spec <path>   Validate Spec Contract (forked context)"
echo ""
echo "  Planning & Execution:"
echo "    /plan-work <spec>     Decompose spec into Beads Issue Contracts"
echo "    /loop [task-id]       Process a task autonomously"
echo "    /loop --queue         Process all tasks in queue"
echo "    /parallel --queue     Process tasks in parallel waves"
echo ""
echo "  Verification & Lifecycle:"
echo "    /verify-completion <step>  Check all completion gates"
echo "    /handoff <step>            Create ORDER-to-ORDER handoff"
echo "    /order-resume <file>       Resume from handoff document"
echo ""
echo "  Monitoring:"
echo "    /order-status         Check execution status"
echo ""
echo "Configuration: .chaos/framework/order/config.yml"
echo "Task queue:    .chaos/framework/order/queue.txt"
echo ""
echo "To uninstall ORDER:"
echo "  $ORDER_DIR/uninstall.sh"
echo ""
