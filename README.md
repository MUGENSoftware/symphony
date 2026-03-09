# Symphony

Symphony is an Elixir service that turns Linear issues into autonomous Claude Code sessions. It
polls a Linear project for work, creates isolated per-issue workspaces, runs Claude Code in each
one, and tracks progress until the issue reaches a terminal state or needs human review.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work
and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI
status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents
land the PR safely. Engineers manage the work at a higher level instead of supervising Claude Code
directly._

> [!WARNING]
> Symphony is an engineering preview for testing in trusted environments.

## How It Works

1. The **Orchestrator** polls Linear on a fixed interval for eligible issues.
2. For each issue, it creates an isolated **workspace** directory and runs a configurable hook
   (typically `git clone`) to bootstrap the repo.
3. An **Agent Runner** launches Claude Code inside that workspace with a prompt built from
   [`WORKFLOW.md`](WORKFLOW.md).
4. Claude has access to Linear via MCP (auto-configured) and works the issue through its lifecycle.
5. A **terminal dashboard** and optional **web dashboard** (Phoenix LiveView) show live status,
   active workers, and token usage.

See [Architecture Overview](docs/architecture-overview.md) for the full component map and sequence
diagrams.

## Quick Start

### Prerequisites

- [mise](https://mise.jdx.dev/) for toolchain management (Elixir 1.19+ / OTP 28)
- A Linear personal API key exported as `LINEAR_API_KEY`
- Claude Code CLI installed and on your `PATH`
- Access to the repository your `after_create` hook will clone

### Build and Run

```bash
# Install toolchain and dependencies
mise install
mise exec -- mix setup

# Build the escript
mise exec -- mix build

# Run Symphony
LINEAR_API_KEY=lin_api_xxx \
  mise exec -- ./bin/symphony \
  ./WORKFLOW.md
```

To enable the web dashboard, add `--port 4000`.

For the complete operator guide, see [Getting Started](docs/getting-started.md).

## Configuration

All runtime behaviour is driven by [`WORKFLOW.md`](WORKFLOW.md), a Markdown file with YAML front
matter that defines:

- **Tracker** settings (Linear project slug, polling interval, assignee filters)
- **Workspace** root directory and lifecycle hooks
- **Claude** command, model, MCP config, concurrency limits, and max turns
- **Prompt template** (Liquid/Jinja2-style) rendered per issue

See the [Workflow Reference](docs/workflow-reference.md) for the full configuration surface.

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](docs/getting-started.md) | Operator guide for first run and minimal setup |
| [Architecture Overview](docs/architecture-overview.md) | System components, data flow, and sequence diagrams |
| [Workflow Reference](docs/workflow-reference.md) | Complete WORKFLOW.md configuration reference |
| [Code Map](docs/code-map.md) | Module-by-module guide for contributors |
| [Elixir for Readers](docs/elixir-for-readers.md) | Elixir/OTP concepts for non-Elixir developers |
| [Operations](docs/operations.md) | Runtime operations and troubleshooting |
| [Logging](docs/logging.md) | Structured logging conventions |
| [Token Accounting](docs/token_accounting.md) | Claude token usage and limits |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and solutions |
| [Specification](SPEC.md) | Language-agnostic Symphony service specification |

## Contributor Setup

After cloning, install the repo-managed Git hook once:

```bash
./scripts/setup-git-hooks.sh
```

The pre-commit hook formats only staged `*.ex` and `*.exs` files, then re-stages those files so
commits include the formatter output automatically.

Run the full quality gate locally:

```bash
make all
```

This runs formatting checks, Credo linting (strict), the test suite with coverage (85% threshold),
and Dialyzer type checking.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
