# Symphony Architecture

Symphony is an Elixir service that transforms Linear issues into autonomous Claude Code sessions. It polls a Linear project for eligible issues, creates isolated per-issue workspaces, launches Claude Code CLI in each workspace, and tracks progress until issues reach terminal states.

## System Overview

```mermaid
graph TB
    subgraph External["External Services"]
        Linear["Linear API<br/>(GraphQL)"]
        GitHub["GitHub<br/>(git remote)"]
        Claude["Claude Code CLI"]
    end

    subgraph Symphony["Symphony Application"]
        CLI["CLI Entry Point"]
        App["Application Supervisor"]

        subgraph Core["Core Services"]
            Orchestrator["Orchestrator<br/>(GenServer)"]
            WorkflowStore["WorkflowStore<br/>(GenServer)"]
            TaskSup["Task.Supervisor"]
            PubSub["Phoenix.PubSub"]
        end

        subgraph Workers["Per-Issue Workers"]
            AR1["AgentRunner<br/>(Issue A)"]
            AR2["AgentRunner<br/>(Issue B)"]
            ARn["AgentRunner<br/>(Issue N)"]
        end

        subgraph Infra["Infrastructure Layer"]
            Workspace["Workspace<br/>(fs isolation)"]
            Git["Git Module<br/>(branch/PR)"]
            PromptBuilder["PromptBuilder<br/>(template)"]
            Tracker["Tracker Adapter"]
            DynTools["DynamicToolRegistry"]
        end

        subgraph UI["Dashboards"]
            StatusDash["StatusDashboard<br/>(terminal)"]
            HttpServer["HttpServer<br/>(Phoenix)"]
            LiveView["DashboardLive<br/>(LiveView)"]
        end
    end

    CLI -->|starts| App
    App -->|supervises| Orchestrator
    App -->|supervises| WorkflowStore
    App -->|supervises| TaskSup
    App -->|supervises| PubSub
    App -->|supervises| StatusDash
    App -->|supervises| HttpServer

    Orchestrator -->|polls| Tracker
    Tracker -->|GraphQL| Linear
    Orchestrator -->|spawns via| TaskSup
    TaskSup -->|runs| AR1
    TaskSup -->|runs| AR2
    TaskSup -->|runs| ARn

    AR1 -->|creates| Workspace
    AR1 -->|renders prompt| PromptBuilder
    AR1 -->|subprocess| Claude
    AR1 -->|branch/PR| Git
    Git -->|push/PR| GitHub

    DynTools -->|linear_graphql| Linear
    DynTools -->|git_status/commit| Git

    Orchestrator -->|broadcasts| PubSub
    PubSub -->|updates| StatusDash
    PubSub -->|updates| LiveView
    HttpServer -->|serves| LiveView
```

## Polling & Dispatch Loop

```mermaid
sequenceDiagram
    participant Timer as :tick Timer
    participant Orch as Orchestrator
    participant Linear as Linear API
    participant TaskSup as Task.Supervisor
    participant AR as AgentRunner

    loop Every polling_interval_ms (default 30s)
        Timer->>Orch: :tick
        Orch->>Orch: refresh_runtime_config()
        Orch->>Linear: fetch_candidate_issues()<br/>(active states only)
        Linear-->>Orch: issues list

        Orch->>Orch: filter by concurrency limit,<br/>cooldown, already running

        loop For each eligible issue
            Orch->>TaskSup: start_child(AgentRunner)
            TaskSup->>AR: spawn & monitor
            AR-->>Orch: {:claude_worker_update, id, msg}
        end

        Orch->>Linear: fetch_issue_states_by_ids()<br/>(reconcile running workers)
        Note over Orch: Remove workers whose issues<br/>reached terminal state
    end
```

## Issue Execution Lifecycle

