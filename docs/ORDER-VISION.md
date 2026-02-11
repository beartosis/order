# ORDER: Optional Resource During Extended Runtimes

**An Engineering Lead plugin for CHAOS v2 that manages task-based autonomous execution with PR lifecycle.**

---

## Vision

CHAOS v2 treats each Claude Code conversation as a single professional developer. This developer reads tasks, explores code, implements changes, self-checks quality, and pushes draft PRs.

ORDER v2 is the Engineering Lead who manages these developers.

**ORDER** decomposes specs into PR-sized tasks, spawns CHAOS `/work` instances to implement them, reviews the resulting PRs, coordinates with GitHub Actions for automated review, and handles the merge lifecycle.

| Mode | Developer Role | Lead Role |
|------|---------------|-----------|
| **CHAOS v2 alone** | Human gives tasks, reviews PRs | Human is the lead |
| **CHAOS v2 + ORDER** | CHAOS `/work` implements tasks | ORDER manages lifecycle |

### Philosophy

> *"From CHAOS comes ORDER"*

- **Explicit opt-in**: ORDER must be installed separately; CHAOS v2 remains standalone by default
- **Task-based decomposition**: Specs break into ~400 LOC PR-sized tasks
- **Dual review gate**: Both ORDER and GHA must approve before merge
- **Self-reinforcing learning**: Post-merge `/learn` captures observations for future tasks
- **Safety first**: Hard limits on iterations, time, PR pipeline depth
- **Full audit trail**: All decisions logged to Beads and PR comments
- **Reversible**: Uninstall ORDER to restore standalone CHAOS v2

### Health Before Features

> *"Move slowly and fix things."*

When operating autonomously, ORDER follows a discipline of codebase stewardship:

1. **Is the codebase healthy?** Analyze for tech debt, test gaps, security issues.
2. **Are existing features solid?** Fix bugs and shore up quality before adding complexity.
3. **Is the foundation stable?** Reduce debt per release, not accumulate it.

---

## Architecture

### Separate Repository

ORDER lives in its own repository, installed on top of an existing CHAOS v2 installation:

```
~/chaos/           # Core framework (single-developer paradigm)
~/order/           # Plugin (Engineering Lead)
```

### How ORDER Layers on CHAOS v2

```
+-----------------------------------------------------+
|                    Your Project                      |
+-----------------------------------------------------+
|  .claude/                                            |
|  +-- skills/                                         |
|  |   +-- [CHAOS v2 skills]   <-- work, self-check,  |
|  |   |                           learn, review-      |
|  |   |                           feedback, etc.      |
|  |   +-- plan-work/          <-- ORDER skills        |
|  |   +-- loop/                                       |
|  |   +-- parallel/                                   |
|  |   +-- work-wrapper/                               |
|  |   +-- order-status/                               |
|  |   +-- order-oracle/       <-- Internal (forked)   |
|  |   +-- order-arbiter/      <-- Internal (forked)   |
|  |   +-- parse-roadmap/      <-- Roadmap skills      |
|  |   +-- create-spec/                                |
|  |   +-- review-spec/        <-- Forked context      |
|  |   +-- verify-completion/  <-- Verification        |
|  |   +-- handoff/            <-- Lifecycle            |
|  |   +-- order-resume/                               |
|  |   +-- index.yml           <-- Merged (ORDER-      |
|  |                               START/END markers)  |
|  +-- scripts/                                        |
|  |   +-- sentinel-check.sh   <-- Safety scripts      |
|  |   +-- post-task-hook.sh                           |
|  +-- settings.local.json     <-- From CHAOS v2       |
+-----------------------------------------------------+
|  .chaos/                                              |
|  +-- framework/              <-- CHAOS metadata       |
|  |   +-- version                                      |
|  |   +-- framework_path                               |
|  |   +-- order/              <-- ORDER metadata       |
|  |   |   +-- version                                  |
|  |   |   +-- config.yml                               |
|  |   |   +-- queue.txt                                |
|  |   |   +-- state.json     <-- Lifecycle state       |
|  |   |   +-- installed                                |
|  |   |   +-- framework_path                           |
|  |   |   +-- handoffs/      <-- Handoff documents     |
|  |   |       +-- step-N_HANDOFF.yml                   |
|  |   +-- runs/              <-- Per-task run dirs     |
|  |       +-- <task-id>/                               |
|  |           +-- status.json                          |
|  |           +-- output.log                           |
|  |           +-- pr_number                            |
|  +-- learnings.md            <-- CHAOS v2 learning    |
|  +-- learnings-archive/          system               |
+-------------------------------------------------------+
```

