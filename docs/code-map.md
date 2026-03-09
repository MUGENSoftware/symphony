# Code Map

This is a plain-English guide to the important modules. It is meant for engineers who can read code
but do not already know Elixir conventions.

## Read These First

If you want to understand runtime behavior quickly, read in this order:

1. `lib/symphony_elixir/cli.ex`
2. `lib/symphony_elixir/config.ex`
3. `lib/symphony_elixir/orchestrator.ex`
4. `lib/symphony_elixir/agent_runner.ex`
5. `lib/symphony_elixir/workspace.ex`

## Runtime Entry And Supervision

### `SymphonyElixir` / `SymphonyElixir.Application`

What this means:
The thin entrypoint and the OTP application startup module.

Why Symphony needs it:
This is where the service's long-lived children are started under supervision.

Where it lives in code:
`lib/symphony_elixir.ex`

What can go wrong:
if a child fails during startup, the application does not fully boot.

### `SymphonyElixir.CLI`

What this means:
The escript entrypoint invoked by `./bin/symphony`.

Why Symphony needs it:
It turns command-line input into runtime configuration and starts the application.

Where it lives in code:
`lib/symphony_elixir/cli.ex`

What can go wrong:
bad flags, missing workflow file, or missing acknowledgement flag.

## Configuration And Workflow

### `SymphonyElixir.Workflow`

What this means:
Reads `WORKFLOW.md` and splits YAML front matter from the prompt body.

Why Symphony needs it:
The workflow file is the user-facing contract; the rest of the runtime should not parse Markdown.

Where it lives in code:
`lib/symphony_elixir/workflow.ex`

### `SymphonyElixir.WorkflowStore`

What this means:
The in-memory holder for the currently loaded workflow.

Why Symphony needs it:
Long-lived processes need a shared current view of the workflow without reparsing the file on every
call.

### `SymphonyElixir.Config`

What this means:
The normalized configuration facade used by the rest of the system.

Why Symphony needs it:
It hides raw YAML shape, injects defaults, resolves env-backed values, and validates key settings.

Where it lives in code:
`lib/symphony_elixir/config.ex`

## Scheduler And Execution

### `SymphonyElixir.Orchestrator`

What this means:
The scheduler loop and runtime control plane.

Why Symphony needs it:
It decides what to run, when to retry, when to clean up, and what the dashboard should show.

Where it lives in code:
`lib/symphony_elixir/orchestrator.ex`

Read it for:

- poll timing,
- issue dispatch rules,
- worker exit handling,
- retry scheduling,
- running issue reconciliation.

### `SymphonyElixir.AgentRunner`

What this means:
The adapter from one issue to one Claude session lifecycle.

Why Symphony needs it:
It owns workspace prep, prompt construction, Claude turn execution, and continuation turns.

Where it lives in code:
`lib/symphony_elixir/agent_runner.ex`

Read it for:

- turn loop behavior,
- continuation prompt logic,
- issue-state refresh after turns.

### `SymphonyElixir.Workspace`

What this means:
The filesystem safety and hook execution layer.

Why Symphony needs it:
Workspaces must stay inside a trusted root, and repo bootstrap must be scriptable.

Where it lives in code:
`lib/symphony_elixir/workspace.ex`

Read it for:

- workspace path validation,
- lifecycle hooks,
- cleanup behavior.

## Tracker Boundary

### `SymphonyElixir.Tracker`

What this means:
The abstraction layer for issue tracker reads and writes.

Why Symphony needs it:
The orchestrator should depend on a tracker interface, not directly on Linear implementation details.

Where it lives in code:
`lib/symphony_elixir/tracker.ex`

Read it for:

- fetch candidate issues,
- refresh issue states,
- write comments or state updates through adapters.

## Observability

### `SymphonyElixir.StatusDashboard`

What this means:
The terminal renderer for live runtime status.

Why Symphony needs it:
It provides a fast local view of scheduler and worker state without opening a browser.

Where it lives in code:
`lib/symphony_elixir/status_dashboard.ex`

### `SymphonyElixir.HttpServer`

What this means:
The wrapper that starts the Phoenix endpoint when HTTP observability is enabled.

Why Symphony needs it:
It exposes the same runtime state through a web UI and JSON endpoints.

Where it lives in code:
`lib/symphony_elixir/http_server.ex`

## Supporting Docs

- [Architecture Overview](./architecture-overview.md)
- [Elixir For Readers](./elixir-for-readers.md)
- [Logging Best Practices](./logging.md)
- [Claude Code Token Accounting](./token_accounting.md)
