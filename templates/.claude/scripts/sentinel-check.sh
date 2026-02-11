#!/bin/bash
# ORDER Sentinel Check — Pure bash safety gate
#
# Usage: bash .claude/scripts/sentinel-check.sh
#
# Checks all safety limits before each task execution.
# Exits 0 (CONTINUE) or 1 (STOP).
#
# Checks (in order):
#   1. Kill file (.chaos/framework/order/STOP)
#   2. Iteration limit
#   3. Time limit
#   4. Consecutive failures
#   5. PR pipeline health

set -euo pipefail

CONFIG=".chaos/framework/order/config.yml"
STATE=".chaos/framework/order/state.json"

# --- Helpers ---

yaml_val() {
    # Extract a simple YAML value: yaml_val "key" "file"
    grep -m1 "^\s*$1:" "$2" 2>/dev/null | sed 's/.*:\s*//' | tr -d ' '
}

# --- Preflight ---

if [[ ! -f "$CONFIG" ]]; then
    echo "STOP: Config file not found ($CONFIG)"
    exit 1
fi

if [[ ! -f "$STATE" ]]; then
    echo "STOP: State file not found ($STATE)"
    exit 1
fi

# Verify jq is available
if ! command -v jq &>/dev/null; then
    echo "STOP: jq is required but not installed"
    exit 1
fi

# --- Check 1: Kill File ---

if [[ -f ".chaos/framework/order/STOP" ]]; then
    echo "STOP: Kill file detected (.chaos/framework/order/STOP)"
    # Update state
    jq '.status = "stopped" | .last_check = now | todate' "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE" 2>/dev/null || true
    exit 1
fi

# --- Check 2: Iteration Limit ---

MAX_ITER=$(yaml_val "max_iterations" "$CONFIG")
CURRENT_ITER=$(jq -r '.iteration // 0' "$STATE")

if [[ -n "$MAX_ITER" ]] && [[ "$CURRENT_ITER" -ge "$MAX_ITER" ]]; then
    echo "STOP: Iteration limit reached ($CURRENT_ITER >= $MAX_ITER)"
    exit 1
fi

# --- Check 3: Time Limit ---

MAX_HOURS=$(yaml_val "max_time_hours" "$CONFIG")
STARTED_AT=$(jq -r '.started_at // empty' "$STATE")

if [[ -n "$MAX_HOURS" ]] && [[ -n "$STARTED_AT" ]]; then
    NOW_EPOCH=$(date +%s)
    # Cross-platform epoch conversion
    if date --version 2>/dev/null | grep -q GNU; then
        START_EPOCH=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo "$NOW_EPOCH")
    else
        START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${STARTED_AT%%[+-]*}" +%s 2>/dev/null || echo "$NOW_EPOCH")
    fi
    ELAPSED_HOURS=$(( (NOW_EPOCH - START_EPOCH) / 3600 ))

    if [[ "$ELAPSED_HOURS" -ge "$MAX_HOURS" ]]; then
        echo "STOP: Time limit reached (${ELAPSED_HOURS}h >= ${MAX_HOURS}h)"
        exit 1
    fi
fi

# --- Check 4: Consecutive Failures ---

MAX_FAILURES=$(yaml_val "max_consecutive_failures" "$CONFIG")
CONSECUTIVE=$(jq -r '.consecutive_failures // 0' "$STATE")

if [[ -n "$MAX_FAILURES" ]] && [[ "$CONSECUTIVE" -ge "$MAX_FAILURES" ]]; then
    echo "STOP: Too many consecutive failures ($CONSECUTIVE >= $MAX_FAILURES)"
    exit 1
fi

# --- Check 5: PR Pipeline Health ---

MAX_CONCURRENT=$(yaml_val "max_concurrent_prs" "$CONFIG")

if [[ -n "$MAX_CONCURRENT" ]] && command -v gh &>/dev/null; then
    OPEN_PRS=$(gh pr list --search "head:task/" --json number -q 'length' 2>/dev/null || echo "0")
    if [[ "$OPEN_PRS" -ge "$MAX_CONCURRENT" ]]; then
        echo "STOP: Too many open PRs ($OPEN_PRS >= $MAX_CONCURRENT)"
        exit 1
    fi
fi

# --- Update State ---

LAST_CHECK=$(date -Iseconds)
jq --arg ts "$LAST_CHECK" '.last_check = $ts' "$STATE" > "${STATE}.tmp" && mv "${STATE}.tmp" "$STATE" 2>/dev/null || true

# --- All Clear ---

echo "CONTINUE: All safety checks passed (iter $CURRENT_ITER/$MAX_ITER, failures $CONSECUTIVE/$MAX_FAILURES)"
exit 0
