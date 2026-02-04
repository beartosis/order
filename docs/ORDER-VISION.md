# ORDER: Optional Resource During Extended Runtimes

**A plugin for CHAOS that enables autonomous, human-free operation.**

---

## Vision

CHAOS (Claude Handling Agentic Orchestration System) is designed with humans in the loop—writing specs, answering questions, resolving disputes. This is intentional: human oversight ensures quality and catches edge cases.

But sometimes you want to let it run.

**ORDER** removes the human element, enabling CHAOS to operate in a self-sustaining loop. It's the difference between supervised and unsupervised execution:

| Mode | Human Role | Use Case |
|------|-----------|----------|
| **CHAOS** | Write specs, answer questions, resolve disputes | Active development, complex features |
| **CHAOS + ORDER** | Queue specs, walk away | Batch processing, overnight runs, CI/CD |

ORDER is **optional** and **additive**—it layers on top of CHAOS without modifying the core framework. Users explicitly opt into autonomous mode.

### Philosophy

> *"From CHAOS comes ORDER"*

- **Explicit opt-in**: ORDER must be installed separately; CHAOS remains human-in-the-loop by default
- **Configurable autonomy**: Users control how aggressive ORDER is (skip failures vs halt)
- **Safety first**: Hard limits on iterations, time, and cost prevent runaway execution
- **Full audit trail**: All autonomous decisions logged to Beads for review
- **Reversible**: Uninstall ORDER to restore standard CHAOS behavior
- **Health before features**: Prioritize codebase quality over new functionality

### Health Before Features

> *"Move slowly and fix things."*

When operating autonomously, ORDER follows a discipline of codebase stewardship. Without human oversight, ORDER must be conservative about what it chooses to work on.

**The Crawl-First Approach**:

1. **Is the codebase healthy?** Analyze for tech debt, test gaps, security issues.
2. **Are existing features solid?** Fix bugs and shore up quality before adding complexity.
3. **Is the foundation stable?** Reduce debt per release, not accumulate it.

**The Improvement Cycle**:

