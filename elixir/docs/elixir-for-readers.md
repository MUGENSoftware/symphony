# Elixir For Readers

This is not a general Elixir tutorial. It is the minimum project-specific primer needed to read this
codebase confidently.

## The Mental Model

If you already know services written in Go, Rust, Java, or Node, map the main Elixir ideas like
this:

- `Application` = service startup entrypoint
- `Supervisor` = process tree manager for long-lived components
- `GenServer` = stateful service object that handles messages serially
- `Task` = lightweight async worker
- module = namespace plus functions, roughly comparable to a file-scoped service or utility type

The main adjustment is that state is immutable, so long-lived components keep current state inside a
process loop instead of mutating shared objects.

## `Application` And Supervision

### What This Means

The runtime starts one application that launches its long-lived children under a supervisor.

### Why Symphony Needs It

Symphony is a scheduler with multiple supporting services. Supervision gives it a structured process
tree instead of ad hoc thread management.

### Where It Lives In Code

- `lib/symphony_elixir.ex`

### What Can Go Wrong

- if a child cannot start cleanly, the app does not reach a healthy running state

## `GenServer`

### What This Means

A `GenServer` is a process that owns state and reacts to messages one at a time.

### Why Symphony Needs It

The orchestrator and status dashboard are stateful services that need serialized updates:

- the orchestrator tracks running issues, retries, token totals, and next poll timing
- the dashboard tracks rendering cadence and snapshot state

### Where It Lives In Code

- `lib/symphony_elixir/orchestrator.ex`
- `lib/symphony_elixir/status_dashboard.ex`
- `lib/symphony_elixir/http_server.ex`

### What Can Go Wrong

- blocking work inside a GenServer makes the service unresponsive
- that is why expensive work is pushed into tasks or child processes

## `Task`

### What This Means

A `Task` is the lightweight process used for asynchronous work.

### Why Symphony Needs It

Claude execution and hook execution can block. The orchestrator must stay responsive while those run.

### Where It Lives In Code

- worker tasks started from the orchestrator
- hook execution in `workspace.ex`

### What Can Go Wrong

- if a task crashes, the orchestrator receives an exit signal or monitor message and schedules a
  retry

## Pattern Matching And Multiple Function Heads

### What This Means

Elixir often defines several versions of the same function that match different shapes of input.

### Why Symphony Needs It

This codebase uses that style heavily for:

- message handling in `handle_info`
- option parsing branches
- issue-state helpers

### Where It Lives In Code

- `cli.ex`
- `orchestrator.ex`
- `agent_runner.ex`

### What Can Go Wrong

- if you miss a later function head, you can misunderstand the real control flow

## Immutable State

### What This Means

State is replaced, not mutated in place. You will often see a local variable rebound to a new map or
struct after each transformation.

### Why Symphony Needs It

The orchestrator state is updated step by step on every message:

- refresh config
- update running entries
- adjust retry bookkeeping
- notify dashboard

### Where It Lives In Code

- `Orchestrator.State`
- `StatusDashboard` state struct

### What Can Go Wrong

- if you forget that each step returns new state, it is easy to lose an update while editing code

## OTP In Practice For This Repo

For this codebase, you can read OTP as:

- startup tree for core services,
- message-driven scheduler loop,
- isolated worker tasks,
- supervised observability components.

You do not need deeper OTP theory before contributing. Start with:

1. [Architecture Overview](./architecture-overview.md)
2. [Code Map](./code-map.md)
3. `lib/symphony_elixir/orchestrator.ex`

Then follow one concrete flow, such as "issue found in Linear" or "worker exits and retries."
