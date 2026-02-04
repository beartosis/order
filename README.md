# ORDER: Optional Resource During Extended Runtimes

**Autonomous operation plugin for CHAOS** · v0.0.1

> **Early Release**: This is an initial release (v0.0.1). APIs and workflows may change as we iterate based on feedback.

ORDER removes the human from the loop, enabling CHAOS to operate autonomously for batch processing, overnight runs, and CI/CD integration.

## Requirements

- [CHAOS](https://github.com/beartosis/chaos) installed in your project
- [Beads](https://github.com/steveyegge/beads) for issue tracking
- `jq` - JSON processor
- `bc` - Calculator for cost estimation

## Installation

```bash
# 1. Clone ORDER
git clone https://github.com/beartosis/order.git ~/order

# 2. Navigate to your project (with CHAOS already installed)
cd ~/my-project

# 3. Install ORDER on top of CHAOS
~/order/install.sh
```

## Usage

### Process a Single Spec
```bash
claude /loop 2025-02-03-my-feature
```

### Process All Specs in Queue
```bash
# Add specs to queue
echo "2025-02-03-feature-1" >> .CHAOS/order/queue.txt
echo "2025-02-03-feature-2" >> .CHAOS/order/queue.txt

# Process queue
claude /loop --queue
```

### Autonomous Mode (Generate & Execute)
```bash
# ORDER analyzes codebase and generates improvement specs
claude /loop --auto
```

### Check Status
```bash
claude /order-status
```

### Emergency Stop
```bash
touch .CHAOS/order/STOP
```

## How It Works

ORDER intercepts CHAOS's human escalation points:

| CHAOS (Human-in-Loop) | ORDER (Autonomous) |
|-----------------------|-------------------|
| `spec-architect` asks human | `order-oracle` decides based on codebase |
| `dispute-resolver` escalates | `order-arbiter` retries or skips |
| Human monitors progress | `order-sentinel` enforces limits |

## Configuration

Edit `.CHAOS/order/config.yml`:

```yaml
safety:
  max_iterations: 100        # Stop after N specs
  max_time_hours: 24         # Stop after N hours
  max_cost_dollars: 50.00    # Stop after $N spent
  max_consecutive_failures: 10

behavior:
  on_unresolvable: skip      # skip | halt
  auto_commit: true
  branch_prefix: order/
```

## Safety Mechanisms

- **Iteration limits** - Stop after N specs processed
- **Time limits** - Stop after N hours
- **Cost limits** - Estimated cost tracking with hard cap
- **Failure circuit breaker** - Stop on consecutive failures
- **Kill file** - Touch `.CHAOS/order/STOP` to halt immediately
- **Branch safety** - All changes on `order/*` branches, never main
- **Dry run mode** - Simulate without changes

## Philosophy

> *"From CHAOS comes ORDER"*

ORDER follows the **Health Before Features** principle:

1. Analyze codebase for tech debt, test gaps, security issues
2. Generate improvement specs
3. Execute and verify
4. Only propose new features when codebase is healthy

## Uninstallation

```bash
~/order/uninstall.sh
```

Restores standard CHAOS human-in-the-loop behavior.

## Documentation

- [Vision Document](docs/ORDER-VISION.md) - Full architecture and design
- [CHAOS Documentation](https://github.com/beartosis/chaos) - Base framework

## License

MIT