```
┌─────────────────────────────────────────────────────────────┐
│                 ORDER IMPROVEMENT CYCLE                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│    Crawl ──► Identify ──► Fix ──► Crawl ──►                 │
│       │                             │                        │
│       └─── (only when healthy) ─────┴───► New Feature       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**When ORDER proposes new features**:

New feature specs should only be generated when:
- Recent `code-explorer` analysis shows acceptable health score
- Known tech debt is documented and tracked
- Test coverage meets configured thresholds
- Security scan shows no critical issues

This isn't gatekeeping—it's sustainability. ORDER earns the right to add features by first proving the codebase is healthy.

---

## Architecture

### Separate Repository

ORDER lives in its own repository (`CHAOS-ORDER`), installed on top of an existing CHAOS installation:

```
~/CHAOS/           # Core framework (human-in-the-loop)
~/CHAOS-ORDER/     # Plugin (autonomous mode)
```

This separation ensures:
- CHAOS users aren't burdened with autonomous features they don't want
- ORDER can version independently
- Clear boundary between supervised and unsupervised operation

### How ORDER Layers on CHAOS

```
┌─────────────────────────────────────────────────────┐
│                    Your Project                      │
├─────────────────────────────────────────────────────┤
│  .claude/                                            │
│  ├── agents/                                         │
│  │   ├── [CHAOS agents]         ← Original          │
│  │   ├── order-arbiter.md       ← ORDER override    │
│  │   ├── order-oracle.md        ← ORDER addition    │
│  │   └── order-sentinel.md      ← ORDER addition    │
│  ├── skills/                                         │
│  │   ├── [CHAOS skills]         ← Original          │
│  │   ├── loop/                  ← ORDER addition    │
│  │   └── order-status/          ← ORDER addition    │
│  └── settings.local.json        ← Merged hooks      │
├─────────────────────────────────────────────────────┤
│  .CHAOS/                                             │
│  ├── version                    ← CHAOS metadata    │
│  ├── framework_path                                  │
│  └── order/                     ← ORDER metadata    │
│      ├── config.yml                                  │
│      ├── queue.txt                                   │
│      └── state.json                                  │
└─────────────────────────────────────────────────────┘
```

### Escalation Point Interception

CHAOS has three human escalation points. ORDER intercepts all of them:

| Escalation Point | CHAOS Behavior | ORDER Behavior |
|------------------|----------------|----------------|
| **Spec clarification** | `spec-reviewer` asks human via `AskUserQuestion` | `order-oracle` analyzes codebase and decides |
| **Spec creation** | `create-spec` has multi-round conversation with human | `code-explorer` + `order-oracle` generate specs autonomously |
| **Third failure** | `dispute-resolver` escalates to human | `order-arbiter` tries alternative strategies, never escalates |

---

## Components

### Agents

#### `order-arbiter.md` — The Autonomous Dispute Resolver

Replaces `dispute-resolver` with a version that **never escalates to humans**.

**Model**: Sonnet

**Strategies on failure**:
1. **Retry with different approach** — Suggest alternative implementation path
2. **Scope reduction** — Simplify requirements to unblock
3. **Skip and continue** — Mark as unresolvable, move to next spec
4. **Halt** — Stop the loop (if configured)

**Key difference from `dispute-resolver`**:
- No `AskUserQuestion` tool
- Decision logged to Beads for audit
- Configurable max retries before skip/halt

#### `order-oracle.md` — The Autonomous Decision Maker

Handles questions that `spec-reviewer` would ask humans.

**Model**: Sonnet

**How it decides**:
1. Analyzes the codebase for patterns and conventions
2. Looks at similar implementations
3. Makes a reasonable decision based on evidence
4. Documents the decision and rationale in Beads

**Example**:
```
spec-reviewer asks: "Should errors be logged, shown to user, or both?"
order-oracle analyzes: Found ErrorHandler class that logs + shows toast
order-oracle decides: "Both - following existing ErrorHandler pattern"
```

#### `order-sentinel.md` — The Loop Controller

Monitors autonomous execution and enforces safety limits.

**Model**: Haiku (fast, cheap—runs frequently)

**Responsibilities**:
- Track iteration count, elapsed time, estimated cost
- Check safety limits before each spec
- Detect stuck/looping behavior
- Trigger emergency stop if limits exceeded
- Maintain state in `.CHAOS/order/state.json`

### Skills

#### `/loop [spec-name]` — Main Entry Point

The primary ORDER skill. Wraps `/orchestrate` in an autonomous loop.

**Usage**:
```bash
# Process a single spec autonomously
claude /loop 2025-02-03-my-feature

# Process all specs in queue
claude /loop --queue

# Dry run (no changes, just simulate)
claude /loop --dry-run 2025-02-03-my-feature
```

**Flow**:
```
/loop
  │
  ├─► Read queue from .CHAOS/order/queue.txt
  │
  ├─► For each spec:
  │     │
  │     ├─► order-sentinel checks safety limits
  │     │
  │     ├─► /orchestrate [spec] (with ORDER agents)
  │     │     └─► order-oracle answers questions
  │     │     └─► order-arbiter handles failures
  │     │
  │     ├─► Log result to Beads
  │     │
  │     └─► Continue or halt based on config
  │
  └─► Report summary
```

#### `/order-status` — Monitoring

Check the state of an ORDER run.

**Output**:
```
ORDER Status
============
State: RUNNING
Current spec: 2025-02-03-user-auth
Iteration: 7 of 100
Elapsed: 2h 14m of 24h limit
Estimated cost: $12.40 of $50.00 limit
Specs completed: 3
Specs failed: 1
Specs remaining: 2

Recent decisions (order-arbiter):
  - 2025-02-03-api-refactor: SKIP (unresolvable after 5 retries)
  - 2025-02-03-user-auth: RETRY (trying alternative approach)
```

---

## Autonomous Spec Generation

ORDER doesn't just execute pre-written specs—it can generate its own work.

### How ORDER Finds Work

```
┌─────────────────────────────────────────────────────────────┐
│              AUTONOMOUS SPEC GENERATION                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  code-explorer crawls codebase                              │
│         │                                                    │
│         ▼                                                    │
│  Identifies improvement opportunities:                       │
│  ├─ Tech debt hotspots                                      │
│  ├─ Test coverage gaps                                      │
│  ├─ Security concerns                                       │
│  └─ Performance issues                                      │
│         │                                                    │
│         ▼                                                    │
│  order-oracle prioritizes based on:                         │
│  ├─ Severity (critical > high > medium > low)               │
│  ├─ Health-first policy (fixes before features)             │
│  └─ Configuration thresholds                                │
│         │                                                    │
│         ▼                                                    │
│  order-oracle generates spec (no human questions)           │
│         │                                                    │
│         ▼                                                    │
│  Spec added to queue → /loop processes it                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Generation Modes