```mermaid
sequenceDiagram
    participant Orch as Orchestrator
    participant AR as AgentRunner
    participant WS as Workspace
    participant Git as Git Module
    participant PB as PromptBuilder
    participant Claude as Claude CLI
    participant DT as DynamicTools
    participant Linear as Linear API

    Orch->>AR: dispatch(issue)

    rect rgb(240, 248, 255)
        Note over AR,WS: Workspace Setup
        AR->>WS: create_workspace(issue)
        WS->>WS: mkdir per-issue directory
        WS->>WS: run after_create hook<br/>(git clone)
    end

    rect rgb(240, 255, 240)
        Note over AR,Git: Git Setup
        AR->>Git: setup_branch(issue)
        Git->>Git: fetch origin
        Git->>Git: create/checkout feature branch
        Git->>Git: merge base branch
    end

    AR->>WS: run before_run hook

    rect rgb(255, 248, 240)
        Note over AR,Claude: Claude Turn Loop (1..max_turns)
        loop Turn 1 to max_turns
            AR->>PB: build_turn_prompt(issue, attempt)
            PB-->>AR: rendered prompt + git context

            AR->>Claude: start subprocess<br/>(--output-format stream-json)
            Claude-->>AR: stream JSON messages

            loop Tool calls during turn
                Claude->>DT: tool_call (linear_graphql, git_status, git_commit)
                DT-->>Claude: tool_result
            end

            Claude-->>AR: turn result + token metrics
            AR->>Orch: {:claude_worker_update, id, metrics}

            alt outcome: done
                Note over AR: break loop
            else outcome: needs_retry
                Note over AR: continue next turn
            end
        end
    end

    rect rgb(248, 240, 255)
        Note over AR,Git: Publish Phase
        AR->>Git: publish(workspace)
        Git->>Git: push commits to origin
        Git->>Git: create/update PR
    end

    AR->>WS: run after_run hook
    AR-->>Orch: :DOWN (normal exit)
```

## Worker Exit & Retry Flow

```mermaid
flowchart TD
    A[Worker exits] --> B{Exit reason?}
    B -->|normal| C[Mark issue completed]
    B -->|error| D[Schedule retry<br/>with backoff]
    C --> E[Schedule continuation check]
    D --> E
    E --> F[Next :tick]
    F --> G[Reconcile against Linear]
    G --> H{Issue in<br/>terminal state?}
    H -->|yes| I[Remove workspace<br/>Clean up]
    H -->|no| J{Retry<br/>available?}
    J -->|yes| K[Re-dispatch issue]
    J -->|no| L[Log failure]
```

## Issue State Machine

```mermaid
stateDiagram-v2
    [*] --> Backlog
    Backlog --> Todo: human moves
    Todo --> InProgress: Symphony picks up
    InProgress --> InReview: PR created & validated
    InReview --> Rework: reviewer requests changes
    InReview --> Merging: human approves
    Rework --> InProgress: rework starts
    Merging --> Done: land skill merges PR
    Done --> [*]
```

## Supervision Tree

```mermaid
graph TD
    App["Application<br/>(Supervisor)"]
    OTEL["OpenTelemetry Setup"]
    TaskSup["Task.Supervisor<br/>(agent workers)"]
    PubSub["Phoenix.PubSub"]
    WFS["WorkflowStore<br/>(GenServer)"]
    Orch["Orchestrator<br/>(GenServer)"]
    HTTP["HttpServer<br/>(Phoenix)"]
    Dash["StatusDashboard<br/>(GenServer)"]

    App --> OTEL
    App --> TaskSup
    App --> PubSub
    App --> WFS
    App --> Orch
    App --> HTTP
    App --> Dash

    TaskSup --> W1["AgentRunner (issue 1)"]
    TaskSup --> W2["AgentRunner (issue 2)"]
    TaskSup --> Wn["AgentRunner (issue N)"]
```

## Configuration Flow

```mermaid
flowchart LR
    WF["WORKFLOW.md<br/>(YAML front matter<br/>+ prompt template)"]
    ENV["Environment Variables<br/>(LINEAR_API_KEY, etc.)"]
    MCP["MCP Config<br/>(claude.mcp.json)"]

    WF --> Config["Config Module"]
    ENV --> Config

    Config --> Orch["Orchestrator<br/>(polling, concurrency)"]
    Config --> Tracker["Tracker<br/>(Linear settings)"]
    Config --> Agent["AgentRunner<br/>(max_turns, timeout)"]
    Config --> Git["Git Module<br/>(branch prefix, base)"]

    MCP --> Claude["Claude CLI<br/>(MCP servers)"]
    WF -->|prompt_template| PB["PromptBuilder"]
    PB -->|rendered prompt| Claude
```