---

## Components

### Skills

#### `/plan-work <spec>` - Spec Decomposition

Breaks a spec into PR-sized tasks:
1. Read spec and project standards
2. Explore codebase for context
3. Decompose into ~400 LOC tasks
4. Create Beads + GitHub issues per task
5. Write task queue with wave metadata
6. Output summary table

#### `/loop [task-id | --queue | --auto]` - Sequential Execution

Main entry point. For each task:
1. Sentinel safety check
2. Spawn `claude -p "/work <task-id>"`
3. `/review-pr <PR#>` after /work completes
4. Wait for GHA review
5. Handle feedback if needed (spawn `/review-feedback`)
6. Merge PR
7. Post-merge `/learn`
8. Record result, continue

#### `/parallel [--queue | --auto]` - Wave-Based Execution

Parallel task execution respecting dependencies:
1. Parse wave metadata from task queue
2. For each wave: spawn all tasks simultaneously
3. After wave: batch review, handle failures, batch merge
4. Batch learn from all merged PRs
5. Continue to next wave

#### `/work-wrapper <task-id>` - Instance Manager (Internal)

Thin wrapper for `/parallel` spawned instances:
1. Write initial status.json
2. Invoke CHAOS `/work`
3. Extract PR number
4. Write final status.json

#### `/order-status` - Monitoring

Displays: task progress, PR pipeline table, agent decisions, health checks.

### Internal Skills (Forked Context)

#### `/order-oracle` - Autonomous Decision Maker

**Model**: Sonnet | **Context**: Fork | **User-Invocable**: No

Handles questions during execution:
- Analyzes codebase patterns and project learnings
- Makes evidence-based decisions
- Assists `/plan-work` with task sizing
- Documents decisions in Beads

#### `/order-arbiter` - Failure Handler

**Model**: Sonnet | **Context**: Fork | **User-Invocable**: No

Handles task failures:
- RETRY: Different approach with guidance
- REDUCE_SCOPE: Simplify task
- SKIP: Move to next task
- HALT: Stop execution
- PR-aware: factors in review state, GHA results

### Roadmap Skills

#### `/parse-roadmap` - Extract Next Step
Reads `docs/ROADMAP.md`, finds first uncompleted `[ ]` step, extracts step number/title/description/complexity. Validates lifecycle state machine.

#### `/create-spec` - Spec Contract Generation
Expands a one-line roadmap step into a full Spec Contract. Explores codebase, reads standards and learnings, invokes `/order-oracle` for ambiguous decisions. Writes to `specs/step-{N}-{slug}/SPEC.md`.

#### `/review-spec` - Spec Contract Validation
**Context**: Fork (self-validation invariant)

Reviews Spec Contract for completeness, feasibility, and quality. Validates all 10 required sections, checks content quality, verifies codebase references, and assesses feasibility. Returns READY or NEEDS_REVISION.

### Verification & Lifecycle Skills

#### `/verify-completion` - Completion Gate Enforcement
Verifies 5 BLOCKING gates (Issues Closed, PRs Merged, Acceptance Criteria, Tests Pass, No GHA Warnings) + 1 ADVISORY gate (Out-of-Scope Clean). All binary and machine-verifiable.

#### `/handoff` - ORDER-to-ORDER Transfer
Creates structured YAML handoff document for ORDER instance transition. Captures decisions, outcomes, and next intent. No narrative prose, no PIDs.

#### `/order-resume` - Resume from Handoff
Validates handoff schema, verifies previous step complete, reads learnings, updates state to INIT, auto-invokes `/parse-roadmap`.

---

## Lifecycle State Machine

ORDER's progression follows a strict state machine. Transitions must not be skipped.

```
INIT → PARSE_ROADMAP → CREATE_SPEC → REVIEW_SPEC → PLAN_WORK → EXECUTE_TASKS → VERIFY_COMPLETION → HANDOFF → EXIT
```

Each skill maps to one or more states. The state machine is tracked in `.chaos/framework/order/state.json`, which is the **authoritative** checkpoint for lifecycle progress.

### Authority & Responsibility Matrix

| Actor | Owns | Must Not Do |
|-------|------|-------------|
| **Human** | Vision, Roadmap, Constraints | Write code, review PRs |
| **ORDER** | Planning, Specs, Sequencing, Progression | Read PR diffs, review code |
| **CHAOS** | Implementation, PR iteration, Merge | Change scope, reinterpret specs |
| **Claude GHA** | Correctness, Tests, Style, Spec Adherence | Make architectural decisions |