ORDER supports two modes of operation:

| Mode | Trigger | Work Source |
|------|---------|-------------|
| **Queue mode** | `/loop --queue` | Process human-written specs from queue.txt |
| **Autonomous mode** | `/loop --auto` | Generate specs from codebase analysis |

In autonomous mode, ORDER:
1. Runs `code-explorer` to analyze codebase health
2. Checks health thresholds (see Configuration)
3. If unhealthy: generates improvement specs
4. If healthy: optionally generates feature specs (if configured)
5. Executes generated specs through standard pipeline

### Health Gates

ORDER enforces health requirements before generating new feature specs:

```yaml
# .CHAOS/order/config.yml
autonomous:
  enabled: true

  # Health thresholds (must pass before new features)
  health_gates:
    min_test_coverage: 70          # Percentage
    max_critical_issues: 0         # Security/critical bugs
    max_high_issues: 5             # High-severity tech debt

  # What ORDER can generate
  allow_feature_specs: false       # Only improvements until healthy
  improvement_categories:
    - tech_debt
    - test_coverage
    - security
    - performance
```

When `allow_feature_specs: false`, ORDER focuses exclusively on codebase health. Once thresholds are met, setting `allow_feature_specs: true` allows ORDER to propose enhancements.

### Example: Autonomous Improvement Run

```
$ claude /loop --auto

ORDER Autonomous Mode
=====================
Running code-explorer analysis...

Codebase Health Report:
  Test coverage: 45% (threshold: 70%) ❌
  Critical issues: 0 ✓
  High issues: 12 (threshold: 5) ❌

Health gates NOT met. Generating improvement specs only.

Generated specs:
  1. 2025-02-03-add-auth-tests (test coverage)
  2. 2025-02-03-fix-sql-injection (security)
  3. 2025-02-03-refactor-duplicate-validation (tech debt)

Processing queue...
[ORDER proceeds to execute specs]
```

---

## Configuration

### `.CHAOS/order/config.yml`

```yaml
# Safety limits - hard stops that cannot be exceeded
safety:
  max_iterations: 100          # Stop after N specs processed
  max_time_hours: 24           # Stop after N hours
  max_cost_dollars: 50.00      # Stop after estimated $N spent
  max_consecutive_failures: 10 # Stop after N failures in a row

# Behavior settings
behavior:
  on_unresolvable: skip        # skip | halt
  auto_commit: true            # Commit after each successful spec
  branch_prefix: order/        # Git branch prefix for changes
  dry_run: false               # Simulate without making changes

# Notification (future)
notify:
  on_complete: false
  on_failure: false
  webhook_url: null
```

### `.CHAOS/order/queue.txt`

Simple text file listing specs to process:

```
# Specs to process (one per line)
# Lines starting with # are comments
# Processed specs are removed from queue

2025-02-03-user-authentication
2025-02-03-api-rate-limiting
2025-02-03-dashboard-redesign
```

### `.CHAOS/order/state.json`

Runtime state maintained by `order-sentinel`:

```json
{
  "status": "running",
  "started_at": "2025-02-03T10:00:00Z",
  "current_spec": "2025-02-03-user-auth",
  "iteration": 7,
  "completed": ["2025-02-03-setup", "2025-02-03-models"],
  "failed": ["2025-02-03-api-refactor"],
  "skipped": [],
  "estimated_cost_dollars": 12.40,
  "consecutive_failures": 0
}
```

---

## Installation

### Prerequisites

- CHAOS installed in target project (`.CHAOS/version` exists)
- Beads installed (`bd` command available)

### Installation Flow

```bash
# 1. Clone ORDER repository
git clone https://github.com/beartosis/order.git ~/order

# 2. Navigate to your project (with CHAOS already installed)
cd ~/my-project

# 3. Install ORDER on top
~/order/install.sh
```

