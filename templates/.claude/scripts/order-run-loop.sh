#!/bin/bash
# order-run-loop.sh — ORDER Lifecycle Orchestrator
#
# The real state machine dispatcher. Reads state.json, dispatches each
# skill via `claude -p` (fresh process per skill), reads state.json for
# the result, repeats. Handles the full lifecycle:
#
#   INIT -> /parse-roadmap -> /create-spec -> /review-spec -> /plan-work
#        -> /work (per task) -> MERGE_PRS -> /verify-completion -> /handoff -> next step
#
# Usage:
#   .claude/scripts/order-run-loop.sh [OPTIONS]
#
# Options:
#   --max-steps N      Max roadmap steps to process (default: 999)
#   --start-step N     Start from a specific step number
#
# Environment:
#   WORK_MODEL    Model for /work instances (default: sonnet)

# ── Paths ─────────────────────────────────────────────────────────
STATE_FILE=".chaos/framework/order/state.json"
CONFIG_FILE=".chaos/framework/order/config.yml"
QUEUE_FILE=".chaos/framework/order/queue.txt"
KILL_FILE=".chaos/framework/order/STOP"

# ── Defaults ──────────────────────────────────────────────────────
WORK_MODEL="${WORK_MODEL:-sonnet}"
MAX_STEPS=999
START_STEP=""
step_count=0
revision_count=0

# ── Argument Parsing ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-steps) MAX_STEPS="$2"; shift 2 ;;
        --start-step) START_STEP="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helper Functions ──────────────────────────────────────────────

# Read a value from state.json via jq
state() {
    jq -r "$1 // empty" "$STATE_FILE" 2>/dev/null
}

# Read a simple config value (grep for unique YAML key, return default if missing)
config() {
    local key="$1" default="$2"
    local val
    val=$(grep "${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}' | tr -d "\"'")
    echo "${val:-$default}"
}

# Dispatch a skill to a fresh Claude process
dispatch() {
    local skill="$1"
    echo "  > $skill"
    if ! claude -p "$skill" --dangerously-skip-permissions; then
        echo "  x Failed: $skill (process error)"
        return 1
    fi
}

# Safety checks before each dispatch
preflight() {
    if [ -f "$KILL_FILE" ]; then
        echo "x Kill file detected ($KILL_FILE). Halting."
        exit 1
    fi
    if [ -f ".claude/scripts/sentinel-check.sh" ]; then
        if ! bash .claude/scripts/sentinel-check.sh 2>/dev/null; then
            echo "x Sentinel check failed. Halting."
            exit 1
        fi
    fi
}

