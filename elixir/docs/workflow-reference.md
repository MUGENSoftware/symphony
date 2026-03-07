# Workflow Reference

`WORKFLOW.md` is Symphony's main public interface. It combines:

- YAML front matter for runtime configuration
- a Markdown body used as the Claude prompt template

This guide explains the file in plain operational terms.

## File Shape

```md
---
# YAML front matter
---

# Markdown prompt body
```

If the YAML front matter is invalid, or decodes to something other than a map, Symphony treats the
workflow as broken and stops scheduling work.

## What This Means

The front matter answers "how should Symphony run?" The Markdown body answers "what instructions
should Claude follow once an issue is assigned?"

## Why Symphony Needs It

The runtime is generic. `WORKFLOW.md` is what makes the same scheduler work for your repository,
your issue states, your workspace bootstrap process, and your Claude policy settings.

## Where It Lives In Code

- Workflow parsing: `lib/symphony_elixir/workflow.ex`
- Validation and defaults: `lib/symphony_elixir/config.ex`
- CLI path selection: `lib/symphony_elixir/cli.ex`

## What Can Go Wrong

- missing file: CLI exits with `Workflow file not found`
- malformed YAML: validation fails and polling stops
- valid YAML but missing required runtime fields: the orchestrator logs the specific missing field
- hook commands that succeed locally but fail in a fresh workspace: worker startup fails

## Required And Optional Sections

### `tracker`

What this means:
Connects Symphony to the issue source.

Why Symphony needs it:
The orchestrator polls the tracker to find work and re-check issue state after Claude turns finish.

Where it lives in code:
`Config.tracker_kind/0`, `Tracker`, and the Linear adapter boundary.

Fields:

- `kind`
  - required
  - supported values: `linear`, `memory`
  - default: none
- `endpoint`
  - optional
  - default: `https://api.linear.app/graphql`
- `api_key`
  - optional in the file if `LINEAR_API_KEY` exists
  - if unset, Symphony reads `LINEAR_API_KEY`
  - if set to `$LINEAR_API_KEY`, Symphony resolves that env var explicitly
- `project_slug`
  - required for `kind: linear`
  - no default
- `assignee`
  - optional
  - may be set to `$LINEAR_ASSIGNEE`
- `active_states`
  - optional
  - default: `["Todo", "In Progress"]`
- `terminal_states`
  - optional
  - default: `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`

Example:

```yaml
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "platform"
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Closed
    - Duplicate
```

### `polling`

What this means:
Controls how often Symphony checks for work.

Why Symphony needs it:
Polling too slowly delays work pickup. Polling too quickly increases external API traffic and noise.

Where it lives in code:
`Config.poll_interval_ms/0`, `Orchestrator`.

Fields:

- `interval_ms`
  - optional
  - default: `30000`

### `workspace`

What this means:
Defines where isolated issue directories are created.

Why Symphony needs it:
Each issue gets its own filesystem root so Claude can work in parallel without cross-contamination.

Where it lives in code:
`Config.workspace_root/0`, `Workspace`.

Fields:

- `root`
  - optional
  - default: `<system tmp>/symphony_workspaces`
  - supports `~`
  - supports `$VAR` resolution before path expansion

Example:

```yaml
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
```

### `hooks`

What this means:
Shell commands Symphony runs around workspace lifecycle events.

Why Symphony needs it:
Symphony creates empty directories; hooks are how you clone a repo, install dependencies, or clean up
before removal.

Where it lives in code:
`Config.workspace_hooks/0`, `Workspace.run_hook/4`.

Fields:

- `after_create`
  - optional
  - runs only when Symphony creates a new workspace directory
- `before_run`
  - optional
  - runs before each Claude execution attempt
- `after_run`
  - optional
  - runs after each Claude execution attempt
  - failures are logged and ignored
- `before_remove`
  - optional
  - runs before a workspace is deleted
  - failures are logged and ignored
- `timeout_ms`
  - optional
  - default: `60000`

Important behavior:

- hooks run with `sh -lc` in the workspace directory
- non-zero exit codes fail the hook
- hook output is logged, truncated for log safety
- workspace paths are validated to stay under `workspace.root`

### `agent`

What this means:
Controls scheduler concurrency and continuation behavior.

Why Symphony needs it:
The orchestrator may find more candidate issues than you want to run at once.

Where it lives in code:
`Config.max_concurrent_agents/0`, `Config.agent_max_turns/0`, `Orchestrator`, `AgentRunner`.

Fields:

- `max_concurrent_agents`
  - optional
  - default: `10`
- `max_turns`
  - optional
  - default: `20`
  - this is the per-agent continuation cap used by Symphony's own loop