### Self-Validation Invariant

> **No actor may validate its own work product.**

| Work Product | Created By | Validated By | Enforcement |
|---|---|---|---|
| Spec Contract | `/create-spec` | `/review-spec` (forked context) | `context: fork` |
| Implementation | CHAOS `/work` | Claude GHA | Separate actor |
| Merge readiness | CHAOS `/pr-monitor` | Claude GHA approval gate | External approval |
| Spec intent | ORDER | Claude GHA (adherence check) | GHA rejects violations |

---

## Complete Workflow

```
1. ORDER starts, reads docs/ROADMAP.md
   STATE: INIT → PARSE_ROADMAP

2. Identifies next uncompleted step (first [ ] checkbox)
   /parse-roadmap extracts step details

3. /create-spec expands step into full Spec Contract
   STATE: PARSE_ROADMAP → CREATE_SPEC

4. /review-spec validates spec completeness (forked context)
   STATE: CREATE_SPEC → REVIEW_SPEC

5. /plan-work decomposes spec into Beads Issue Contracts
   STATE: REVIEW_SPEC → PLAN_WORK

6. Creates Beads issues, writes task queue
   STATE: PLAN_WORK → EXECUTE_TASKS

7. /loop or /parallel spawns CHAOS instances:
   claude -p "/work <task-id>"

8. CHAOS: implement → /self-check → push PR → /pr-monitor → merge → /learn

9. ORDER polls Beads checking task completion
   STATE: EXECUTE_TASKS → VERIFY_COMPLETION

10. /verify-completion checks all completion gates

11. /handoff creates structured YAML for next ORDER instance
    STATE: VERIFY_COMPLETION → HANDOFF → EXIT

12. New ORDER: /order-resume → INIT → next step
```

---

## Configuration

### `.chaos/framework/order/config.yml`

```yaml
safety:
  max_iterations: 100
  max_time_hours: 24
  max_consecutive_failures: 10
  max_pr_age_hours: 24
  max_concurrent_prs: 10

pr_workflow:
  order_review: true
  gha_wait_timeout_minutes: 30
  merge_method: squash
  delete_branch: true
  post_merge_learn: true

task_decomposition:
  target_pr_size_loc: 400
  max_pr_size_loc: 800

behavior:
  on_unresolvable: skip
  auto_commit: true
  branch_prefix: task/
  dry_run: false

roadmap:
  path: docs/ROADMAP.md
  spec_dir: specs/
  auto_advance: true

contracts:
  spec_contract_required: true
  completion_gates_required: true

lifecycle:
  enforce_state_machine: true
  state_file: .chaos/framework/order/state.json

handoff:
  enabled: true
  handoff_dir: .chaos/framework/order/handoffs/
```

---

## Safety Mechanisms

### 1. Iteration Limits
Stop after processing N tasks.

### 2. Time Limits
Stop after N hours of execution.

### 3. Failure Circuit Breaker
Stop if too many consecutive failures.

### 4. Kill File
```bash
touch .chaos/framework/order/STOP
```

### 5. PR Pipeline Health
Sentinel monitors for stuck PRs, too many concurrent PRs, and GHA bottlenecks.

### 6. Branch Safety
All changes on `task/*` branches, never directly on main.

### 7. Dual Review Gate
GHA must approve via CHAOS `/pr-monitor` before merge.

### 8. Dry Run Mode
```bash
claude /loop --dry-run my-task
```

---

## v1 to v2 Migration

| v1 | v2 |
|----|-----|
| Spec-based orchestration | Task-based decomposition |
| `/orchestrate <spec>` | `/work <task-id>` (CHAOS) |
| `dispute-resolver` replaced | No dispute-resolver in CHAOS v2 |
| `code-explorer` for analysis | Oracle reads learnings + codebase |
| Spec queue (one per line) | Task queue with wave metadata |
| `order/*` branches | `task/*` branches |
| No PR lifecycle | Full PR lifecycle (review, GHA, merge) |
| No post-work learning | Post-merge `/learn` on every task |

---

## Summary

ORDER v2 transforms CHAOS v2 from a supervised single-developer into a managed team:

```
CHAOS v2 alone:  Human -> Task -> /work -> Draft PR -> Human reviews -> Merge
CHAOS + ORDER:   Roadmap -> /parse-roadmap -> /create-spec -> /plan-work -> /loop -> /work -> /pr-monitor -> GHA -> Merge -> /learn
```

The Engineering Lead manages the full lifecycle while respecting safety limits and maintaining a complete audit trail in Beads.