# Enrich state.json with CI failure context for the arbiter
# Usage: enrich_ci_context <pr_number> <fix_attempt> <max_fix_attempts>
enrich_ci_context() {
    local pr_num="$1" fix_attempt="$2" max_attempts="$3"
    local pr_branch

    pr_branch=$(gh pr view "$pr_num" --json headRefName -q '.headRefName' 2>/dev/null || echo "")

    # Fetch failed check details from statusCheckRollup
    local failed_checks
    failed_checks=$(gh pr view "$pr_num" --json statusCheckRollup \
        -q '[.statusCheckRollup // [] | .[] | select(.status == "COMPLETED" and .conclusion == "FAILURE")] | map({name: .name, detail: .detailsUrl})' \
        2>/dev/null || echo "[]")

    # Extract job_id and run_id from detailsUrl (format: .../runs/{run_id}/job/{job_id})
    local enriched_checks
    enriched_checks=$(echo "$failed_checks" | jq '[.[] | {
        name: .name,
        job_id: (.detail | capture("job/(?<id>[0-9]+)") | .id // empty),
        run_id: (.detail | capture("runs/(?<id>[0-9]+)") | .id // empty)
    }]' 2>/dev/null || echo "[]")

    # Warn if job ID extraction failed (arbiter will still run but may not fetch logs)
    if [ "$enriched_checks" = "[]" ] || [ -z "$enriched_checks" ]; then
        echo "    x Warning: Failed to extract job IDs from failed checks for PR $pr_num"
    fi

    jq --arg pr "$pr_num" \
       --arg branch "$pr_branch" \
       --argjson attempt "$fix_attempt" \
       --argjson max "$max_attempts" \
       --argjson checks "$enriched_checks" \
       '.arbiter_context = {
            pr_number: $pr,
            pr_branch: $branch,
            failure_type: "checks_failed",
            failed_checks: $checks,
            fix_attempt: $attempt,
            max_fix_attempts: $max
        }' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# ── Initialization ────────────────────────────────────────────────

if [ ! -f "$STATE_FILE" ]; then
    echo '{"current_state":"INIT"}' > "$STATE_FILE"
fi

if [ -n "$START_STEP" ]; then
    jq --arg step "$START_STEP" --arg time "$(date -Iseconds)" \
       '.current_state = "PARSE_ROADMAP" | .step_number = ($step | tonumber) | del(.last_result) | .last_transition = $time' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

echo "=== ORDER Lifecycle Orchestrator ==="
echo "Max steps: $MAX_STEPS"
echo ""

# ── Main State Machine Loop ──────────────────────────────────────

while true; do
    preflight

    CURRENT=$(state '.current_state')
    VERDICT=$(state '.last_result.verdict')

    echo "-- $CURRENT ${VERDICT:+(verdict: $VERDICT)} --"

    case "$CURRENT" in

        # ── INIT: Parse roadmap for next uncompleted step ──
        INIT)
            dispatch "/parse-roadmap" || exit 1

            VERDICT=$(state '.last_result.verdict')
            if [ "$VERDICT" = "ROADMAP_COMPLETE" ]; then
                echo ""
                echo "=== Roadmap Complete ==="
                echo "All steps have been processed."
                exit 0
            fi

            step_count=$((step_count + 1))
            if [ "$step_count" -gt "$MAX_STEPS" ]; then
                echo "Max steps ($MAX_STEPS) reached."
                exit 0
            fi
            revision_count=0
            echo "  Step $(state '.step_number') identified."
            ;;

        # ── PARSE_ROADMAP: Create spec for this step ──
        PARSE_ROADMAP)
            STEP=$(state '.step_number')

            # If parse-roadmap reported SPEC_EXISTS, skip to REVIEW_SPEC
            if [ "$VERDICT" = "SPEC_EXISTS" ]; then
                echo "  Step $STEP already has a spec. Advancing to REVIEW_SPEC."
                SPEC_ID=$(state '.spec_id')
                jq --arg time "$(date -Iseconds)" \
                   '.current_state = "CREATE_SPEC" | .last_transition = $time | .last_result.verdict = "SPEC_CREATED"' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                continue
            fi

            dispatch "/create-spec $STEP" || exit 1
            ;;

        # ── CREATE_SPEC: Review spec, or re-create if revision needed ──
        CREATE_SPEC)
            if [ "$VERDICT" = "NEEDS_REVISION" ]; then
                revision_count=$((revision_count + 1))
                MAX_REV=$(config "max_spec_revisions" "3")

                if [ "$revision_count" -gt "$MAX_REV" ]; then
                    echo "  x Max revisions ($MAX_REV) exceeded. Invoking arbiter..."
                    dispatch "/order-arbiter" || exit 1
                    ARB=$(state '.last_result.verdict')
                    if [ "$ARB" = "SKIP" ]; then
                        echo "  Arbiter: SKIP. Advancing to next step."
                        jq '.current_state = "INIT" | del(.last_result)' \
                            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        continue
                    fi
                    echo "  x Arbiter: HALT"; exit 1
                fi

                echo "  Revision $revision_count/$MAX_REV -- re-creating spec..."
                STEP=$(state '.step_number')
                dispatch "/create-spec $STEP" || exit 1
            else
                SPEC_ID=$(state '.spec_id')
                dispatch "/review-spec specs/$SPEC_ID/SPEC.md" || exit 1

                NEW_VERDICT=$(state '.last_result.verdict')
                if [ "$NEW_VERDICT" = "READY" ]; then
                    revision_count=0
                fi
            fi
            ;;

        # ── REVIEW_SPEC: Plan work from approved spec ──
        REVIEW_SPEC)
            SPEC_ID=$(state '.spec_id')
            dispatch "/plan-work specs/$SPEC_ID/SPEC.md" || exit 1
            ;;

        # ── PLAN_WORK: Execute next single task from queue ──
        # Sequential mode: one task at a time. Each task is worked, its PR
        # merged, and main pulled before the next task begins.
        PLAN_WORK)
            # Find the next unprocessed task in queue
            NEXT_TASK=""
            TOTAL_TASKS=0
            while IFS='|' read -r task_id rest; do
                [[ "$task_id" =~ ^[[:space:]]*# ]] && continue
                [[ -z "${task_id}" ]] && continue
                task_id=$(echo "$task_id" | xargs)
                [[ -z "$task_id" ]] && continue
                TOTAL_TASKS=$((TOTAL_TASKS + 1))

                # Skip tasks already completed or failed
                if jq -e --arg t "$task_id" '.completed // [] | index($t) != null' "$STATE_FILE" >/dev/null 2>&1; then
                    continue
                fi
                if jq -e --arg t "$task_id" '.failed // [] | index($t) != null' "$STATE_FILE" >/dev/null 2>&1; then
                    continue
                fi

                NEXT_TASK="$task_id"
                break
            done < "$QUEUE_FILE"

            COMPLETED_COUNT=$(jq '.completed // [] | length' "$STATE_FILE")
            FAILED_COUNT=$(jq '.failed // [] | length' "$STATE_FILE")

            if [ -z "$NEXT_TASK" ]; then
                # All tasks have been processed (completed or failed)
                echo "  All $TOTAL_TASKS tasks processed ($COMPLETED_COUNT ok, $FAILED_COUNT failed)."

                if [ "$FAILED_COUNT" -gt 0 ]; then
                    TASK_VERDICT="TASKS_FAILED"
                else
                    TASK_VERDICT="TASKS_COMPLETE"
                fi

                # Skip EXECUTE_TASKS — go directly to MERGE_PRS for any remaining unmerged PRs
                jq --arg state "MERGE_PRS" \
                   --arg time "$(date -Iseconds)" \
                   --arg verdict "$TASK_VERDICT" \
                   --argjson failures "$FAILED_COUNT" \
                   '.current_state = $state | .last_transition = $time | .last_result = {skill: "order-run-loop", verdict: $verdict, failures: $failures}' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            else
                echo "  [$((COMPLETED_COUNT + FAILED_COUNT + 1))/$TOTAL_TASKS] /work $NEXT_TASK"

                run_dir=".chaos/framework/runs/$NEXT_TASK"
                mkdir -p "$run_dir"

                # Pre-task: create branch from latest main
                git checkout main 2>/dev/null || true
                git pull origin main 2>/dev/null || true
                git checkout -b "task/$NEXT_TASK" 2>/dev/null || git checkout "task/$NEXT_TASK" 2>/dev/null || true

                claude -p "/work $NEXT_TASK" \
                    --dangerously-skip-permissions \
                    --model "$WORK_MODEL" \
                    > "$run_dir/output.log" 2>&1
                TASK_EXIT=$?

                # Post-task hook captures PR number and updates state
                if [ -f ".claude/scripts/post-task-hook.sh" ]; then
                    bash .claude/scripts/post-task-hook.sh "$NEXT_TASK" "$TASK_EXIT" 2>/dev/null || true
                fi

                # Post-task: return to main regardless of outcome
                git checkout main 2>/dev/null || true

                # Check result from post-task hook
                if jq -e --arg t "$NEXT_TASK" '.completed // [] | index($t) != null' "$STATE_FILE" >/dev/null 2>&1; then
                    echo "    ok: $NEXT_TASK"
                    TASK_VERDICT="TASKS_COMPLETE"
                else
                    echo "    x FAILED: $NEXT_TASK"
                    TASK_VERDICT="TASKS_FAILED"
                fi

                jq --arg state "EXECUTE_TASKS" \
                   --arg time "$(date -Iseconds)" \
                   --arg verdict "$TASK_VERDICT" \
                   --arg task "$NEXT_TASK" \
                   '.current_state = $state | .last_transition = $time | .last_result = {skill: "order-run-loop", verdict: $verdict, current_task: $task}' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            fi
            ;;

        # ── EXECUTE_TASKS: Handle task result, then transition ──
        EXECUTE_TASKS)
            if [ "$VERDICT" = "TASKS_FAILED" ]; then
                echo "  Task failed. Invoking arbiter..."
                dispatch "/order-arbiter" || exit 1
                ARB=$(state '.last_result.verdict')
                case "$ARB" in
                    RETRY)
                        echo "  Arbiter: RETRY task."
                        # Remove the task from failed list so PLAN_WORK retries it
                        FAILED_TASK=$(state '.last_result.current_task // empty')
                        if [ -n "$FAILED_TASK" ]; then
                            jq --arg t "$FAILED_TASK" --arg time "$(date -Iseconds)" \
                               '.failed = [.failed // [] | .[] | select(. != $t)] | .consecutive_failures = 0 | .current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        else
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        fi
                        continue
                        ;;
                    SKIP)
                        echo "  Arbiter: SKIP failed task. Moving to next."
                        # Task stays in failed list; PLAN_WORK will skip it
                        # Check if there are remaining tasks or if we should wrap up
                        REMAINING=$(jq '[.completed // [], .failed // []] | flatten | length' "$STATE_FILE")
                        TOTAL_Q=$(grep -cvE '^[[:space:]]*(#|$)' "$QUEUE_FILE" 2>/dev/null || echo "0")
                        if [ "$REMAINING" -ge "$TOTAL_Q" ]; then
                            echo "  No more tasks. Advancing to merge available PRs."
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "MERGE_PRS" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        else
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        fi
                        continue
                        ;;
                    *)
                        echo "  x Arbiter: HALT."
                        exit 1
                        ;;
                esac
            fi

            # Task succeeded — transition to MERGE_PRS for this single PR
            jq --arg time "$(date -Iseconds)" \
               '.current_state = "MERGE_PRS" | .last_transition = $time | del(.last_result)' \
               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            ;;

        # ── MERGE_PRS: Mark drafts ready, wait for GHA checks, address feedback, merge ──
        MERGE_PRS)
            # Read config values
            GHA_TIMEOUT=$(config "gha_wait_timeout_minutes" "30")
            MERGE_METHOD=$(config "merge_method" "squash")
            DELETE_BRANCH=$(config "delete_branch" "true")
            MAX_FEEDBACK_ROUNDS=5
            POLL_INTERVAL=120  # 2 minutes

            # Ensure TODO directory exists for review artifacts
            mkdir -p .chaos/todos

            # Collect PR numbers from state.json (exclude already-merged PRs)
            PR_NUMBERS=$(jq -r '.prs // {} | to_entries[] | select(.value.status != "merged") | .key' "$STATE_FILE" 2>/dev/null)

            if [ -z "$PR_NUMBERS" ]; then
                # Count queue tasks to detect PR registration failures
                QUEUE_TASK_COUNT=$(grep -cvE '^[[:space:]]*(#|$)' "$QUEUE_FILE" 2>/dev/null || echo "0")

                if [ "$QUEUE_TASK_COUNT" -gt 0 ]; then
                    echo "  x WARNING: $QUEUE_TASK_COUNT tasks in queue but no PRs in state."
                    echo "  Attempting PR discovery from queue..."

                    DISCOVERED=0
                    while IFS='|' read -r disc_task_id disc_rest; do
                        [[ "$disc_task_id" =~ ^[[:space:]]*# ]] && continue
                        [[ -z "${disc_task_id}" ]] && continue
                        disc_task_id=$(echo "$disc_task_id" | xargs)
                        [[ -z "$disc_task_id" ]] && continue

                        disc_bd_id=$(echo "$disc_rest" | sed -n 's/.*bd:\([^|]*\).*/\1/p')
                        disc_pr=""

                        # Try beads-prefixed branch first
                        if [[ -n "$disc_bd_id" ]]; then
                            disc_pr=$(gh pr list --state open --head "task/${disc_bd_id}-${disc_task_id}" \
                                --json number -q '.[0].number' 2>/dev/null || echo "")
                        fi

                        # Fallback: exact branch match
                        if [[ -z "$disc_pr" ]]; then
                            disc_pr=$(gh pr list --state open --head "task/${disc_task_id}" \
                                --json number -q '.[0].number' 2>/dev/null || echo "")
                        fi

                        # Fallback: suffix match
                        if [[ -z "$disc_pr" ]]; then
                            disc_pr=$(gh pr list --state open --json number,headRefName \
                                --jq "[.[] | select(.headRefName | endswith(\"-${disc_task_id}\"))] | .[0].number // empty" \
                                2>/dev/null || echo "")
                        fi

                        if [[ -n "$disc_pr" ]]; then
                            echo "    Discovered PR #$disc_pr for task $disc_task_id"
                            jq --arg pr "$disc_pr" --arg task "$disc_task_id" \
                                '.prs[$pr] = {"task": $task, "status": "draft"}' \
                                "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                            DISCOVERED=$((DISCOVERED + 1))
                        fi
                    done < "$QUEUE_FILE"

                    # Re-read after discovery
                    PR_NUMBERS=$(jq -r '.prs // {} | to_entries[] | select(.value.status != "merged") | .key' "$STATE_FILE" 2>/dev/null)

                    if [ -z "$PR_NUMBERS" ]; then
                        echo "  x ERROR: Could not discover any PRs for $QUEUE_TASK_COUNT queued tasks."
                        echo "  x Tasks may have failed to push branches. Halting."
                        exit 1
                    fi
                    echo "  Discovered $DISCOVERED PRs. Proceeding to merge."
                else
                    echo "  No PRs to merge. Advancing to VERIFY_COMPLETION."
                    jq --arg time "$(date -Iseconds)" \
                       '.current_state = "VERIFY_COMPLETION" | .last_transition = $time' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                    continue
                fi
            fi

            MERGE_FAILED=0
            MERGE_SUCCEEDED=0
            MERGE_BLOCKERS=()

            for PR_NUM in $PR_NUMBERS; do
                preflight

                PR_STATUS=$(jq -r ".prs[\"$PR_NUM\"].status // \"draft\"" "$STATE_FILE")

                # Skip already-merged PRs (idempotent for retries)
                if [ "$PR_STATUS" = "merged" ]; then
                    echo "  PR #$PR_NUM: already merged, skipping."
                    MERGE_SUCCEEDED=$((MERGE_SUCCEEDED + 1))
                    continue
                fi

                echo "  PR #$PR_NUM: processing..."
                # Fix attempt counter (not persisted — resets if loop crashes and restarts)
                FIX_ATTEMPT=0
                MAX_FIX_ATTEMPTS=3

                # ── Phase 0: Rebase PR branch onto current main ──
                PR_DATA=$(gh pr view "$PR_NUM" --json headRefName,state 2>/dev/null || echo '{}')
                PR_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName // empty')
                PR_STATE=$(echo "$PR_DATA" | jq -r '.state // empty')

                if [ -n "$PR_BRANCH" ] && [ "$PR_STATE" = "OPEN" ]; then
                    echo "    Rebasing $PR_BRANCH onto main..."

                    # Try GitHub-side branch update first (merge commit vanishes on squash merge)
                    if gh pr update-branch "$PR_NUM" 2>/dev/null; then
                        echo "    Branch updated via GitHub API."
                        sleep 5
                    else
                        # Fallback: local rebase + force-push
                        echo "    GitHub API update failed, trying local rebase..."
                        git fetch origin main 2>/dev/null || true
                        git checkout "$PR_BRANCH" 2>/dev/null || {
                            echo "    x Failed to checkout $PR_BRANCH"
                            git checkout main 2>/dev/null || true
                            MERGE_FAILED=$((MERGE_FAILED + 1))
                            MERGE_BLOCKERS+=("PR #$PR_NUM: branch checkout failed")
                            continue
                        }
                        git pull origin "$PR_BRANCH" 2>/dev/null || true

                        if git rebase origin/main 2>/dev/null; then
                            echo "    Rebase succeeded. Force-pushing..."
                            if git push --force-with-lease origin "$PR_BRANCH" 2>/dev/null; then
                                echo "    Force-push succeeded."
                            else
                                echo "    x Force-push failed for PR #$PR_NUM."
                                git rebase --abort 2>/dev/null || true
                                git checkout main 2>/dev/null || true
                                MERGE_FAILED=$((MERGE_FAILED + 1))
                                MERGE_BLOCKERS+=("PR #$PR_NUM: force-push failed after rebase")
                                jq --arg pr "$PR_NUM" \
                                   '.prs[$pr].status = "rebase_failed"' \
                                   "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                                continue
                            fi
                        else
                            echo "    Rebase conflict for PR #$PR_NUM. Attempting resolution..."

                            # Capture conflict files while rebase is in progress
                            CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null \
                                | jq -R . | jq -s .)

                            # Write conflict context to state.json for the skill
                            jq --arg pr "$PR_NUM" \
                               --arg branch "$PR_BRANCH" \
                               --argjson files "${CONFLICT_FILES:-[]}" \
                               '.conflict_context = {pr_number: $pr, branch: $branch, conflict_files: $files}' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

                            # Dispatch — rebase-in-progress state persists on disk
                            if dispatch "/resolve-conflicts"; then
                                RESOLVE_VERDICT=$(state '.last_result.verdict')
                                if [ "$RESOLVE_VERDICT" = "RESOLVED" ]; then
                                    echo "    Conflicts resolved for PR #$PR_NUM."
                                    git checkout main 2>/dev/null || true
                                    # Continue to Phase 1 (mark ready, poll, merge)
                                else
                                    echo "    x Resolution returned: $RESOLVE_VERDICT"
                                    git rebase --abort 2>/dev/null || true
                                    git checkout main 2>/dev/null || true
                                    MERGE_FAILED=$((MERGE_FAILED + 1))
                                    MERGE_BLOCKERS+=("PR #$PR_NUM: conflict unresolvable")
                                    jq --arg pr "$PR_NUM" \
                                       '.prs[$pr].status = "rebase_conflict"' \
                                       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                                    continue
                                fi
                            else
                                echo "    x /resolve-conflicts crashed for PR #$PR_NUM."
                                git rebase --abort 2>/dev/null || true
                                git checkout main 2>/dev/null || true
                                MERGE_FAILED=$((MERGE_FAILED + 1))
                                MERGE_BLOCKERS+=("PR #$PR_NUM: resolve-conflicts crashed")
                                jq --arg pr "$PR_NUM" \
                                   '.prs[$pr].status = "rebase_conflict"' \
                                   "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                                continue
                            fi
                        fi

                        # Return to main after local rebase
                        git checkout main 2>/dev/null || true
                    fi

                    # Brief pause for GHA to trigger on synchronize event from rebase
                    sleep 10
                fi

                # ── Phase 1: Mark draft as ready for review ──
                IS_DRAFT=$(gh pr view "$PR_NUM" --json isDraft -q '.isDraft' 2>/dev/null || echo "true")
                if [ "$IS_DRAFT" = "true" ]; then
                    echo "    Marking ready for review..."
                    if ! gh pr ready "$PR_NUM" 2>/dev/null; then
                        echo "    x Failed to mark PR #$PR_NUM ready."
                        MERGE_FAILED=$((MERGE_FAILED + 1))
                        MERGE_BLOCKERS+=("PR #$PR_NUM: failed to mark ready for review")
                        jq --arg pr "$PR_NUM" \
                           '.prs[$pr].status = "ready_failed"' \
                           "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        continue
                    fi
                    jq --arg pr "$PR_NUM" \
                       '.prs[$pr].status = "ready"' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                    echo "    PR #$PR_NUM marked ready."
                    # Brief pause for GHA to trigger on ready_for_review event
                    sleep 10
                fi

                FEEDBACK_ROUND=0
                PR_MERGEABLE=false

                while [ "$FEEDBACK_ROUND" -le "$MAX_FEEDBACK_ROUNDS" ]; do

                    # ── Phase 2: Poll GHA checks until completion ──
                    DEADLINE=$(($(date +%s) + GHA_TIMEOUT * 60))
                    CHECKS_RESOLVED=false
                    CHECKS_PASSED=false

                    echo "    Polling checks (timeout: ${GHA_TIMEOUT}m, round: $FEEDBACK_ROUND)..."

                    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
                        preflight

                        CHECK_DATA=$(gh pr view "$PR_NUM" --json statusCheckRollup,reviews 2>/dev/null || echo '{}')

                        TOTAL_CHECKS=$(echo "$CHECK_DATA" | jq '[.statusCheckRollup // [] | .[]] | length')
                        COMPLETED_CHECKS=$(echo "$CHECK_DATA" | jq '[.statusCheckRollup // [] | .[] | select(.status == "COMPLETED")] | length')
                        FAILED_CHECKS=$(echo "$CHECK_DATA" | jq '[.statusCheckRollup // [] | .[] | select(.status == "COMPLETED" and .conclusion == "FAILURE")] | length')
                        CHANGES_REQUESTED=$(echo "$CHECK_DATA" | jq '[.reviews // [] | .[] | select(.state == "CHANGES_REQUESTED")] | length')

                        echo "      Checks: $COMPLETED_CHECKS/$TOTAL_CHECKS resolved, $FAILED_CHECKS failed | Changes requested: $CHANGES_REQUESTED"

                        # Early exit: check failure
                        if [ "$FAILED_CHECKS" -gt 0 ]; then
                            echo "    x PR #$PR_NUM: check(s) FAILED."
                            CHECKS_RESOLVED=true
                            break
                        fi

                        # Early exit: changes requested
                        if [ "$CHANGES_REQUESTED" -gt 0 ]; then
                            echo "    x PR #$PR_NUM: CHANGES_REQUESTED by reviewer."
                            CHECKS_RESOLVED=true
                            break
                        fi

                        # Success: all checks resolved (COMPLETED status, any conclusion except FAILURE)
                        if [ "$TOTAL_CHECKS" -gt 0 ] && [ "$COMPLETED_CHECKS" -eq "$TOTAL_CHECKS" ]; then
                            echo "    PR #$PR_NUM: all checks passed."
                            CHECKS_RESOLVED=true
                            CHECKS_PASSED=true
                            break
                        fi

                        sleep "$POLL_INTERVAL"
                    done

                    # Timeout handling
                    if [ "$CHECKS_RESOLVED" = false ]; then
                        echo "    x PR #$PR_NUM: timed out waiting for checks (${GHA_TIMEOUT}m)."
                        MERGE_FAILED=$((MERGE_FAILED + 1))
                        MERGE_BLOCKERS+=("PR #$PR_NUM: timed out waiting for checks after ${GHA_TIMEOUT}m")
                        jq --arg pr "$PR_NUM" \
                           '.prs[$pr].status = "timeout"' \
                           "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        break
                    fi

                    # Check failure or changes requested
                    if [ "$CHECKS_PASSED" = false ]; then
                        if [ "$FAILED_CHECKS" -gt 0 ] && [ "$FIX_ATTEMPT" -lt "$MAX_FIX_ATTEMPTS" ]; then
                            # ── Arbiter fix cycle ──
                            FIX_ATTEMPT=$((FIX_ATTEMPT + 1))
                            echo "    Arbiter fix attempt $FIX_ATTEMPT/$MAX_FIX_ATTEMPTS..."

                            enrich_ci_context "$PR_NUM" "$FIX_ATTEMPT" "$MAX_FIX_ATTEMPTS"

                            # Checkout PR branch for arbiter to work on
                            PR_FIX_BRANCH=$(gh pr view "$PR_NUM" --json headRefName -q '.headRefName' 2>/dev/null)
                            git checkout "$PR_FIX_BRANCH" 2>/dev/null || true
                            git pull origin "$PR_FIX_BRANCH" 2>/dev/null || true
                            PRE_ARBITER_HEAD=$(git rev-parse HEAD 2>/dev/null)

                            if [ -z "$PRE_ARBITER_HEAD" ]; then
                                echo "    x Failed to capture PRE_ARBITER_HEAD"
                                git checkout main 2>/dev/null || true
                                MERGE_BLOCKERS+=("PR #$PR_NUM: failed to capture safety anchor")
                                MERGE_FAILED=$((MERGE_FAILED + 1))
                                break
                            fi

                            if dispatch "/order-arbiter"; then
                                ARB_VERDICT=$(state '.last_result.verdict')

                                case "$ARB_VERDICT" in
                                    FIXED)
                                        echo "    Arbiter: FIXED. Dispatching review..."
                                        if dispatch "/arbiter-review"; then
                                            REVIEW_VERDICT=$(state '.last_result.review')
                                            if [ "$REVIEW_VERDICT" = "APPROVED" ]; then
                                                echo "    Review: APPROVED. Pushing fix..."
                                                if git push origin "$PR_FIX_BRANCH" 2>/dev/null; then
                                                    echo "    Fix pushed. Re-polling checks..."
                                                    git checkout main 2>/dev/null || true
                                                    # Wait for GHA to trigger on push event
                                                    sleep 15
                                                    continue  # re-enter check polling loop
                                                else
                                                    echo "    x Push failed. Reverting..."
                                                    git reset --hard "$PRE_ARBITER_HEAD" 2>/dev/null || true
                                                    git checkout main 2>/dev/null || true
                                                    MERGE_BLOCKERS+=("PR #$PR_NUM: arbiter fix push failed")
                                                    MERGE_FAILED=$((MERGE_FAILED + 1))
                                                    break
                                                fi
                                            else
                                                REVIEW_REASON=$(state '.last_result.review_reason // "no reason"')
                                                echo "    Review: REJECTED — $REVIEW_REASON"
                                                git reset --hard "$PRE_ARBITER_HEAD" 2>/dev/null || true
                                                git checkout main 2>/dev/null || true
                                                MERGE_BLOCKERS+=("PR #$PR_NUM: arbiter fix rejected by review — $REVIEW_REASON")
                                                MERGE_FAILED=$((MERGE_FAILED + 1))
                                                break
                                            fi
                                        else
                                            echo "    x /arbiter-review crashed. Reverting..."
                                            git reset --hard "$PRE_ARBITER_HEAD" 2>/dev/null || true
                                            git checkout main 2>/dev/null || true
                                            MERGE_BLOCKERS+=("PR #$PR_NUM: arbiter-review crashed")
                                            MERGE_FAILED=$((MERGE_FAILED + 1))
                                            break
                                        fi
                                        ;;
                                    *)
                                        echo "    Arbiter: $ARB_VERDICT. Reverting..."
                                        git reset --hard "$PRE_ARBITER_HEAD" 2>/dev/null || true
                                        git checkout main 2>/dev/null || true
                                        MERGE_BLOCKERS+=("PR #$PR_NUM: arbiter verdict $ARB_VERDICT")
                                        MERGE_FAILED=$((MERGE_FAILED + 1))
                                        break
                                        ;;
                                esac
                            else
                                echo "    x /order-arbiter crashed. Reverting..."
                                git reset --hard "$PRE_ARBITER_HEAD" 2>/dev/null || true
                                git checkout main 2>/dev/null || true
                                MERGE_BLOCKERS+=("PR #$PR_NUM: arbiter crashed")
                                MERGE_FAILED=$((MERGE_FAILED + 1))
                                break
                            fi

                        elif [ "$FAILED_CHECKS" -gt 0 ]; then
                            # Max fix attempts exhausted — fall through to manual intervention
                            echo "    x Max fix attempts ($MAX_FIX_ATTEMPTS) exhausted for PR #$PR_NUM."
                            MERGE_BLOCKERS+=("PR #$PR_NUM: GHA check(s) failed after $MAX_FIX_ATTEMPTS fix attempts")
                            jq --arg pr "$PR_NUM" \
                               '.prs[$pr].status = "checks_failed"' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                            MERGE_FAILED=$((MERGE_FAILED + 1))
                            break
                        else
                            MERGE_BLOCKERS+=("PR #$PR_NUM: review requested changes")
                            jq --arg pr "$PR_NUM" \
                               '.prs[$pr].status = "changes_requested"' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                            MERGE_FAILED=$((MERGE_FAILED + 1))
                            break
                        fi
                    fi

                    # ── Phase 3: Address review feedback ──
                    if [ "$FEEDBACK_ROUND" -lt "$MAX_FEEDBACK_ROUNDS" ]; then
                        FEEDBACK_ROUND=$((FEEDBACK_ROUND + 1))
                        echo "    Dispatching /review-feedback (round $FEEDBACK_ROUND/$MAX_FEEDBACK_ROUNDS)..."

                        # Checkout PR branch so the skill can detect the PR
                        PR_BRANCH=$(gh pr view "$PR_NUM" --json headRefName -q '.headRefName' 2>/dev/null)
                        if [ -n "$PR_BRANCH" ]; then
                            git checkout "$PR_BRANCH" 2>/dev/null || true
                            git pull origin "$PR_BRANCH" 2>/dev/null || true
                        fi

                        jq --arg pr "$PR_NUM" --arg round "feedback_round_$FEEDBACK_ROUND" \
                           '.prs[$pr].status = $round' \
                           "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

                        # Capture HEAD before dispatch to detect if feedback pushed changes
                        OLD_HEAD=$(git rev-parse HEAD 2>/dev/null)

                        dispatch "/review-feedback" || true

                        # Pull latest to see if feedback pushed commits to remote
                        git pull origin "$PR_BRANCH" 2>/dev/null || true

                        # Check if /review-feedback pushed any new commits
                        NEW_HEAD=$(git rev-parse HEAD 2>/dev/null)

                        # Return to main
                        git checkout main 2>/dev/null || true

                        # If no new commits were pushed, feedback was a no-op — proceed to merge
                        if [ "$NEW_HEAD" = "$OLD_HEAD" ] || [ -z "$PR_BRANCH" ]; then
                            echo "    No changes from feedback. Proceeding to merge."
                            PR_MERGEABLE=true
                            break
                        fi

                        echo "    Feedback pushed changes. Re-polling checks..."
                        # Brief pause for GHA to trigger on synchronize event
                        sleep 10
                        # Loop back to Phase 2
                        continue
                    else
                        echo "    Max feedback rounds ($MAX_FEEDBACK_ROUNDS) reached. Proceeding to merge."
                        PR_MERGEABLE=true
                        break
                    fi

                done  # feedback round loop

                # Log if TODO file was generated by review-feedback
                if [ -f ".chaos/todos/TODO-${PR_NUM}.md" ]; then
                    echo "    Non-blocking review items saved to .chaos/todos/TODO-${PR_NUM}.md"
                fi

                # ── Phase 4: Merge the PR ──
                if [ "$PR_MERGEABLE" = true ] || [ "$CHECKS_PASSED" = true ]; then
                    jq --arg pr "$PR_NUM" \
                       '.prs[$pr].status = "checks_passed"' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

                    echo "    Merging PR #$PR_NUM (method: $MERGE_METHOD)..."

                    MERGE_FLAGS="--$MERGE_METHOD"
                    if [ "$DELETE_BRANCH" = "true" ]; then
                        MERGE_FLAGS="$MERGE_FLAGS --delete-branch"
                    fi

                    if gh pr merge "$PR_NUM" $MERGE_FLAGS 2>/dev/null; then
                        echo "    PR #$PR_NUM merged."
                        MERGE_SUCCEEDED=$((MERGE_SUCCEEDED + 1))
                        jq --arg pr "$PR_NUM" \
                           '.prs[$pr].status = "merged"' \
                           "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

                        # Keep local main current for subsequent PRs
                        git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true
                    else
                        # gh pr merge can return non-zero even when the PR was merged.
                        # Verify the actual PR state before declaring failure.
                        sleep 3
                        ACTUAL_STATE=$(gh pr view "$PR_NUM" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
                        if [ "$ACTUAL_STATE" = "MERGED" ]; then
                            echo "    PR #$PR_NUM: merge command returned error but PR is MERGED. Continuing."
                            MERGE_SUCCEEDED=$((MERGE_SUCCEEDED + 1))
                            jq --arg pr "$PR_NUM" \
                               '.prs[$pr].status = "merged"' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                            git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true
                        else
                            echo "    x PR #$PR_NUM: merge command failed (state: $ACTUAL_STATE)."
                            MERGE_FAILED=$((MERGE_FAILED + 1))
                            MERGE_BLOCKERS+=("PR #$PR_NUM: gh pr merge command failed")
                            jq --arg pr "$PR_NUM" \
                               '.prs[$pr].status = "merge_failed"' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        fi
                    fi
                fi

            done  # PR loop

            # Cleanup stale arbiter_context — runs on all exit paths (success, failure, timeout)
            if jq -e '.arbiter_context' "$STATE_FILE" >/dev/null 2>&1; then
                jq 'del(.arbiter_context)' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            fi

            echo "  Merge results: $MERGE_SUCCEEDED merged, $MERGE_FAILED failed"

            # ── Decide next state ──
            # Count remaining tasks not yet completed or failed
            PROCESSED=$(jq '[.completed // [], .failed // []] | flatten | length' "$STATE_FILE")
            TOTAL_Q=$(grep -cvE '^[[:space:]]*(#|$)' "$QUEUE_FILE" 2>/dev/null || echo "0")
            REMAINING=$((TOTAL_Q - PROCESSED))

            if [ "$MERGE_FAILED" -eq 0 ]; then
                # PR merged successfully
                echo "  Pulling latest main after merge..."
                git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true

                if [ "$REMAINING" -gt 0 ]; then
                    echo "  $REMAINING task(s) remaining. Continuing to next task."
                    jq --arg time "$(date -Iseconds)" \
                       '.current_state = "PLAN_WORK" | .last_transition = $time | .last_result = {skill: "merge-prs", verdict: "MERGED_CONTINUING"}' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                else
                    echo "  All tasks complete. Advancing to verification."
                    jq --arg time "$(date -Iseconds)" \
                       '.current_state = "VERIFY_COMPLETION" | .last_transition = $time | .last_result = {skill: "merge-prs", verdict: "ALL_MERGED"}' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                fi
            else
                # Merge failed -> invoke arbiter
                echo "  Merge failure detected. Invoking arbiter..."

                BLOCKERS_JSON=$(printf '%s\n' "${MERGE_BLOCKERS[@]}" | jq -R . | jq -s .)
                jq --arg time "$(date -Iseconds)" \
                   --argjson blockers "$BLOCKERS_JSON" \
                   --argjson failures "$MERGE_FAILED" \
                   '.last_result = {skill: "merge-prs", verdict: "MERGE_BLOCKED", blockers: $blockers, failures: $failures} | .last_transition = $time' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

                dispatch "/order-arbiter" || exit 1
                ARB=$(state '.last_result.verdict')
                case "$ARB" in
                    RETRY)
                        echo "  Arbiter: RETRY merge."
                        jq --arg time "$(date -Iseconds)" \
                           '.current_state = "MERGE_PRS" | .last_transition = $time | del(.last_result)' \
                           "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        ;;
                    SKIP)
                        echo "  Arbiter: SKIP merge failure."
                        git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true
                        if [ "$REMAINING" -gt 0 ]; then
                            echo "  $REMAINING task(s) remaining. Continuing to next task."
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        else
                            echo "  No more tasks. Advancing to verification."
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "VERIFY_COMPLETION" | .last_transition = $time' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        fi
                        ;;
                    *)
                        echo "  x Arbiter: HALT."
                        exit 1
                        ;;
                esac
            fi
            ;;

        # ── VERIFY_COMPLETION: Create handoff document ──
        VERIFY_COMPLETION)
            STEP=$(state '.step_number')
            dispatch "/handoff $STEP" || exit 1
            ;;

        # ── HANDOFF: Step complete, reset for next step ──
        HANDOFF)
            STEP=$(state '.step_number')
            echo ""
            echo "=== Step $STEP Complete ==="
            echo ""

            # Reset state to INIT for next roadmap step
            jq '.current_state = "INIT" | del(.last_result)' \
                "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            revision_count=0
            ;;

        *)
            echo "x Unknown state: $CURRENT"
            exit 1
            ;;
    esac
done

echo ""
echo "=== ORDER Loop Complete ==="
echo "Steps run: $step_count"