- `max_retry_backoff_ms`
  - optional
  - default: `300000`
- `max_concurrent_agents_by_state`
  - optional
  - default: `{}`
  - map of state name to positive integer limit
  - state names are normalized case-insensitively before lookup

### `claude`

What this means:
Controls how Symphony launches Claude Code.

Why Symphony needs it:
Symphony is responsible for process orchestration, not Claude CLI defaults. This section is how you
set the command, model, timeouts, and permission behavior.

Where it lives in code:
`Config.claude_*`, `AgentRunner`, Claude CLI wrapper modules.

Fields:

- `command`
  - required in practice
  - default: `claude --output-format stream-json`
  - parsed as an executable plus arguments and launched directly
  - bare executables such as `claude` are resolved from the runtime `PATH`, with a login-shell
    fallback for PATH initialization
  - absolute paths are the most deterministic option
- `model`
  - optional
  - default: `nil`
- `output_format`
  - optional
  - default: `stream-json`
- `approval_policy`
  - optional
  - default:

```json
{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}
```

- `thread_sandbox`
  - optional
  - default: `workspace-write`
  - supported values documented in the current README and validated in code
- `turn_sandbox_policy`
  - optional
  - default: generated `workspaceWrite` policy rooted at the current issue workspace
- `dangerously_skip_permissions`
  - optional
  - default: `false`
- `permission_mode`
  - optional
  - default: `nil`
- `allowed_tools`
  - optional
  - default: `nil`
- `append_system_prompt`
  - optional
  - default: `nil`
- `mcp_config`
  - optional
  - default: `nil`
  - advanced override for a custom Claude MCP config file
  - if omitted for `tracker.kind: linear` in `stream-json` mode, Symphony generates a default MCP
    config for the blessed official Linear MCP server
  - when set, the file must exist, be readable, and contain valid JSON
- `max_turns`
  - optional
  - default: `nil`
  - this is a Claude CLI setting, separate from `agent.max_turns`
- `read_timeout_ms`
  - optional
  - default: `5000`
- `turn_timeout_ms`
  - optional
  - default: `3600000`
- `stall_timeout_ms`
  - optional
  - default: `300000`

Important distinction:

- `agent.max_turns` controls how many back-to-back Claude turns Symphony will continue for one
  active issue before handing control back to the orchestrator.
- `claude.max_turns` is passed through to Claude CLI behavior.

### `observability`

What this means:
Controls terminal dashboard refresh behavior.

Why Symphony needs it:
The dashboard is the fastest way to see whether the scheduler is idle, polling, or actively running
workers.

Where it lives in code:
`Config.observability_*`, `StatusDashboard`.

Fields:

- `dashboard_enabled`
  - optional
  - default: `true`
- `refresh_ms`
  - optional
  - default: `1000`
- `render_interval_ms`
  - optional
  - default: `16`

### `server`

What this means:
Controls the optional HTTP dashboard and JSON API.

Why Symphony needs it:
The terminal dashboard is useful locally, but the HTTP surface is easier to inspect remotely or to
integrate with simple tooling.

Where it lives in code:
`Config.server_port/0`, `Config.server_host/0`, `HttpServer`.

Fields:

- `port`
  - optional
  - default: `nil` (disabled)
  - can be overridden by CLI `--port`
- `host`
  - optional
  - default: `127.0.0.1`

When enabled, the server exposes:

- `/`
- `/api/v1/state`
- `/api/v1/<issue_identifier>`
- `/api/v1/refresh`

## Prompt Body

The Markdown body is rendered as the prompt template used for Claude turns. It supports issue data
such as:

- `issue.identifier`
- `issue.title`
- `issue.description`

If the prompt body is blank, Symphony uses a built-in default prompt template.

## CLI Overrides

Runtime entrypoint:

```bash
./bin/symphony [path-to-WORKFLOW.md]
```

Supported CLI flags:

- `--logs-root <path>`
- `--port <port>`
- `--i-understand-that-this-will-be-running-without-the-usual-guardrails`

CLI behavior:

- workflow path omitted: uses `./WORKFLOW.md`
- `--port` overrides `server.port`
- `--logs-root` changes the log root without editing the workflow file

## Recommended Authoring Pattern

Keep the workflow file focused on:

- tracker configuration,
- workspace bootstrap,
- Claude safety and timeout settings,
- the prompt contract for your repository.

Move repository-specific long instructions into the prompt body instead of trying to encode them as
YAML settings.

For runtime behavior after startup, see [Operations Guide](./operations.md). For startup and first
run instructions, see [Getting Started](./getting-started.md).
