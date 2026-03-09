# Getting Started

This guide is for operators who want to run Symphony without first learning Elixir.

## What This Means

Symphony is a background service. You start it once, and it keeps polling Linear for work. For each
eligible issue, it creates an isolated workspace, runs Claude Code there, and tracks progress until
the issue becomes terminal or requires human review.

## Why Symphony Needs This

The runtime is deliberately split into:

- a long-lived scheduler,
- short-lived per-issue Claude worker sessions,
- a workflow file that tells the runtime how to prepare a workspace and how Claude should behave.

That separation lets Symphony run multiple issues in parallel while keeping each issue isolated.

## Where It Lives In Code

- Startup and CLI entrypoint: `lib/symphony_elixir/cli.ex`
- Workflow loading and validation: `lib/symphony_elixir/workflow.ex`, `lib/symphony_elixir/config.ex`
- Scheduler loop: `lib/symphony_elixir/orchestrator.ex`
- Per-issue execution: `lib/symphony_elixir/agent_runner.ex`
- Workspace management: `lib/symphony_elixir/workspace.ex`

## What Can Go Wrong

- Missing `LINEAR_API_KEY`: Symphony starts but will refuse to poll Linear.
- Missing or invalid `WORKFLOW.md`: startup and scheduling halt until fixed.
- Broken workspace hooks: issue execution fails before Claude can do useful work.
- Wrong Claude command or permissions: worker sessions start and fail immediately.

## Prerequisites

- [mise](https://mise.jdx.dev/) installed
- Linear personal API key exported as `LINEAR_API_KEY`
- access to the repository your `after_create` hook will clone
- Claude Code CLI installed and reachable from the command configured in `WORKFLOW.md`

Install the runtime toolchain:

```bash
mise install
mise exec -- elixir --version
```

## First Run

From the repository root:

```bash
./scripts/setup-git-hooks.sh
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
LINEAR_API_KEY=lin_api_xxx \
  mise exec -- ./bin/symphony \
  ./WORKFLOW.md
```

If you want the web dashboard:

```bash
LINEAR_API_KEY=lin_api_xxx \
  mise exec -- ./bin/symphony \
  --port 4000 \
  ./WORKFLOW.md
```

The Git hook setup is a one-time step. It installs a repo-managed `pre-commit` hook that formats
only staged `*.ex` and `*.exs` files, then re-stages those files automatically.

## Minimal Workflow File

```md
---
tracker:
  kind: linear
  project_slug: "your-linear-project-slug"
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
claude:
  command: claude --output-format stream-json
  # Optional advanced override for a custom Claude MCP config file.
  # If omitted, Symphony generates a default Linear MCP config.
  # mcp_config: /absolute/path/to/custom-claude.mcp.json
---

You are working on Linear issue {{ issue.identifier }}.
```

Notes:

- `tracker.kind` must currently be `linear` or `memory`.
- `tracker.project_slug` is required for `linear`.
- `hooks.after_create` is how a fresh workspace gets the target repository contents.
- `claude.command` must be a non-empty executable command string.

## Required Environment Variables

- `LINEAR_API_KEY`: required for `tracker.kind: linear` unless your workflow injects `tracker.api_key`
- `LINEAR_ASSIGNEE`: optional shortcut if you use `tracker.assignee: $LINEAR_ASSIGNEE`

Linear integration behavior:

- In the default `stream-json` path, Symphony generates a Claude MCP config for the blessed
  official Linear MCP server automatically.
- You only need to provide Linear credentials for the default path.
- `claude.mcp_config` is an advanced override for teams that want a custom MCP config.

Path and env behavior:

- `workspace.root` supports `~` expansion.
- `workspace.root` also supports `$VAR`, which is resolved before path handling.
- `claude.command` is parsed into an executable plus arguments and launched directly, not via
  `sh -lc`.
- A bare executable like `claude` is resolved from the current `PATH`, with a login-shell
  fallback to pick up user PATH initialization when needed.
- Absolute paths remain the most deterministic option for `claude.command`.

## What You Should Expect To See

On a healthy start:

- the CLI accepts the workflow path,
- the application supervisor starts,
- the orchestrator begins polling,
- terminal status output starts refreshing,
- logs appear under `./log` unless you override `--logs-root`.

Important log files:

- `./log/symphony.jsonl` for general runtime lifecycle
- `./log/linear-pull.jsonl` for Linear fetch attempts, returned issue identifiers, pagination, and
  fetch failures
- `./log/claude/<issue_identifier>/*.jsonl` for Claude session artifacts
- `./log/claude.mcp.json` for the generated default Claude MCP config when `claude.mcp_config` is
  not set

If `--port` or `server.port` is set:

- the dashboard becomes available at `/`
- JSON endpoints become available at:
  - `/api/v1/state`
  - `/api/v1/<issue_identifier>`
  - `/api/v1/refresh`

## Recommended First Validation

Use a small Linear project with a single safe issue and confirm:

1. Symphony sees the issue during a poll cycle.
2. A workspace directory appears under `workspace.root`.
3. Your `after_create` hook clones the repository successfully.
4. Claude starts in that workspace.
5. Logs and dashboard reflect the active run.

For the full workflow file surface, see [Workflow Reference](./workflow-reference.md). For runtime
behavior, see [Operations Guide](./operations.md).
