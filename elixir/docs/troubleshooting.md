# Troubleshooting

This guide is organized by symptom. Every section tells you what the failure usually means, where it
comes from, and what to inspect first.

## Symphony Refuses To Start

### Symptom

The CLI exits immediately with a usage message or acknowledgement banner.

### What This Means

The startup contract was not satisfied before the application booted.

### Where It Lives In Code

- `lib/symphony_elixir/cli.ex`

### What To Check

- you passed `--i-understand-that-this-will-be-running-without-the-usual-guardrails`
- the workflow path exists
- `--port` is a non-negative integer
- `--logs-root` is not blank

## "Workflow file not found"

### What This Means

The CLI could not find the path it was asked to load.

### Where It Lives In Code

- `Workflow.load/1`
- `CLI.run/2`

### What To Check

- absolute path vs current working directory
- whether you intended to rely on the default `./WORKFLOW.md`

## "Failed to parse WORKFLOW.md"

### What This Means

The YAML front matter is malformed or decodes to a non-map value.

### Where It Lives In Code

- `lib/symphony_elixir/workflow.ex`
- `lib/symphony_elixir/config.ex`

### What To Check

- front matter opens and closes with `---`
- indentation is valid YAML
- top-level front matter decodes to a map, not a list or scalar

## Poll Loop Runs But No Issues Dispatch

### What This Means

The orchestrator is alive, but one of the dispatch preconditions is failing.

### Where It Lives In Code

- `Orchestrator.maybe_dispatch/1`
- `Config.validate!/0`

### What To Check

- `tracker.kind` is present and supported
- `LINEAR_API_KEY` or `tracker.api_key` is set
- `tracker.project_slug` is present
- `claude.command` is non-empty
- `agent.max_concurrent_agents` is not effectively exhausted by already-running issues

## Workspace Gets Created But Claude Never Does Useful Work

### What This Means

The failure usually happened in a workspace hook or in Claude process startup.

### Where It Lives In Code

- `lib/symphony_elixir/workspace.ex`
- `lib/symphony_elixir/agent_runner.ex`

### What To Check

- `after_create` clones the repository successfully in a brand-new empty directory
- `before_run` commands succeed in that same workspace
- the `claude.command` is available in the hook environment
- hook output in logs for non-zero exit codes or timeouts

## Hook Timeouts Or Hook Failures

### What This Means

The shell command in `hooks.after_create`, `before_run`, `after_run`, or `before_remove` exceeded
its timeout or exited non-zero.

### Where It Lives In Code

- `Workspace.run_hook/4`

### What To Check

- `hooks.timeout_ms` is large enough for repository bootstrap work
- the hook command succeeds when run with `sh -lc` in the workspace directory
- any secret or tool expected by the hook is available in the runtime environment

Important behavior:

- `after_run` and `before_remove` failures are logged but ignored
- `after_create` and `before_run` failures fail the agent run

## Issue Keeps Retrying

### What This Means

The worker task is exiting abnormally, so the orchestrator is applying retry logic.

### Where It Lives In Code

- `orchestrator.ex`
- `agent_runner.ex`

### What To Check

- worker failure logs with `issue_id`, `issue_identifier`, and `session_id`
- whether the issue is actually still in an active state
- whether Claude timeouts or tracker refresh failures are repeating

## Issue Was Closed In Linear But Local Work Kept Running

### What This Means

Symphony only knows to stop when it can refresh tracker state successfully.

### Where It Lives In Code

- running issue reconciliation in `orchestrator.ex`

### What To Check

- tracker API health
- terminal state names in `tracker.terminal_states`
- logs around running issue reconciliation

## Dashboard Is Missing

### What This Means

One of two things is happening:

- the terminal dashboard is disabled, or
- the HTTP dashboard was never enabled.

### Where It Lives In Code

- `Config.observability_*`
- `StatusDashboard`
- `HttpServer`

### What To Check

- `observability.dashboard_enabled` is true for terminal rendering
- `server.port` or CLI `--port` is set for HTTP rendering
- `server.host` is reachable from your browser or local tooling

HTTP routes when enabled:

- `/`
- `/api/v1/state`
- `/api/v1/<issue_identifier>`
- `/api/v1/refresh`

## Logs Are Hard To Interpret

### What This Means

You are looking for issue lifecycle context without the key fields Symphony expects.

### What To Check

- search by `issue_id` and `issue_identifier`
- when Claude is involved, also search by `session_id`

For conventions and expected fields, see [Logging Best Practices](./logging.md).

## Token Totals Look Confusing

### What This Means

Claude reports both live deltas and cumulative totals. They are not interchangeable.

### What To Check

- whether you are looking at a streaming token update or a turn completion payload

For the accounting rules, see [Claude Code Token Accounting](./token_accounting.md).
