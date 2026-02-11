# ORDER: Optional Resource During Extended Runtimes

v0.0.2

> Engineering Lead plugin for CHAOS v2. ORDER decomposes specs into PR-sized tasks, executes them sequentially, and manages the full PR lifecycle — rebase, GHA checks, review feedback, and merge.

## How It Works

ORDER acts as an Engineering Lead that drives a CHAOS v2 developer through a roadmap:

```
ROADMAP.md → /parse-roadmap → /create-spec → /review-spec (forked) → /plan-work
    ↓
Task Queue → /work (one task at a time) → MERGE_PRS → next task
    ↓
All tasks complete → /verify-completion → /handoff → Next ORDER instance → Next step
```

Tasks execute **sequentially**: each task is worked, its PR is rebased onto main, GHA checks pass, review feedback is addressed, the PR is merged, and main is pulled before the next task begins. This avoids merge conflicts and ensures each task builds on the fully-integrated result of all previous tasks.

| CHAOS v2 (Single Developer) | ORDER v2 (Engineering Lead) |
|-----------------------------|---------------------------|
| `/work` implements a task | `/plan-work` decomposes specs into tasks |
| `/self-check` pre-push gate | `/create-spec` creates Spec Contracts |
| `/review-feedback` addresses comments | `/loop` manages sequential execution |
| `/learn` captures observations | `/verify-completion` enforces completion gates |

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| [CHAOS v2](https://github.com/beartosis/chaos) | Base framework | `~/chaos/install.sh` |
| [Beads](https://github.com/steveyegge/beads) | Issue tracking (`bd` command) | `go install github.com/steveyegge/beads/cmd/bd@latest` |
| [jq](https://jqlang.github.io/jq/) | JSON processor | `brew install jq` / `apt install jq` |
| [gh](https://cli.github.com/) | GitHub CLI (for PR workflow) | `brew install gh` / `apt install gh` |

## Installation

```bash
# 1. Clone ORDER
git clone https://github.com/beartosis/order.git ~/order

# 2. Navigate to your project (with CHAOS v2 already installed)
cd ~/my-project

# 3. Install ORDER on top of CHAOS v2
~/order/install.sh

# For CI/scripts (no prompts)
~/order/install.sh --force
```

## Usage

### Run Full Lifecycle (Recommended)
```bash
# Run autonomous lifecycle (each skill gets fresh Claude process + context window)
.claude/scripts/order-run-loop.sh

# Limit number of roadmap steps
.claude/scripts/order-run-loop.sh --max-steps 3

# Start from a specific step
.claude/scripts/order-run-loop.sh --start-step 5

# Or invoke from an interactive Claude session
claude /order-run
```

### Decompose a Spec into Tasks
```bash
claude /plan-work specs/my-feature/SPEC.md
```
Creates PR-sized tasks (~400 LOC each) with Beads Issue Contracts. Beads is the sole issue tracker — GitHub Issues are not used.

### Process Tasks
```bash
# Single task
claude /loop my-task-name

# All tasks in queue (sequential, one at a time)
claude /loop --queue
```

### Check Status
```bash
claude /order-status
```

### Roadmap-Driven Development

ORDER reads your project roadmap (`docs/ROADMAP.md`) and autonomously:
1. Extracts the next uncompleted step (`/parse-roadmap`)
2. Creates a detailed Spec Contract from the one-line description (`/create-spec`)
3. Validates the spec in an independent forked context (`/review-spec`)
4. Decomposes the spec into Beads Issue Contracts (`/plan-work`)
5. Executes tasks one at a time, merging each PR before the next begins
6. Verifies all completion gates pass (`/verify-completion`)
7. Commits step artifacts and hands off to a fresh ORDER instance (`/handoff`)

### Contract-Driven Execution

The system uses explicit contracts at every boundary to prevent drift:

- **Authority Matrix**: Each actor has explicit "Owns" and "Must Not Do" columns
- **Self-Validation Invariant**: No actor may validate its own work product
- **Spec Contracts**: Structured specs with In/Out of Scope, Required Interfaces, and testable Acceptance Criteria
- **Beads Issue Contracts**: Tasks mechanically derived from spec acceptance criteria (1-3 max per task)
- **PR Merge Gates**: Auto-generated checklists; merge requires all GHA checks passing
- **Completion Gates**: Binary, machine-verifiable gates before any step is marked complete
- **Handoff Schema**: Structured YAML, not prose — validated on resume
- **Lifecycle State Machine**: Strict state transitions, no skipping, authoritative checkpoint

### Emergency Stop
```bash
touch .chaos/framework/order/STOP
```

## Lifecycle State Machine

ORDER enforces a strict state progression. No states can be skipped.

```
INIT → PARSE_ROADMAP → CREATE_SPEC → REVIEW_SPEC → PLAN_WORK
     → EXECUTE_TASKS → MERGE_PRS → VERIFY_COMPLETION → HANDOFF → next step
```

The **MERGE_PRS** state handles the full PR lifecycle for each task:
1. **Rebase** the PR branch onto current main (GitHub API first, local fallback)
2. **Mark ready** for review (transition from draft)
3. **Poll GHA checks** with configurable timeout
4. **Address review feedback** via `/review-feedback` (up to 5 rounds)
5. **Merge** via `gh pr merge` with configurable method (squash by default)
6. **Pull main** and loop back to PLAN_WORK for the next task

## Configuration

Edit `.chaos/framework/order/config.yml`:

```yaml
safety:
  max_iterations: 100          # Stop after N tasks
  max_time_hours: 24           # Stop after N hours
  max_consecutive_failures: 10 # Stop after N failures in a row
  max_pr_age_hours: 24         # Flag old PRs
  max_concurrent_prs: 10       # PR pipeline limit

pr_workflow:
  order_review: false          # CHAOS handles full PR lifecycle
  gha_wait_timeout_minutes: 30 # How long to wait for GHA checks
  merge_method: squash         # squash | merge | rebase
  delete_branch: true          # Delete branch after merge
  post_merge_learn: true       # Run /learn after merge

task_decomposition:
  target_pr_size_loc: 400      # Target PR size
  max_pr_size_loc: 800         # Maximum PR size

behavior:
  on_unresolvable: skip        # skip | halt
  branch_prefix: task/         # Git branch prefix

orchestrator:
  max_spec_revisions: 3        # Max create-spec/review-spec cycles
  execution_mode: sequential   # Tasks execute one at a time, each merged before the next

roadmap:
  path: docs/ROADMAP.md        # Roadmap file path
  spec_dir: specs/             # Spec output directory
  auto_advance: true           # Auto-advance to next step

contracts:
  spec_contract_required: true    # Enforce Spec Contract format
  completion_gates_required: true # Enforce completion gates
```

## Safety Mechanisms

- **Iteration limits** — stop after N tasks processed
- **Time limits** — stop after N hours
- **Failure circuit breaker** — stop on consecutive failures
- **Kill file** — touch `.chaos/framework/order/STOP` to halt immediately
- **Branch safety** — all changes on `task/*` branches, never main
- **PR pipeline monitoring** — flag stuck or aged PRs
- **GHA review gate** — all checks must pass before merge
- **Arbiter** — automatic failure handler with retry/skip/halt decisions
- **Dry run mode** — simulate without changes

### Security Considerations

ORDER runs with `--dangerously-skip-permissions` to enable autonomous operation:

- Claude can execute commands without per-command approval
- File modifications happen without confirmation prompts
- Git operations (commits, branches, PRs) proceed automatically

**Mitigations:**
- Always run ORDER in isolated environments for untrusted codebases
- Use branch safety (`task/*` branches) to protect main
- GHA must approve before merge
- Set conservative limits in `config.yml`
- Monitor with `/order-status`

## Uninstallation

```bash
~/order/uninstall.sh

# For CI/scripts (no prompts)
~/order/uninstall.sh --force
```

Restores CHAOS v2 standalone single-developer operation.

## Documentation

- [Vision Document](docs/ORDER-VISION.md) — Full architecture and design

## License

MIT — see [LICENSE](LICENSE) file.