**What the installer does**:
1. Verifies CHAOS is installed
2. Backs up existing `dispute-resolver.md`
3. Installs ORDER agents to `.claude/agents/`
4. Installs ORDER skills to `.claude/skills/`
5. Merges ORDER hooks into `settings.local.json`
6. Creates `.CHAOS/order/` directory with default config
7. Runs verification

### Uninstallation

```bash
~/CHAOS-ORDER/uninstall.sh
```

Restores original CHAOS agents and removes ORDER components.

---

## Safety Mechanisms

### 1. Iteration Limits

Hard stop after processing N specs. Prevents infinite loops.

```yaml
safety:
  max_iterations: 100
```

### 2. Time Limits

Hard stop after N hours. Prevents overnight runs from going too long.

```yaml
safety:
  max_time_hours: 24
```

### 3. Cost/Token Limits

Estimated cost tracking based on model usage. Hard stop when limit approached.

```yaml
safety:
  max_cost_dollars: 50.00
```

**Cost estimation**:
- Haiku: ~$0.001 per agent run
- Sonnet: ~$0.01 per agent run
- Opus: ~$0.10 per agent run

### 4. Failure Circuit Breaker

Stop if too many consecutive failures—something is probably wrong.

```yaml
safety:
  max_consecutive_failures: 10
```

### 5. Kill File

Touch this file to immediately halt ORDER:

```bash
touch .CHAOS/order/STOP
```

The `order-sentinel` checks for this file before each iteration.

### 6. Git Branch Safety

All ORDER changes happen on feature branches, never directly on main:

```yaml
behavior:
  branch_prefix: order/
```

Creates branches like `order/2025-02-03-user-auth`.

### 7. Dry Run Mode

Test ORDER without making any actual changes:

```bash
claude /loop --dry-run 2025-02-03-my-feature
```

---

## Repository Structure

```
CHAOS-ORDER/
├── README.md
├── LICENSE
├── install.sh                      # Main installer
├── uninstall.sh                    # Clean removal
├── lib/
│   ├── order_check.sh              # Verify CHAOS installed
│   ├── hooks_merge.sh              # Merge hooks into settings
│   └── cost_estimator.sh           # Token/cost tracking
├── templates/
│   ├── .claude/
│   │   ├── agents/
│   │   │   ├── order-arbiter.md.tmpl
│   │   │   ├── order-oracle.md.tmpl
│   │   │   └── order-sentinel.md.tmpl
│   │   ├── skills/
│   │   │   ├── loop/
│   │   │   │   └── SKILL.md.tmpl
│   │   │   └── order-status/
│   │   │       └── SKILL.md.tmpl
│   │   └── scripts/
│   │       ├── order-checkpoint.sh
│   │       ├── order-log-decision.sh
│   │       └── order-cost-track.sh
│   └── .CHAOS/
│       └── order/
│           ├── config.yml.tmpl
│           └── queue.txt.tmpl
└── docs/
    ├── architecture.md
    ├── safety.md
    └── troubleshooting.md
```

---

## Future Considerations

### Potential Enhancements

1. **Webhook notifications** — Alert on completion/failure
2. **Web dashboard** — Monitor ORDER runs in browser
3. **Spec prioritization** — Process high-priority specs first
4. **Parallel execution** — Run multiple specs concurrently
5. **Learning from failures** — Improve oracle decisions over time

### Integration Points

- **CI/CD**: Run ORDER as part of deployment pipeline
- **Cron**: Schedule overnight ORDER runs
- **GitHub Actions**: Trigger ORDER on new spec PRs

---

## Summary

ORDER transforms CHAOS from a human-supervised system into an autonomous one:

```
CHAOS alone:     Human → Spec → [Questions?] → Human → Execute → [Failure?] → Human
CHAOS + ORDER:   Human → Spec → Queue → ORDER → Execute → Done
ORDER auto:      ORDER → Analyze → Generate Spec → Execute → Repeat
```

ORDER operates in two modes:
- **Queue mode**: Human writes specs, ORDER executes them
- **Autonomous mode**: ORDER analyzes codebase, generates specs, executes them

The "Health Before Features" philosophy ensures ORDER prioritizes codebase quality over new functionality—earning the right to add features by first proving the foundation is solid.

**Remember**: With great automation comes great responsibility. Always review ORDER's decisions in the Beads audit trail, and start with conservative safety limits.
