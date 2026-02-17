#!/bin/bash
# order-run-loop.sh — ORDER Lifecycle Orchestrator v3.0
#
# The state machine dispatcher. Reads state.json, dispatches each
# skill via `claude -p` (fresh process per skill), reads state.json for
# the result, repeats. Handles the full lifecycle:
#
#   INIT -> PARSE_ROADMAP -> CREATE_SPEC -> REVIEW_SPEC -> PLAN_WORK
#        -> EXECUTE_TASKS -> MERGE_PRS -> VERIFY_COMPLETION -> HANDOFF -> next step
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

set -o pipefail

# ── Paths ─────────────────────────────────────────────────────────
STATE_FILE=".chaos/framework/order/state.json"
CONFIG_FILE=".chaos/framework/order/config.yml"
QUEUE_FILE=".chaos/framework/order/queue.txt"
KILL_FILE=".chaos/framework/order/STOP"
HISTORY_ARCHIVE=".chaos/framework/order/history.jsonl"
LOG_DIR=".chaos/framework/order/logs"
HISTORY_KEEP=20

# ── Defaults ──────────────────────────────────────────────────────
WORK_MODEL="${WORK_MODEL:-sonnet}"
MAX_STEPS=999
START_STEP=""
step_count=0
revision_count=0
LOG_FILE=""
CURRENT=""
CURRENT_STEP="?"

# Shared merge state (used by MERGE_PRS sub-functions)
MERGE_BLOCKERS=()

# ── Argument Parsing ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --max-steps) MAX_STEPS="$2"; shift 2 ;;
        --start-step) START_STEP="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ══════════════════════════════════════════════════════════════════
# LOGGING
# ══════════════════════════════════════════════════════════════════

init_logging() {
    mkdir -p "$LOG_DIR"
    local timestamp
    timestamp=$(date +%Y%m%dT%H%M%S)
    LOG_FILE="$LOG_DIR/order-run-${timestamp}.log"
    ln -sf "$(basename "$LOG_FILE")" "$LOG_DIR/latest.log" 2>/dev/null || true
}

# Start a new log file for a specific step.
# The previous log file (init or prior step) is left intact.
start_step_log() {
    local step="$1" title="${2:-}"
    local sanitized
    sanitized=$(printf '%s' "$title" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | head -c 40)
    local timestamp
    timestamp=$(date +%Y%m%dT%H%M%S)
    local new_log="$LOG_DIR/step-${step}${sanitized:+-$sanitized}-${timestamp}.log"

    LOG_FILE="$new_log"
    ln -sf "$(basename "$LOG_FILE")" "$LOG_DIR/latest.log" 2>/dev/null || true
    log INFO "=== Step $step${title:+: $title} ==="
    log INFO "Log file: $LOG_FILE"
}

# log LEVEL "message"
# Levels: INFO, WARN, ERROR, DEBUG
log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date -Iseconds)
    local line="[$timestamp] [$level] [step:${CURRENT_STEP}/${CURRENT:-?}] $*"

    echo "$line"
    [ -n "$LOG_FILE" ] && echo "$line" >> "$LOG_FILE"
}

log_separator() {
    local msg="${1:-}"
    log INFO "────────────────────────────────────────${msg:+ $msg ────}"
}

