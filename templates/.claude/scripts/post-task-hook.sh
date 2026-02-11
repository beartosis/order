#!/bin/bash
# ORDER Post-Task Hook — Capture results from spawned CHAOS instances
#
# Usage: bash .claude/scripts/post-task-hook.sh <task-id> <exit-code>
#
# Called by /loop and /parallel after each spawned CHAOS instance exits.
# Extracts PR number, updates state.json atomically, writes result.json.

set -euo pipefail

TASK_ID="${1:-}"
EXIT_CODE="${2:-1}"

if [[ -z "$TASK_ID" ]]; then
    echo "Usage: bash .claude/scripts/post-task-hook.sh <task-id> <exit-code>"
    exit 1
fi

STATE=".chaos/framework/order/state.json"
RUN_DIR=".chaos/framework/runs/$TASK_ID"

mkdir -p "$RUN_DIR"

# --- Extract PR number ---
# Branch naming: /work creates task/$TASK_ID (e.g. task/step-7-task-1).
# Primary strategy is exact match. Fallbacks exist for legacy naming.

PR_NUM=""
if command -v gh &>/dev/null; then
    # Strategy 1 (primary): exact branch match task/$TASK_ID
    PR_NUM=$(gh pr list --head "task/$TASK_ID" --json number -q '.[0].number' 2>/dev/null || echo "")

    # Strategy 2 (fallback): beads-prefixed branch task/$BD_ID-$TASK_ID
    if [[ -z "$PR_NUM" ]]; then
        echo "  WARN: No PR found for task/$TASK_ID, trying beads-prefixed branch..."
        QUEUE_FILE=".chaos/framework/order/queue.txt"
        if [[ -f "$QUEUE_FILE" ]]; then
            BD_ID=$(grep "^${TASK_ID}|" "$QUEUE_FILE" | sed -n 's/.*bd:\([^|]*\).*/\1/p')
            if [[ -n "$BD_ID" ]]; then
                PR_NUM=$(gh pr list --head "task/${BD_ID}-${TASK_ID}" --json number -q '.[0].number' 2>/dev/null || echo "")
            fi
        fi
    fi

    # Strategy 3 (last resort): suffix match
    if [[ -z "$PR_NUM" ]]; then
        echo "  WARN: Fallback PR search — branch suffix match for -${TASK_ID}..."
        PR_NUM=$(gh pr list --state open --json number,headRefName \
            --jq "[.[] | select(.headRefName | endswith(\"-${TASK_ID}\"))] | .[0].number // empty" \
            2>/dev/null || echo "")
    fi
fi

# --- Recovery: commit + push + PR if work exists but no PR ---
if [[ "$EXIT_CODE" -eq 0 ]] && [[ -z "$PR_NUM" ]]; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    if [[ "$BRANCH" == task/* ]]; then
        # Stage code changes (explicit dirs, never -A)
        git add internal/ cmd/ migrations/ 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "feat: ${TASK_ID}" 2>/dev/null || true
            git push -u origin "$BRANCH" 2>/dev/null || true
            PR_NUM=$(gh pr create --draft \
                --title "${TASK_ID}" \
                --body "Auto-recovered by post-task hook" \
                2>/dev/null | grep -oP '\d+$' || echo "")
            if [[ -n "$PR_NUM" ]]; then
                echo "  RECOVERED: Created PR #${PR_NUM} from stranded work"
            fi
        fi
    fi
fi

# --- Determine result ---

if [[ "$EXIT_CODE" -eq 0 ]] && [[ -n "$PR_NUM" ]]; then
    STATUS="success"
else
    STATUS="failed"
fi

# --- Write result.json ---

cat > "$RUN_DIR/result.json" << EOF
{
  "task": "$TASK_ID",
  "status": "$STATUS",
  "exit_code": $EXIT_CODE,
  "pr_number": ${PR_NUM:-null},
  "completed_at": "$(date -Iseconds)"
}
EOF

# --- Update state.json atomically ---

if [[ -f "$STATE" ]] && command -v jq &>/dev/null; then
    TEMP_STATE="${STATE}.tmp.$$"

    if [[ "$STATUS" == "success" ]]; then
        jq --arg task "$TASK_ID" --arg pr "${PR_NUM:-}" \
            '.completed += [$task] |
             .consecutive_failures = 0 |
             .current_task = null |
             (if $pr != "" then .prs[$pr] = {"task": $task, "status": "draft"} else . end)' \
            "$STATE" > "$TEMP_STATE" && mv "$TEMP_STATE" "$STATE"
    else
        jq --arg task "$TASK_ID" \
            '.failed += [$task] |
             .consecutive_failures += 1 |
             .current_task = null' \
            "$STATE" > "$TEMP_STATE" && mv "$TEMP_STATE" "$STATE"
    fi
fi

echo "POST-TASK: $TASK_ID -> $STATUS (exit $EXIT_CODE, PR ${PR_NUM:-none})"