# Log full state summary
log_state_summary() {
    local summary
    summary=$(jq -c '{
        state: .current_state,
        step: .step_number,
        verdict: .last_result.verdict,
        completed: (.completed // [] | length),
        failed: (.failed // [] | length),
        open_prs: [.prs // {} | to_entries[] | select(.value.status == "merged" | not) | .key]
    }' "$STATE_FILE" 2>/dev/null || echo '{}')
    log INFO "State: $summary"
}

# ══════════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════════

# Safely replace state.json from the .tmp file after validating JSON.
# Keeps a .bak copy so interrupted writes can be recovered on next startup.
# Returns 1 if the tmp file contains invalid JSON.
safe_mv_state() {
    if jq empty "${STATE_FILE}.tmp" 2>/dev/null; then
        cp "$STATE_FILE" "${STATE_FILE}.bak.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.bak.tmp" "${STATE_FILE}.bak" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    else
        log ERROR "Refusing to update state: invalid JSON in ${STATE_FILE}.tmp"
        rm -f "${STATE_FILE}.tmp"
        return 1
    fi
}

# Read a value from state.json via jq
state() {
    jq -r "$1 // empty" "$STATE_FILE" 2>/dev/null
}

# Read a config value from YAML. Matches the FIRST occurrence of the
# key at any nesting level. Returns default if key is missing.
config() {
    local key="$1" default="$2"
    local val
    # Match "key:" at any indent, extract the value after the colon
    val=$(grep -E "^[[:space:]]*${key}:" "$CONFIG_FILE" 2>/dev/null \
        | head -1 \
        | sed 's/^[^:]*:[[:space:]]*//' \
        | sed 's/[[:space:]]*#.*//' \
        | tr -d "\"'" \
        | xargs)
    echo "${val:-$default}"
}

# ══════════════════════════════════════════════════════════════════
# STATE HELPERS
# ══════════════════════════════════════════════════════════════════

# Transition to a new state with optional note
transition() {
    local new_state="$1" note="${2:-}"
    local old_state
    old_state=$(state '.current_state')

    local jq_filter='.current_state = $state | .last_transition = $time'
    jq_filter="$jq_filter | .transition_history = (.transition_history + [{from: \$from, to: \$state, at: \$time"
    if [ -n "$note" ]; then
        jq_filter="$jq_filter, note: \$note"
    fi
    jq_filter="$jq_filter}])"

    jq --arg state "$new_state" \
       --arg time "$(date -Iseconds)" \
       --arg from "$old_state" \
       --arg note "$note" \
       "$jq_filter" \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state

    log INFO "Transition: $old_state -> $new_state${note:+ ($note)}"
    CURRENT="$new_state"
}

# Update a PR's status in state.json
update_pr_status() {
    local pr_num="$1" status="$2"
    jq --arg pr "$pr_num" --arg s "$status" \
       '.prs[$pr].status = $s' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
    log DEBUG "PR #$pr_num status -> $status"
}

# Add a merge blocker message
add_blocker() {
    MERGE_BLOCKERS+=("$1")
    log ERROR "Blocker: $1"
}

# Count non-comment, non-blank lines in queue file
count_queue_tasks() {
    local count
    count=$(grep -cvE '^[[:space:]]*(#|$)' "$QUEUE_FILE" 2>/dev/null) || true
    printf '%d' "${count:-0}"
}

# Print state summary for console output
state_summary() {
    jq '{
        current_state,
        step_number,
        last_transition,
        last_result,
        spec_id,
        consecutive_failures,
        completed_count: (.completed // [] | length),
        failed_count: (.failed // [] | length),
        open_prs: [.prs // {} | to_entries[] | select(.value.status == "merged" | not) | .key],
        history_len: (.transition_history | length)
    }' "$STATE_FILE"
}

# Clean up dirty state left by a previous crash.
# Called once during initialization, before the main loop.
recover_dirty_state() {
    log INFO "Running dirty state recovery..."

    # Abort stale rebase
    if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
        log WARN "Stale rebase detected. Aborting."
        git rebase --abort 2>/dev/null || true
    fi

    # Abort stale merge
    if [ -f ".git/MERGE_HEAD" ]; then
        log WARN "Stale merge detected. Aborting."
        git merge --abort 2>/dev/null || true
    fi

    # Abort stale cherry-pick
    if [ -f ".git/CHERRY_PICK_HEAD" ]; then
        log WARN "Stale cherry-pick detected. Aborting."
        git cherry-pick --abort 2>/dev/null || true
    fi

    # Ensure on main branch
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    if [ "$current_branch" != "main" ]; then
        log WARN "Not on main branch (on: '${current_branch:-DETACHED}'). Switching to main."
        git checkout main 2>/dev/null || {
            log ERROR "Cannot checkout main. Forcing."
            git checkout -f main 2>/dev/null || true
        }
    fi

    # Pull latest main
    git pull origin main 2>/dev/null || true

    # Remove stale .tmp files
    rm -f "${STATE_FILE}.tmp" "${STATE_FILE}.bak.tmp"
    rm -f .chaos/framework/order/*.tmp 2>/dev/null || true
    rm -f "$LOG_DIR"/dispatch-*.tmp 2>/dev/null || true

    # Validate queue file if state expects one
    local current_state
    current_state=$(state '.current_state')
    case "$current_state" in
        PLAN_WORK|EXECUTE_TASKS|MERGE_PRS)
            if [ ! -f "$QUEUE_FILE" ]; then
                log WARN "State is $current_state but queue file missing. Resetting to INIT."
                jq --arg time "$(date -Iseconds)" \
                   '.current_state = "INIT" | .last_transition = $time | del(.last_result)' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
            fi
            ;;
    esac

    # Validate spec file if state references one
    local spec_id
    spec_id=$(state '.spec_id // empty')
    if [ -n "$spec_id" ]; then
        case "$current_state" in
            CREATE_SPEC|REVIEW_SPEC)
                if [ ! -f "specs/$spec_id/SPEC.md" ]; then
                    log WARN "State references spec $spec_id but file missing. Resetting to PARSE_ROADMAP."
                    jq --arg time "$(date -Iseconds)" \
                       '.current_state = "PARSE_ROADMAP" | .last_transition = $time | del(.last_result) | del(.spec_id)' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                fi
                ;;
        esac
    fi

    log INFO "Dirty state recovery complete."
}

# ══════════════════════════════════════════════════════════════════
# DISPATCH
# ══════════════════════════════════════════════════════════════════

# Read dispatch_timeout_seconds from config with numeric validation
get_dispatch_timeout() {
    local t
    t=$(config "dispatch_timeout_seconds" "1800")
    if ! [[ "$t" =~ ^[0-9]+$ ]]; then
        log WARN "Invalid dispatch_timeout_seconds '$t', using default 1800s"
        t=1800
    fi
    echo "$t"
}

# Dispatch a skill to a fresh Claude process with timeout
dispatch() {
    local skill="$1"
    local model="${2:-}"
    local skill_timeout
    skill_timeout=$(get_dispatch_timeout)

    log INFO "Dispatching: $skill${model:+ (model: $model)}"
    local start_time=$SECONDS

    local model_args=()
    [ -n "$model" ] && model_args=(--model "$model")

    local dispatch_log="${LOG_DIR}/dispatch-$$.tmp"

    timeout "$skill_timeout" claude -p "$skill" --dangerously-skip-permissions "${model_args[@]}" \
        > "$dispatch_log" 2>&1
    local exit_code=$?

    # Append dispatch output to main log
    if [ -n "$LOG_FILE" ] && [ -f "$dispatch_log" ]; then
        {
            echo ""
            echo "=== Dispatch: $skill ==="
            cat "$dispatch_log"
            echo "=== End Dispatch ==="
            echo ""
        } >> "$LOG_FILE"
    fi
    rm -f "$dispatch_log"

    local elapsed=$((SECONDS - start_time))

    if [ "$exit_code" -eq 124 ]; then
        log ERROR "Dispatch TIMED OUT after ${skill_timeout}s: $skill"
        return 1
    elif [ "$exit_code" -ne 0 ]; then
        log ERROR "Dispatch FAILED (exit $exit_code, ${elapsed}s): $skill"
        return 1
    fi

    log INFO "Dispatch OK (${elapsed}s): $skill"
    return 0
}

# Crash-resilient arbiter invocation.
# Dispatches /order-arbiter with retry on crash or empty verdict.
# Sets ARBITER_VERDICT to the verdict string (or "HALT" on total failure).
# Returns 0 on success (verdict is valid), 1 on total failure.
invoke_arbiter() {
    ARBITER_VERDICT=""
    local max_retries arbiter_delay
    max_retries=$(config "max_arbiter_retries" "2")
    arbiter_delay=$(config "arbiter_retry_delay_seconds" "15")

    local attempt=0
    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))
        log INFO "Invoking arbiter (attempt $attempt/$max_retries)"

        if dispatch "/order-arbiter"; then
            local verdict
            verdict=$(state '.last_result.verdict')

            if [ -z "$verdict" ] || [ "$verdict" = "null" ]; then
                log WARN "Arbiter returned empty verdict (attempt $attempt/$max_retries)"
                if [ "$attempt" -lt "$max_retries" ]; then
                    log INFO "Retrying arbiter in ${arbiter_delay}s..."
                    sleep "$arbiter_delay"
                    continue
                fi
                log ERROR "Arbiter returned empty verdict on all attempts. Defaulting to HALT."
                ARBITER_VERDICT="HALT"
                return 1
            fi

            ARBITER_VERDICT="$verdict"
            return 0
        fi

        log ERROR "Arbiter dispatch crashed (attempt $attempt/$max_retries)"
        if [ "$attempt" -lt "$max_retries" ]; then
            log INFO "Retrying arbiter in ${arbiter_delay}s..."
            sleep "$arbiter_delay"
        fi
    done

    log ERROR "Arbiter failed after $max_retries attempts. Defaulting to HALT."
    ARBITER_VERDICT="HALT"
    return 1
}

# Universal dispatch wrapper with retry + arbiter escalation.
#
# dispatch_or_recover SKILL SKIP_STATE [MODEL]
#
# Tries dispatch with retry, then escalates to arbiter if all retries fail.
#   SKILL       - The skill to dispatch (e.g., "/parse-roadmap")
#   SKIP_STATE  - State to advance to if arbiter says SKIP. Use "NONE" if
#                 skipping is not meaningful for this skill.
#   MODEL       - Optional model override
#
# Returns:
#   0 = dispatch succeeded normally
#   1 = arbiter said RETRY (caller should `continue` the main loop)
#   2 = arbiter said SKIP (state already advanced to SKIP_STATE)
#   3 = arbiter said HALT (caller should `exit 1`)
dispatch_or_recover() {
    local skill="$1"
    local skip_state="$2"
    local model="${3:-}"

    local max_retries dispatch_delay
    max_retries=$(config "max_dispatch_retries" "2")
    dispatch_delay=$(config "dispatch_retry_delay_seconds" "30")

    local attempt=0
    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))

        if dispatch "$skill" "$model"; then
            return 0
        fi

        log WARN "Dispatch failed: $skill (attempt $attempt/$max_retries)"
        if [ "$attempt" -lt "$max_retries" ]; then
            log INFO "Retrying in ${dispatch_delay}s..."
            sleep "$dispatch_delay"
        fi
    done

    log ERROR "Dispatch exhausted retries for: $skill. Escalating to arbiter."

    # Set context for arbiter decision
    jq --arg skill "$skill" --arg time "$(date -Iseconds)" \
       '.last_result = {skill: $skill, verdict: "DISPATCH_FAILED", reason: "Exhausted retries"} | .last_transition = $time' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state

    invoke_arbiter
    local arb_verdict="$ARBITER_VERDICT"

    case "$arb_verdict" in
        RETRY)
            log INFO "Arbiter: RETRY. Will re-enter state loop."
            return 1
            ;;
        SKIP)
            if [ -n "$skip_state" ] && [ "$skip_state" != "NONE" ]; then
                log INFO "Arbiter: SKIP. Advancing to $skip_state."
                jq --arg state "$skip_state" --arg time "$(date -Iseconds)" \
                   '.current_state = $state | .last_transition = $time | del(.last_result)' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                return 2
            else
                log WARN "Arbiter said SKIP but no skip state defined for $skill. Treating as HALT."
                return 3
            fi
            ;;
        *)
            log ERROR "Arbiter: HALT (verdict: $arb_verdict)"
            return 3
            ;;
    esac
}

# Handle dispatch_or_recover return code in the main loop.
# Usage: dispatch_or_recover ... ; handle_dispatch_rc $? || continue
# Returns 0 if dispatch succeeded, exits on HALT, returns 1 on RETRY/SKIP
# (caller should use `|| continue` to re-enter the loop).
handle_dispatch_rc() {
    local rc="$1"
    case "$rc" in
        0) return 0 ;;
        1|2) return 1 ;;  # RETRY or SKIP — caller should continue loop
        3) exit 1 ;;      # HALT
        *) exit 1 ;;      # unexpected — fail safe
    esac
}

# ══════════════════════════════════════════════════════════════════
# SAFETY
# ══════════════════════════════════════════════════════════════════

preflight() {
    if [ -f "$KILL_FILE" ]; then
        log ERROR "Kill file detected ($KILL_FILE). Halting."
        exit 1
    fi
    if [ -f ".claude/scripts/sentinel-check.sh" ]; then
        if ! bash .claude/scripts/sentinel-check.sh 2>/dev/null; then
            log ERROR "Sentinel check failed. Halting."
            exit 1
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════
# HISTORY & ARCHIVE MANAGEMENT
# ══════════════════════════════════════════════════════════════════

# Archive old transition_history entries to keep state.json minimal
archive_transitions() {
    local count
    count=$(jq '.transition_history | length' "$STATE_FILE" 2>/dev/null || echo "0")
    [ "$count" -le "$HISTORY_KEEP" ] && return 0

    local archive_count=$((count - HISTORY_KEEP))

    if ! jq -c ".transition_history[:$archive_count][]" "$STATE_FILE" >> "$HISTORY_ARCHIVE"; then
        log WARN "Failed to append to $HISTORY_ARCHIVE, skipping archive."
        return 1
    fi

    jq --argjson keep "$HISTORY_KEEP" \
       '.transition_history = .transition_history[-$keep:]' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state

    log INFO "Archived $archive_count transitions to $HISTORY_ARCHIVE"
}

# Archive merged PRs from previous steps to keep state.json lean.
# Keeps only PRs from the current step (unmerged) and the last 10 merged.
archive_merged_prs() {
    local merged_count
    merged_count=$(jq '[.prs // {} | to_entries[] | select(.value.status == "merged")] | length' "$STATE_FILE" 2>/dev/null || echo "0")

    [ "$merged_count" -le 10 ] && return 0

    local archive_count=$((merged_count - 10))
    local archive_file="${HISTORY_ARCHIVE%.jsonl}-prs.jsonl"

    # Append oldest merged PRs to archive
    if ! jq -c "[.prs // {} | to_entries[] | select(.value.status == \"merged\")] | sort_by(.key | tonumber) | .[:$archive_count][]" \
         "$STATE_FILE" >> "$archive_file" 2>/dev/null; then
        log WARN "Failed to archive merged PRs."
        return 1
    fi

    # Remove archived PRs from state (oldest N merged)
    jq --argjson n "$archive_count" '
        ([.prs // {} | to_entries[] | select(.value.status == "merged")]
         | sort_by(.key | tonumber) | .[:$n] | .[].key) as $keys
        | reduce ($keys | .[]) as $k (.; del(.prs[$k]))
    ' "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
    log INFO "Archived $archive_count merged PRs to $archive_file"
}

# ══════════════════════════════════════════════════════════════════
# CI CONTEXT ENRICHMENT
# ══════════════════════════════════════════════════════════════════

# Enrich state.json with CI failure context for the arbiter
enrich_ci_context() {
    local pr_num="$1" fix_attempt="$2" max_attempts="$3"
    local pr_branch

    log INFO "Enriching CI context for PR #$pr_num (attempt $fix_attempt/$max_attempts)"

    pr_branch=$(gh pr view "$pr_num" --json headRefName -q '.headRefName' 2>/dev/null || echo "")

    local failed_checks
    failed_checks=$(gh pr view "$pr_num" --json statusCheckRollup \
        -q '[.statusCheckRollup // [] | .[] | select(.status == "COMPLETED" and .conclusion == "FAILURE")] | map({name: .name, detail: .detailsUrl})' \
        2>/dev/null || echo "[]")

    local enriched_checks
    enriched_checks=$(echo "$failed_checks" | jq '[.[] | {
        name: .name,
        job_id: (.detail | capture("job/(?<id>[0-9]+)") | .id // empty),
        run_id: (.detail | capture("runs/(?<id>[0-9]+)") | .id // empty)
    }]' 2>/dev/null || echo "[]")

    if [ "$enriched_checks" = "[]" ] || [ -z "$enriched_checks" ]; then
        log WARN "Failed to extract job IDs from failed checks for PR $pr_num"
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
       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state

    # Capture CI failure logs to sidecar file
    local log_file=".chaos/framework/order/ci-failure-${pr_num}.log"
    {
        echo "=== CI Failure Context for PR #${pr_num} ==="
        echo "Timestamp: $(date -Iseconds)"
        echo "Fix attempt: ${fix_attempt}/${max_attempts}"
        echo "Branch: ${pr_branch}"
        echo ""
    } > "$log_file"

    local repo
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")

    if [ -n "$repo" ] && [ "$enriched_checks" != "[]" ] && [ -n "$enriched_checks" ]; then
        for job_id in $(echo "$enriched_checks" | jq -r '.[].job_id // empty'); do
            [ -z "$job_id" ] && continue
            local job_name
            job_name=$(echo "$enriched_checks" | jq -r --arg jid "$job_id" \
                '.[] | select(.job_id == $jid) | .name // "unknown"')
            echo "--- Check: $job_name (job $job_id) ---" >> "$log_file"
            gh api "repos/$repo/actions/jobs/$job_id/logs" 2>/dev/null \
                | tail -100 >> "$log_file" \
                || echo "  (failed to fetch logs)" >> "$log_file"
            echo "" >> "$log_file"
        done
    fi

    log INFO "CI failure context saved to $log_file"
}

# ══════════════════════════════════════════════════════════════════
# CONFLICT RESOLUTION
# ══════════════════════════════════════════════════════════════════

# Attempt simple conflict resolution for add/add superset conflicts.
# Returns 0 if ALL conflicts in the current rebase step were resolved.
try_simple_conflict_resolution() {
    local conflict_files
    conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null)
    [ -z "$conflict_files" ] && return 1

    local all_resolved=true

    while IFS= read -r cfile; do
        [ -z "$cfile" ] && continue

        local block_count
        block_count=$(grep -c '^<<<<<<<' "$cfile" 2>/dev/null || echo "0")
        if [ "$block_count" -ne 1 ]; then
            log DEBUG "Skipping $cfile: $block_count conflict blocks (only single-block supported)"
            all_resolved=false
            continue
        fi

        local ours theirs
        ours=$(sed -n '/^<<<<<<</,/^=======/p' "$cfile" 2>/dev/null | sed '1d;$d')
        theirs=$(sed -n '/^=======/,/^>>>>>>>/p' "$cfile" 2>/dev/null | sed '1d;$d')

        if diff <(echo "$theirs" | sort) <(echo "$ours" | grep -Fxf <(echo "$theirs") | sort) &>/dev/null; then
            git checkout --ours "$cfile" 2>/dev/null
            git add "$cfile"
            log INFO "Simple-resolved $cfile (HEAD superset)"
        elif diff <(echo "$ours" | sort) <(echo "$theirs" | grep -Fxf <(echo "$ours") | sort) &>/dev/null; then
            git checkout --theirs "$cfile" 2>/dev/null
            git add "$cfile"
            log INFO "Simple-resolved $cfile (PR superset)"
        else
            log DEBUG "Cannot simple-resolve $cfile: not a superset conflict"
            all_resolved=false
        fi
    done <<< "$conflict_files"

    [ "$all_resolved" = true ]
}

# ══════════════════════════════════════════════════════════════════
# AUTO-FIX (delegated to project script)
# ══════════════════════════════════════════════════════════════════

auto_fix_formatting() {
    local pr_branch="$1"

    # Prefer project-specific auto-fix script if available
    if [ -f ".claude/scripts/auto-fix.sh" ]; then
        log INFO "Running project auto-fix script on $pr_branch"
        bash .claude/scripts/auto-fix.sh "$pr_branch" 2>&1 | while IFS= read -r line; do
            log DEBUG "auto-fix: $line"
        done
        return
    fi

    # Built-in fallback: detect and run common formatters
    local changed=false

    # Frontend (web/)
    if [ -d "web" ] && [ -f "web/package.json" ]; then
        log INFO "Running frontend lint:fix + prettier"
        (cd web && npx eslint . --fix 2>/dev/null || true)
        (cd web && npx prettier --write "src/**/*.{ts,tsx,css}" 2>/dev/null || true)
        if ! git diff --quiet -- web/ 2>/dev/null; then
            git diff --name-only -- web/ | xargs -r git add
            changed=true
        fi
    fi

    # Go
    if [ -f "go.mod" ]; then
        log INFO "Running go fmt"
        go fmt ./... 2>/dev/null || true
        if ! git diff --quiet 2>/dev/null; then
            git diff --name-only -- '*.go' 'go.mod' 'go.sum' | xargs -r git add
            changed=true
        fi
    fi

    if [ "$changed" = true ]; then
        git commit -m "style: auto-fix lint and formatting" 2>/dev/null || true
        git push origin "$pr_branch" 2>/dev/null || true
        log INFO "Auto-fix committed and pushed"
    else
        log DEBUG "No formatting changes needed"
    fi
}

# ══════════════════════════════════════════════════════════════════
# MERGE SUB-FUNCTIONS
#
# Each returns 0=success, 1=failure (caller should increment MERGE_FAILED).
# On failure, the function calls add_blocker() with details.
# All functions ensure we return to the main branch on exit.
# ══════════════════════════════════════════════════════════════════

# Phase 0: Rebase PR branch onto current main
merge_rebase_pr() {
    local pr_num="$1"

    local pr_data pr_branch pr_state
    pr_data=$(gh pr view "$pr_num" --json headRefName,state 2>/dev/null || echo '{}')
    pr_branch=$(echo "$pr_data" | jq -r '.headRefName // empty')
    pr_state=$(echo "$pr_data" | jq -r '.state // empty')

    if [ -z "$pr_branch" ] || [ "$pr_state" != "OPEN" ]; then
        log WARN "PR #$pr_num: not open or no branch found (state: $pr_state)"
        add_blocker "PR #$pr_num: not open (state: $pr_state)"
        return 1
    fi

    log INFO "Rebasing $pr_branch onto main"

    # Try GitHub-side branch update first
    if gh pr update-branch "$pr_num" 2>/dev/null; then
        log INFO "Branch updated via GitHub API"
        sleep 5
        return 0
    fi

    # Fallback: local rebase + force-push
    log INFO "GitHub API update failed, trying local rebase"
    git fetch origin main 2>/dev/null || true
    git checkout "$pr_branch" 2>/dev/null || {
        log ERROR "Failed to checkout $pr_branch"
        git checkout main 2>/dev/null || true
        add_blocker "PR #$pr_num: branch checkout failed"
        return 1
    }
    git pull origin "$pr_branch" 2>/dev/null || true

    if git rebase origin/main 2>/dev/null; then
        # Safety check: never force-push main/master or empty branch
        if [[ "$pr_branch" == "main" ]] || [[ "$pr_branch" == "master" ]] || [[ -z "$pr_branch" ]]; then
            log ERROR "Refusing to force-push protected branch: ${pr_branch:-<empty>}"
            git rebase --abort 2>/dev/null || true
            git checkout main 2>/dev/null || true
            add_blocker "PR #$pr_num: invalid branch for force-push"
            return 1
        fi
        log INFO "Rebase succeeded. Force-pushing."
        if git push --force-with-lease origin "$pr_branch" 2>/dev/null; then
            log INFO "Force-push succeeded"
            git checkout main 2>/dev/null || true
            return 0
        else
            log ERROR "Force-push failed"
            git rebase --abort 2>/dev/null || true
            git checkout main 2>/dev/null || true
            add_blocker "PR #$pr_num: force-push failed after rebase"
            update_pr_status "$pr_num" "rebase_failed"
            return 1
        fi
    fi

    # Rebase conflict — try simple resolution
    log INFO "Rebase conflict for PR #$pr_num. Attempting simple resolution."
    local rebase_done=false

    if try_simple_conflict_resolution; then
        log INFO "All conflicts resolved simply. Continuing rebase."
        if GIT_EDITOR=true git rebase --continue 2>/dev/null; then
            if [ ! -d ".git/rebase-merge" ] && [ ! -d ".git/rebase-apply" ]; then
                log INFO "Rebase complete via simple resolution"
                if git push --force-with-lease origin "$pr_branch" 2>/dev/null; then
                    log INFO "Force-push succeeded"
                    git checkout main 2>/dev/null || true
                    return 0
                else
                    log ERROR "Force-push failed after simple resolution"
                    git checkout main 2>/dev/null || true
                    add_blocker "PR #$pr_num: force-push failed after simple resolution"
                    update_pr_status "$pr_num" "rebase_failed"
                    return 1
                fi
            fi
        fi
    fi

    # Complex conflicts — dispatch /resolve-conflicts
    if [ ! -d ".git/rebase-merge" ] && [ ! -d ".git/rebase-apply" ]; then
        log INFO "Restarting rebase for full conflict resolution"
        git rebase --abort 2>/dev/null || true
        git rebase origin/main 2>/dev/null || true
    fi

    log INFO "Complex conflicts remain. Dispatching /resolve-conflicts."

    local conflict_files
    conflict_files=$(git diff --name-only --diff-filter=U 2>/dev/null | jq -R . | jq -s .)

    jq --arg pr "$pr_num" \
       --arg branch "$pr_branch" \
       --argjson files "${conflict_files:-[]}" \
       '.conflict_context = {pr_number: $pr, branch: $branch, conflict_files: $files}' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state

    if dispatch "/resolve-conflicts"; then
        local resolve_verdict
        resolve_verdict=$(state '.last_result.verdict')
        if [ "$resolve_verdict" = "RESOLVED" ]; then
            log INFO "Conflicts resolved for PR #$pr_num"
            git checkout main 2>/dev/null || true
            return 0
        else
            log ERROR "Resolution returned: $resolve_verdict"
        fi
    else
        log ERROR "/resolve-conflicts crashed"
    fi

    git rebase --abort 2>/dev/null || true
    git checkout main 2>/dev/null || true
    add_blocker "PR #$pr_num: conflict unresolvable"
    update_pr_status "$pr_num" "rebase_conflict"
    return 1
}

# Phase 0.5: Auto-fix lint and formatting
merge_auto_fix_pr() {
    local pr_num="$1"

    local pr_branch
    pr_branch=$(gh pr view "$pr_num" --json headRefName -q '.headRefName' 2>/dev/null)

    if [ -z "$pr_branch" ]; then
        log WARN "PR #$pr_num: could not determine branch for auto-fix"
        return 0  # non-fatal
    fi

    log INFO "Auto-fixing lint/formatting on $pr_branch"
    git checkout "$pr_branch" 2>/dev/null || true
    git pull origin "$pr_branch" 2>/dev/null || true
    auto_fix_formatting "$pr_branch"
    git checkout main 2>/dev/null || true
    return 0
}

# Phase 1: Mark draft PR as ready for review
merge_mark_ready() {
    local pr_num="$1"

    local is_draft
    is_draft=$(gh pr view "$pr_num" --json isDraft -q '.isDraft' 2>/dev/null || echo "true")

    if [ "$is_draft" = "true" ]; then
        log INFO "Marking PR #$pr_num ready for review"
        if ! gh pr ready "$pr_num" 2>/dev/null; then
            log ERROR "Failed to mark PR #$pr_num ready"
            add_blocker "PR #$pr_num: failed to mark ready for review"
            update_pr_status "$pr_num" "ready_failed"
            return 1
        fi
        update_pr_status "$pr_num" "ready"
        log INFO "PR #$pr_num marked ready"
    else
        log DEBUG "PR #$pr_num already marked ready"
    fi

    return 0
}

# Phase 2+3: Poll checks, run arbiter fixes if needed, handle review feedback
# This function handles the full check/fix/feedback cycle internally.
merge_poll_and_fix() {
    local pr_num="$1"

    local gha_timeout max_feedback max_fix poll_interval
    gha_timeout=$(config "gha_wait_timeout_minutes" "30")
    max_feedback=$(config "max_feedback_rounds" "5")
    max_fix=$(config "max_fix_attempts" "3")
    poll_interval=120

    local fix_attempt=0
    local feedback_round=0

    while [ "$feedback_round" -le "$max_feedback" ]; do

        # ── Poll checks until completion ──
        local deadline checks_resolved checks_passed failed_checks
        deadline=$(($(date +%s) + gha_timeout * 60))
        checks_resolved=false
        checks_passed=false
        failed_checks=0

        log INFO "Polling checks (timeout: ${gha_timeout}m, feedback round: $feedback_round)"

        while [ "$(date +%s)" -lt "$deadline" ]; do
            preflight

            local check_data total_checks completed_checks changes_requested
            check_data=$(gh pr view "$pr_num" --json statusCheckRollup,reviews 2>/dev/null || echo '{}')
            total_checks=$(echo "$check_data" | jq '[.statusCheckRollup // [] | .[]] | length')
            completed_checks=$(echo "$check_data" | jq '[.statusCheckRollup // [] | .[] | select(.status == "COMPLETED")] | length')
            failed_checks=$(echo "$check_data" | jq '[.statusCheckRollup // [] | .[] | select(.status == "COMPLETED" and .conclusion == "FAILURE")] | length')
            changes_requested=$(echo "$check_data" | jq '[.reviews // [] | .[] | select(.state == "CHANGES_REQUESTED")] | length')

            log DEBUG "Checks: $completed_checks/$total_checks resolved, $failed_checks failed, $changes_requested reviews requesting changes"

            # Early exit: check failure
            if [ "$failed_checks" -gt 0 ]; then
                log WARN "PR #$pr_num: check(s) FAILED"
                checks_resolved=true
                break
            fi

            # Early exit: changes requested
            if [ "$changes_requested" -gt 0 ]; then
                log WARN "PR #$pr_num: CHANGES_REQUESTED by reviewer"
                checks_resolved=true
                break
            fi

            # All checks passed
            if [ "$total_checks" -gt 0 ] && [ "$completed_checks" -eq "$total_checks" ]; then
                log INFO "PR #$pr_num: all $total_checks checks passed"
                checks_resolved=true
                checks_passed=true
                break
            fi

            sleep "$poll_interval"
        done

        # Timeout
        if [ "$checks_resolved" = false ]; then
            log ERROR "PR #$pr_num timed out waiting for checks (${gha_timeout}m)"
            add_blocker "PR #$pr_num: checks timed out after ${gha_timeout}m"
            update_pr_status "$pr_num" "timeout"
            return 1
        fi

        # ── Checks passed — run review feedback cycle ──
        if [ "$checks_passed" = true ]; then
            if [ "$feedback_round" -lt "$max_feedback" ]; then
                feedback_round=$((feedback_round + 1))

                local pr_branch
                pr_branch=$(gh pr view "$pr_num" --json headRefName -q '.headRefName' 2>/dev/null)

                if [ -n "$pr_branch" ]; then
                    git checkout "$pr_branch" 2>/dev/null || true
                    git pull origin "$pr_branch" 2>/dev/null || true
                    local old_head
                    old_head=$(git rev-parse HEAD 2>/dev/null)

                    log INFO "Running /review-feedback (round $feedback_round/$max_feedback)"
                    update_pr_status "$pr_num" "feedback_round_$feedback_round"
                    dispatch "/review-feedback" || true

                    git pull origin "$pr_branch" 2>/dev/null || true
                    local new_head
                    new_head=$(git rev-parse HEAD 2>/dev/null)
                    git checkout main 2>/dev/null || true

                    # Non-blocking review items
                    if [ -f ".chaos/todos/TODO-${pr_num}.md" ]; then
                        log INFO "Non-blocking review items saved to .chaos/todos/TODO-${pr_num}.md"
                    fi

                    if [ "$new_head" = "$old_head" ] || [ -z "$pr_branch" ]; then
                        log INFO "No changes from feedback. Ready to merge."
                        return 0
                    fi

                    log INFO "Feedback pushed changes. Re-polling checks."
                    sleep 10
                    continue  # re-enter check polling loop
                fi
            fi

            # Max feedback rounds reached or no branch
            log INFO "Checks passed. Ready to merge."
            return 0
        fi

        # ── Checks failed — try worker fix first, then arbiter ──
        if [ "$failed_checks" -gt 0 ] && [ "$fix_attempt" -lt "$max_fix" ]; then
            fix_attempt=$((fix_attempt + 1))

            # Tier 1: Worker self-correction (first N attempts)
            local worker_max
            worker_max=$(config "max_worker_fix_attempts" "1")

            if [ "$fix_attempt" -le "$worker_max" ]; then
                log INFO "Fix attempt $fix_attempt/$max_fix for PR #$pr_num (tier: worker)"
                if merge_worker_fix_cycle "$pr_num" "$fix_attempt" "$max_fix"; then
                    log INFO "Worker fix pushed. Re-polling checks."
                    sleep 15
                    continue  # re-enter check polling loop
                fi
                log WARN "Worker fix failed. Next attempt will use arbiter."
                continue  # re-enter loop with incremented fix_attempt
            fi

            # Tier 2: Arbiter tactical fix (remaining attempts)
            log INFO "Fix attempt $fix_attempt/$max_fix for PR #$pr_num (tier: arbiter)"
            if merge_arbiter_fix_cycle "$pr_num" "$fix_attempt" "$max_fix"; then
                log INFO "Arbiter fix pushed. Re-polling checks."
                sleep 15
                continue  # re-enter check polling loop
            else
                return 1  # arbiter_fix_cycle already set blocker
            fi
        fi

        # Exhausted fix attempts or changes requested
        if [ "$failed_checks" -gt 0 ]; then
            log ERROR "Max fix attempts ($max_fix) exhausted for PR #$pr_num"
            add_blocker "PR #$pr_num: checks failed after $max_fix fix attempts"
            update_pr_status "$pr_num" "checks_failed"
        else
            add_blocker "PR #$pr_num: review requested changes"
            update_pr_status "$pr_num" "changes_requested"
        fi
        return 1

    done  # feedback_round loop

    log INFO "Max feedback rounds ($max_feedback) reached. Proceeding to merge."
    return 0
}

# Arbiter CI fix sub-cycle: checkout PR branch, run arbiter, review fix, push
# Returns 0 if fix was pushed successfully, 1 otherwise.
merge_arbiter_fix_cycle() {
    local pr_num="$1" fix_attempt="$2" max_fix="$3"

    enrich_ci_context "$pr_num" "$fix_attempt" "$max_fix"

    local pr_branch
    pr_branch=$(gh pr view "$pr_num" --json headRefName -q '.headRefName' 2>/dev/null)
    git checkout "$pr_branch" 2>/dev/null || true
    git pull origin "$pr_branch" 2>/dev/null || true

    local pre_head
    pre_head=$(git rev-parse HEAD 2>/dev/null)

    if [ -z "$pre_head" ]; then
        log ERROR "Failed to capture pre-arbiter HEAD"
        git checkout main 2>/dev/null || true
        add_blocker "PR #$pr_num: failed to capture safety anchor"
        return 1
    fi

    # Dispatch arbiter with retry (CI fix mode — arbiter_context is set)
    local arbiter_ok=false
    local arb_attempt=0
    local arb_max arb_delay
    arb_max=$(config "max_arbiter_retries" "2")
    arb_delay=$(config "arbiter_retry_delay_seconds" "15")

    while [ "$arb_attempt" -lt "$arb_max" ]; do
        arb_attempt=$((arb_attempt + 1))
        log INFO "Dispatching CI-fix arbiter (attempt $arb_attempt/$arb_max)"

        if dispatch "/order-arbiter"; then
            local check_verdict
            check_verdict=$(state '.last_result.verdict')
            if [ -n "$check_verdict" ] && [ "$check_verdict" != "null" ]; then
                arbiter_ok=true
                break
            fi
            log WARN "Arbiter returned empty verdict (attempt $arb_attempt/$arb_max)"
        else
            log ERROR "Arbiter crashed (attempt $arb_attempt/$arb_max)"
        fi

        if [ "$arb_attempt" -lt "$arb_max" ]; then
            git reset --hard "$pre_head" 2>/dev/null || true
            log INFO "Retrying arbiter in ${arb_delay}s..."
            sleep "$arb_delay"
        fi
    done

    if [ "$arbiter_ok" = false ]; then
        log ERROR "Arbiter failed after $arb_max attempts for PR #$pr_num. Reverting."
        git reset --hard "$pre_head" 2>/dev/null || true
        git checkout main 2>/dev/null || true
        add_blocker "PR #$pr_num: arbiter crashed after $arb_max attempts"
        return 1
    fi

    local arb_verdict
    arb_verdict=$(state '.last_result.verdict')

    case "$arb_verdict" in
        FIXED)
            log INFO "Arbiter: FIXED. Running review."
            if ! dispatch "/arbiter-review"; then
                log ERROR "/arbiter-review crashed. Reverting."
                git reset --hard "$pre_head" 2>/dev/null || true
                git checkout main 2>/dev/null || true
                add_blocker "PR #$pr_num: arbiter-review crashed"
                return 1
            fi

            local review_verdict
            review_verdict=$(state '.last_result.review')

            if [ "$review_verdict" = "APPROVED" ]; then
                log INFO "Review: APPROVED. Pushing fix."
                if git push origin "$pr_branch" 2>/dev/null; then
                    git checkout main 2>/dev/null || true
                    return 0
                else
                    log ERROR "Push failed. Reverting."
                    git reset --hard "$pre_head" 2>/dev/null || true
                    git checkout main 2>/dev/null || true
                    add_blocker "PR #$pr_num: arbiter fix push failed"
                    return 1
                fi
            else
                local reason
                reason=$(state '.last_result.review_reason // "no reason"')
                log WARN "Review: REJECTED -- $reason. Reverting."
                git reset --hard "$pre_head" 2>/dev/null || true
                git checkout main 2>/dev/null || true
                add_blocker "PR #$pr_num: arbiter fix rejected -- $reason"
                return 1
            fi
            ;;
        *)
            log WARN "Arbiter: $arb_verdict. Reverting."
            git reset --hard "$pre_head" 2>/dev/null || true
            git checkout main 2>/dev/null || true
            add_blocker "PR #$pr_num: arbiter verdict $arb_verdict"
            return 1
            ;;
    esac
}

# Worker CI fix sub-cycle: checkout PR branch, run /fix-ci, push.
# The worker has full codebase access and no scope limits (unlike the arbiter).
# Returns 0 if fix was pushed successfully, 1 otherwise.
merge_worker_fix_cycle() {
    local pr_num="$1" fix_attempt="$2" max_attempts="$3"

    enrich_ci_context "$pr_num" "$fix_attempt" "$max_attempts"

    local pr_branch
    pr_branch=$(gh pr view "$pr_num" --json headRefName -q '.headRefName' 2>/dev/null)
    git checkout "$pr_branch" 2>/dev/null || true
    git pull origin "$pr_branch" 2>/dev/null || true

    local pre_head
    pre_head=$(git rev-parse HEAD 2>/dev/null)
    if [ -z "$pre_head" ]; then
        log ERROR "Failed to capture pre-worker-fix HEAD"
        git checkout main 2>/dev/null || true
        return 1
    fi

    log INFO "Dispatching /fix-ci for PR #$pr_num (worker fix)"

    if dispatch "/fix-ci" "$WORK_MODEL"; then
        local fix_verdict
        fix_verdict=$(state '.last_result.verdict')

        if [ "$fix_verdict" = "FIXED" ]; then
            log INFO "Worker fix: FIXED. Pushing."
            if git push origin "$pr_branch" 2>/dev/null; then
                git checkout main 2>/dev/null || true
                return 0
            fi
            log ERROR "Worker fix push failed. Reverting."
        else
            log WARN "Worker fix verdict: $fix_verdict. Reverting to let arbiter try."
        fi
    else
        log ERROR "Worker fix dispatch failed. Reverting."
    fi

    git reset --hard "$pre_head" 2>/dev/null || true
    git checkout main 2>/dev/null || true
    return 1
}

# Phase 4: Merge the PR
merge_do_merge() {
    local pr_num="$1"

    local merge_method delete_branch
    merge_method=$(config "merge_method" "squash")
    delete_branch=$(config "delete_branch" "true")

    update_pr_status "$pr_num" "checks_passed"
    log INFO "Merging PR #$pr_num (method: $merge_method)"

    local merge_flags="--$merge_method"
    if [ "$delete_branch" = "true" ]; then
        merge_flags="$merge_flags --delete-branch"
    fi

    # shellcheck disable=SC2086
    if gh pr merge "$pr_num" $merge_flags 2>/dev/null; then
        log INFO "PR #$pr_num merged successfully"
        update_pr_status "$pr_num" "merged"
        git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true
        return 0
    fi

    # gh pr merge can return non-zero even when the PR was merged
    sleep 3
    local actual_state
    actual_state=$(gh pr view "$pr_num" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")

    if [ "$actual_state" = "MERGED" ]; then
        log INFO "PR #$pr_num: merge command returned error but PR is MERGED. Continuing."
        update_pr_status "$pr_num" "merged"
        git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true
        return 0
    fi

    log ERROR "PR #$pr_num: merge command failed (state: $actual_state)"
    add_blocker "PR #$pr_num: gh pr merge command failed"
    update_pr_status "$pr_num" "merge_failed"
    return 1
}

# Discover PRs from queue when state.json has none registered.
# Prints discovered PR numbers to stdout for capture by caller.
# All log output is redirected to stderr to avoid polluting stdout.
discover_prs() {
    local queue_count
    queue_count=$(count_queue_tasks)

    if [ "$queue_count" -eq 0 ]; then
        return 0
    fi

    log WARN "$queue_count tasks in queue but no PRs in state. Attempting discovery." >&2
    local discovered=0

    while IFS='|' read -r disc_task_id disc_rest; do
        [[ "$disc_task_id" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${disc_task_id}" ]] && continue
        disc_task_id=$(echo "$disc_task_id" | xargs)
        [[ -z "$disc_task_id" ]] && continue

        local disc_bd_id disc_pr
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
            log INFO "Discovered PR #$disc_pr for task $disc_task_id" >&2
            jq --arg pr "$disc_pr" --arg task "$disc_task_id" \
                '.prs[$pr] = {"task": $task, "status": "draft"}' \
                "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
            discovered=$((discovered + 1))
        fi
    done < "$QUEUE_FILE"

    if [ "$discovered" -eq 0 ]; then
        log ERROR "Could not discover any PRs for $queue_count queued tasks." >&2
        return 0  # return empty, caller handles
    fi

    log INFO "Discovered $discovered PRs." >&2
    # Return the newly discovered PR numbers
    jq -r '.prs // {} | to_entries[] | select(.value.status == "merged" | not) | .key' "$STATE_FILE" 2>/dev/null
}

# Cleanup merge artifacts after MERGE_PRS completes
cleanup_merge_artifacts() {
    # Remove arbiter_context
    if jq -e '.arbiter_context' "$STATE_FILE" >/dev/null 2>&1; then
        jq 'del(.arbiter_context)' "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
        log DEBUG "Cleaned up arbiter_context"
    fi

    # Cleanup CI failure logs for merged PRs
    for ci_log in .chaos/framework/order/ci-failure-*.log; do
        [ -f "$ci_log" ] || continue
        local log_pr
        log_pr=$(basename "$ci_log" | sed 's/ci-failure-\([0-9]*\)\.log/\1/')
        local log_status
        log_status=$(jq -r ".prs[\"$log_pr\"].status // \"unknown\"" "$STATE_FILE" 2>/dev/null)
        if [ "$log_status" = "merged" ]; then
            rm -f "$ci_log"
            log DEBUG "Cleaned up $ci_log"
        fi
    done
}

# ══════════════════════════════════════════════════════════════════
# INITIALIZATION
# ══════════════════════════════════════════════════════════════════

init_logging
log INFO "ORDER Lifecycle Orchestrator v3.0"
log INFO "Max steps: $MAX_STEPS, Work model: $WORK_MODEL"

if [ ! -f "$STATE_FILE" ]; then
    if [ -f "${STATE_FILE}.bak" ]; then
        log WARN "State file missing — recovering from backup."
        cp "${STATE_FILE}.bak" "$STATE_FILE"
        log INFO "Recovery successful. State: $(jq -c '{state: .current_state, step: .step_number}' "$STATE_FILE" 2>/dev/null)"
    else
        log INFO "No state file found. Creating initial state."
        echo '{"current_state":"INIT","transition_history":[],"completed":[],"failed":[],"prs":{}}' > "$STATE_FILE"
    fi
fi
rm -f "${STATE_FILE}.tmp"

if [ -n "$START_STEP" ]; then
    log INFO "Resuming from step $START_STEP"
    jq --arg step "$START_STEP" --arg time "$(date -Iseconds)" \
       '.current_state = "PARSE_ROADMAP" | .step_number = ($step | tonumber) | del(.last_result) | .last_transition = $time' \
       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
fi

log_state_summary
recover_dirty_state

# ══════════════════════════════════════════════════════════════════
# MAIN STATE MACHINE LOOP
# ══════════════════════════════════════════════════════════════════

while true; do
    preflight
    archive_transitions
    archive_merged_prs

    CURRENT=$(state '.current_state')
    CURRENT_STEP=$(state '.step_number // "?"')
    VERDICT=$(state '.last_result.verdict')

    log_separator "$CURRENT ${VERDICT:+(verdict: $VERDICT)}"

    case "$CURRENT" in

        # ── INIT: Parse roadmap for next uncompleted step ──────────
        INIT)
            dispatch_or_recover "/parse-roadmap" "NONE"
            handle_dispatch_rc $? || continue

            VERDICT=$(state '.last_result.verdict')
            if [ "$VERDICT" = "ROADMAP_COMPLETE" ]; then
                log INFO "=== Roadmap Complete ==="
                log INFO "All steps have been processed."
                exit 0
            fi

            CURRENT_STEP=$(state '.step_number')
            step_count=$((step_count + 1))
            if [ "$step_count" -gt "$MAX_STEPS" ]; then
                log INFO "Max steps ($MAX_STEPS) reached."
                exit 0
            fi
            revision_count=0

            # Start a step-specific log file
            step_title=$(state '.last_result.title')
            start_step_log "$CURRENT_STEP" "$step_title"
            log INFO "Step $CURRENT_STEP identified: $step_title"
            log_state_summary
            ;;

        # ── PARSE_ROADMAP: Create spec for this step ──────────────
        PARSE_ROADMAP)
            STEP=$(state '.step_number')

            if [ "$VERDICT" = "SPEC_EXISTS" ]; then
                log INFO "Step $STEP already has a spec. Advancing to REVIEW_SPEC."
                jq --arg time "$(date -Iseconds)" \
                   '.current_state = "CREATE_SPEC" | .last_transition = $time | .last_result.verdict = "SPEC_CREATED"' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                continue
            fi

            dispatch_or_recover "/create-spec $STEP" "INIT"
            handle_dispatch_rc $? || continue
            log INFO "Spec created: $(state '.spec_id')"
            log_state_summary
            ;;

        # ── CREATE_SPEC: Review spec, or re-create if revision needed
        CREATE_SPEC)
            if [ "$VERDICT" = "NEEDS_REVISION" ]; then
                revision_count=$((revision_count + 1))
                MAX_REV=$(config "max_spec_revisions" "3")

                if [ "$revision_count" -gt "$MAX_REV" ]; then
                    log WARN "Max revisions ($MAX_REV) exceeded. Invoking arbiter."
                    invoke_arbiter; ARB="$ARBITER_VERDICT"
                    case "$ARB" in
                        SKIP)
                            log INFO "Arbiter: SKIP. Advancing to next step."
                            jq '.current_state = "INIT" | del(.last_result)' \
                                "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                            continue
                            ;;
                        RETRY)
                            log INFO "Arbiter: RETRY. Resetting revision count."
                            revision_count=0
                            continue
                            ;;
                        *)
                            log ERROR "Arbiter: HALT (verdict: $ARB)"
                            exit 1
                            ;;
                    esac
                fi

                log INFO "Revision $revision_count/$MAX_REV -- revising spec from review feedback"
                dispatch_or_recover "/revise-spec" "INIT"
                handle_dispatch_rc $? || continue
            else
                SPEC_ID=$(state '.spec_id')
                log INFO "Reviewing spec: specs/$SPEC_ID/SPEC.md"
                dispatch_or_recover "/review-spec specs/$SPEC_ID/SPEC.md" "REVIEW_SPEC"
                handle_dispatch_rc $? || continue

                NEW_VERDICT=$(state '.last_result.verdict')
                log INFO "Review verdict: $NEW_VERDICT"
                if [ "$NEW_VERDICT" = "READY" ]; then
                    revision_count=0
                fi
            fi
            log_state_summary
            ;;

        # ── REVIEW_SPEC: Plan work from approved spec ─────────────
        REVIEW_SPEC)
            SPEC_ID=$(state '.spec_id')
            log INFO "Planning work for specs/$SPEC_ID/SPEC.md"
            dispatch_or_recover "/plan-work specs/$SPEC_ID/SPEC.md" "INIT"
            handle_dispatch_rc $? || continue
            log INFO "Tasks created: $(state '.last_result.task_count')"
            log_state_summary
            ;;

        # ── PLAN_WORK: Execute next single task from queue ────────
        PLAN_WORK)
            # Find next unprocessed task
            NEXT_TASK=""
            TOTAL_TASKS=0
            while IFS='|' read -r task_id rest; do
                [[ "$task_id" =~ ^[[:space:]]*# ]] && continue
                [[ -z "${task_id}" ]] && continue
                task_id=$(echo "$task_id" | xargs)
                [[ -z "$task_id" ]] && continue
                TOTAL_TASKS=$((TOTAL_TASKS + 1))

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
                log INFO "All $TOTAL_TASKS tasks processed ($COMPLETED_COUNT ok, $FAILED_COUNT failed)."

                if [ "$FAILED_COUNT" -gt 0 ]; then
                    TASK_VERDICT="TASKS_FAILED"
                else
                    TASK_VERDICT="TASKS_COMPLETE"
                fi

                jq --arg state "MERGE_PRS" \
                   --arg time "$(date -Iseconds)" \
                   --arg verdict "$TASK_VERDICT" \
                   --argjson failures "$FAILED_COUNT" \
                   '.current_state = $state | .last_transition = $time | .last_result = {skill: "order-run-loop", verdict: $verdict, failures: $failures}' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
            else
                log INFO "[$((COMPLETED_COUNT + FAILED_COUNT + 1))/$TOTAL_TASKS] Working task: $NEXT_TASK"

                run_dir=".chaos/framework/runs/$NEXT_TASK"
                mkdir -p "$run_dir"

                # Checkout main, create task branch
                git checkout main 2>/dev/null || true
                git pull origin main 2>/dev/null || true
                git checkout -b "task/$NEXT_TASK" 2>/dev/null || git checkout "task/$NEXT_TASK" 2>/dev/null || true

                log INFO "Dispatching /work $NEXT_TASK (model: $WORK_MODEL)"
                work_start=$SECONDS
                skill_timeout=$(get_dispatch_timeout)

                timeout "$skill_timeout" claude -p "/work $NEXT_TASK" \
                    --dangerously-skip-permissions \
                    --model "$WORK_MODEL" \
                    > "$run_dir/output.log" 2>&1
                TASK_EXIT=$?

                work_elapsed=$((SECONDS - work_start))

                # Append tail of work output to main log
                if [ -n "$LOG_FILE" ] && [ -f "$run_dir/output.log" ]; then
                    {
                        echo ""
                        echo "=== /work $NEXT_TASK (exit: $TASK_EXIT, ${work_elapsed}s) ==="
                        tail -80 "$run_dir/output.log"
                        echo "=== End /work (full log: $run_dir/output.log) ==="
                        echo ""
                    } >> "$LOG_FILE"
                fi

                if [ "$TASK_EXIT" -eq 124 ]; then
                    log ERROR "/work $NEXT_TASK TIMED OUT after ${skill_timeout}s"
                elif [ "$TASK_EXIT" -ne 0 ]; then
                    log ERROR "/work $NEXT_TASK FAILED (exit $TASK_EXIT, ${work_elapsed}s)"
                else
                    log INFO "/work $NEXT_TASK completed (${work_elapsed}s)"
                fi

                # Post-task hook
                if [ -f ".claude/scripts/post-task-hook.sh" ]; then
                    log DEBUG "Running post-task hook for $NEXT_TASK"
                    bash .claude/scripts/post-task-hook.sh "$NEXT_TASK" "$TASK_EXIT" 2>/dev/null || true
                fi

                # Return to main
                git checkout main 2>/dev/null || true

                # Check result
                if jq -e --arg t "$NEXT_TASK" '.completed // [] | index($t) != null' "$STATE_FILE" >/dev/null 2>&1; then
                    log INFO "Task $NEXT_TASK: OK"
                    TASK_VERDICT="TASKS_COMPLETE"
                else
                    log ERROR "Task $NEXT_TASK: FAILED"
                    TASK_VERDICT="TASKS_FAILED"
                fi

                jq --arg state "EXECUTE_TASKS" \
                   --arg time "$(date -Iseconds)" \
                   --arg verdict "$TASK_VERDICT" \
                   --arg task "$NEXT_TASK" \
                   '.current_state = $state | .last_transition = $time | .last_result = {skill: "order-run-loop", verdict: $verdict, current_task: $task}' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
            fi
            log_state_summary
            ;;

        # ── EXECUTE_TASKS: Handle task result, then transition ────
        EXECUTE_TASKS)
            if [ "$VERDICT" = "TASKS_FAILED" ]; then
                log WARN "Task failed. Invoking arbiter."
                invoke_arbiter; ARB="$ARBITER_VERDICT"

                case "$ARB" in
                    RETRY)
                        log INFO "Arbiter: RETRY task."
                        FAILED_TASK=$(state '.last_result.current_task // empty')
                        if [ -n "$FAILED_TASK" ]; then
                            jq --arg t "$FAILED_TASK" --arg time "$(date -Iseconds)" \
                               '.failed = [.failed // [] | .[] | select(. != $t)] | .consecutive_failures = 0 | .current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                        else
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                        fi
                        continue
                        ;;
                    SKIP)
                        log INFO "Arbiter: SKIP failed task. Moving to next."
                        REMAINING_PROCESSED=$(jq '[.completed // [], .failed // []] | flatten | length' "$STATE_FILE")
                        TOTAL_Q=$(count_queue_tasks)
                        if [ "$REMAINING_PROCESSED" -ge "$TOTAL_Q" ]; then
                            log INFO "No more tasks. Advancing to merge available PRs."
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "MERGE_PRS" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                        else
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                        fi
                        continue
                        ;;
                    *)
                        log ERROR "Arbiter: HALT (verdict: $ARB)"
                        exit 1
                        ;;
                esac
            fi

            # Task succeeded — transition to MERGE_PRS
            log INFO "Task succeeded. Transitioning to MERGE_PRS."
            jq --arg time "$(date -Iseconds)" \
               '.current_state = "MERGE_PRS" | .last_transition = $time | del(.last_result)' \
               "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
            ;;

        # ── MERGE_PRS: Rebase, fix, poll, merge ──────────────────
        MERGE_PRS)
            log_separator "MERGE_PRS"

            mkdir -p .chaos/todos

            # Collect unmerged PRs
            PR_NUMBERS=$(jq -r '.prs // {} | to_entries[] | select(.value.status == "merged" | not) | .key' "$STATE_FILE" 2>/dev/null)

            if [ -z "$PR_NUMBERS" ]; then
                PR_NUMBERS=$(discover_prs)
                if [ -z "$PR_NUMBERS" ]; then
                    log INFO "No PRs to merge. Advancing to VERIFY_COMPLETION."
                    jq --arg time "$(date -Iseconds)" \
                       '.current_state = "VERIFY_COMPLETION" | .last_transition = $time' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                    continue
                fi
            fi

            MERGE_FAILED=0
            MERGE_SUCCEEDED=0
            MERGE_BLOCKERS=()

            for PR_NUM in $PR_NUMBERS; do
                preflight

                pr_status=$(jq -r ".prs[\"$PR_NUM\"].status // \"draft\"" "$STATE_FILE")
                if [ "$pr_status" = "merged" ]; then
                    log INFO "PR #$PR_NUM: already merged, skipping"
                    MERGE_SUCCEEDED=$((MERGE_SUCCEEDED + 1))
                    continue
                fi

                log_separator "PR #$PR_NUM"

                # Phase 0: Rebase
                merge_rebase_pr "$PR_NUM" || { MERGE_FAILED=$((MERGE_FAILED + 1)); continue; }
                sleep 10

                # Phase 0.5: Auto-fix
                merge_auto_fix_pr "$PR_NUM"
                sleep 5

                # Phase 1: Mark ready
                merge_mark_ready "$PR_NUM" || { MERGE_FAILED=$((MERGE_FAILED + 1)); continue; }
                sleep 10

                # Phase 2+3: Poll checks, fix, feedback
                merge_poll_and_fix "$PR_NUM" || { MERGE_FAILED=$((MERGE_FAILED + 1)); continue; }

                # Phase 4: Merge
                merge_do_merge "$PR_NUM" || { MERGE_FAILED=$((MERGE_FAILED + 1)); continue; }

                MERGE_SUCCEEDED=$((MERGE_SUCCEEDED + 1))
            done

            # Cleanup
            cleanup_merge_artifacts

            log INFO "Merge results: $MERGE_SUCCEEDED merged, $MERGE_FAILED failed"

            # ── Decide next state ──
            PROCESSED=$(jq '[.completed // [], .failed // []] | flatten | length' "$STATE_FILE")
            TOTAL_Q=$(count_queue_tasks)
            REMAINING=$((TOTAL_Q - PROCESSED))

            if [ "$MERGE_FAILED" -eq 0 ]; then
                log INFO "Pulling latest main after merge"
                git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true

                # Mark ROADMAP step as complete [X] at merge time (not just at handoff).
                # This prevents restart loops from re-attempting already-merged work.
                if [ "$REMAINING" -eq 0 ]; then
                    STEP=$(state '.step_number')
                    if [ -n "$STEP" ] && [ -f "docs/ROADMAP.md" ]; then
                        if grep -qP "^${STEP}\\. \\[ \\]" docs/ROADMAP.md; then
                            sed -i "s/^${STEP}\\. \\[ \\]/${STEP}. [X]/" docs/ROADMAP.md
                            git add docs/ROADMAP.md 2>/dev/null || true
                            git commit -m "chore: mark step ${STEP} complete in ROADMAP" 2>/dev/null || true
                            git push origin main 2>/dev/null || true
                            log INFO "ROADMAP: step ${STEP} marked [X]"
                        fi
                    fi
                fi

                if [ "$REMAINING" -gt 0 ]; then
                    log INFO "$REMAINING task(s) remaining. Continuing to next task."
                    jq --arg time "$(date -Iseconds)" \
                       '.current_state = "PLAN_WORK" | .last_transition = $time | .last_result = {skill: "merge-prs", verdict: "MERGED_CONTINUING"}' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                else
                    log INFO "All tasks complete. Advancing to verification."
                    jq --arg time "$(date -Iseconds)" \
                       '.current_state = "VERIFY_COMPLETION" | .last_transition = $time | .last_result = {skill: "merge-prs", verdict: "ALL_MERGED"}' \
                       "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                fi
            else
                log ERROR "Merge failure detected. Invoking arbiter."
                BLOCKERS_JSON=$(printf '%s\n' "${MERGE_BLOCKERS[@]}" | jq -R . | jq -s .)

                jq --arg time "$(date -Iseconds)" \
                   --argjson blockers "$BLOCKERS_JSON" \
                   --argjson failures "$MERGE_FAILED" \
                   '.last_result = {skill: "merge-prs", verdict: "MERGE_BLOCKED", blockers: $blockers, failures: $failures} | .last_transition = $time' \
                   "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state

                invoke_arbiter; ARB="$ARBITER_VERDICT"

                case "$ARB" in
                    RETRY)
                        log INFO "Arbiter: RETRY merge."
                        jq --arg time "$(date -Iseconds)" \
                           '.current_state = "MERGE_PRS" | .last_transition = $time | del(.last_result)' \
                           "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                        ;;
                    SKIP)
                        log INFO "Arbiter: SKIP merge failure."
                        git checkout main 2>/dev/null && git pull origin main 2>/dev/null || true
                        if [ "$REMAINING" -gt 0 ]; then
                            log INFO "$REMAINING task(s) remaining. Continuing to next task."
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "PLAN_WORK" | .last_transition = $time | del(.last_result)' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                        else
                            log INFO "No more tasks. Advancing to verification."
                            jq --arg time "$(date -Iseconds)" \
                               '.current_state = "VERIFY_COMPLETION" | .last_transition = $time' \
                               "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
                        fi
                        ;;
                    *)
                        log ERROR "Arbiter: HALT (verdict: $ARB)"
                        exit 1
                        ;;
                esac
            fi
            log_state_summary
            ;;

        # ── VERIFY_COMPLETION: Create handoff document ────────────
        VERIFY_COMPLETION)
            STEP=$(state '.step_number')
            log INFO "Verifying completion for step $STEP"
            dispatch_or_recover "/handoff $STEP" "HANDOFF"
            handle_dispatch_rc $? || continue
            log INFO "Handoff dispatched"
            log_state_summary
            ;;

        # ── HANDOFF: Step complete, reset for next step ───────────
        HANDOFF)
            STEP=$(state '.step_number')
            log_separator "Step $STEP Complete"

            jq '.current_state = "INIT" | del(.last_result)' \
                "$STATE_FILE" > "${STATE_FILE}.tmp" && safe_mv_state
            revision_count=0
            ;;

        *)
            log ERROR "Unknown state: $CURRENT"
            exit 1
            ;;
    esac
done

log_separator "ORDER Loop Complete"
log INFO "Steps run: $step_count"
