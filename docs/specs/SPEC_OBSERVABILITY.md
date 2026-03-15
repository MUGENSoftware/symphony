# Specification: Symphony Observability & Telemetry

## 1. Executive Summary

Symphony already exposes useful local observability through:

- the terminal status dashboard,
- rotating disk logs,
- per-issue Claude session logs,
- the optional HTTP dashboard and JSON API.

This specification extends those surfaces with a self-hosted telemetry pipeline based on
OpenTelemetry and the LGTM stack.

The key requirement is additive observability, not replacement observability:

- local logs must remain available for operators,
- per-issue Claude session logs must remain the source of full turn output,
- OTEL traces, metrics, and searchable logs should enrich the current experience, not remove it.

The goal is end-to-end traceability from:

- `issue_id` / `issue_identifier`
- to orchestrator dispatch and retry decisions
- to individual Claude turns
- to the raw turn log file persisted on disk
- to the live status shown in the dashboard/API

## 2. Current Project Reality

This specification is intentionally aligned to the current Elixir implementation.

### 2.1 Actual Runtime Boundaries

- `SymphonyElixir.Orchestrator` is a `GenServer` scheduler.
- Issue work is executed in supervised tasks spawned by `Task.Supervisor`.
- `SymphonyElixir.AgentRunner` is a worker module with `run/3`; it is not a `GenServer`.
- `SymphonyElixir.Claude.Cli` owns Claude subprocess startup and `Port` interaction.
- `SymphonyElixir.Claude.SessionLog` persists per-issue turn logs under the configured logs root.

### 2.2 Existing Observability Surfaces

- Terminal dashboard: live local state, throughput, retries, cooldowns.
- Disk log: `log/symphony.jsonl`, emitted by the default `logger_json` file handler.
- Linear pull log: `log/linear-pull.jsonl`.
- Claude session logs: `log/claude/<issue_identifier>/*.jsonl`.
- HTTP dashboard/API: current running/retrying state plus issue-specific session log metadata.

Any telemetry design that ignores or replaces these surfaces is not a fit for this repository.

## 3. Goals

### 3.1 Primary Goals

- Preserve current operator workflows.
- Add distributed traces for orchestration and Claude turns.
- Add machine-scrapable metrics for runtime health and throughput.
- Make logs and traces correlate on the same identifiers already used by the codebase.
- Keep raw Claude turn output accessible through local files and the issue API.

### 3.2 Non-Goals

- Re-architecting `AgentRunner` into a `GenServer`.
- Replacing local disk logging with remote-only logging.
- Sending full Claude output bodies into Prometheus metrics.
- Using high-cardinality metric labels such as `issue_identifier` or `session_id`.

## 4. Correlation Model

All observability data should use the project's existing field names.

### 4.1 Canonical Identifiers

- `issue_id`: Linear internal UUID.
- `issue_identifier`: human ticket key such as `MT-620`.
- `session_id`: Claude session/thread identifier when available.

### 4.2 Optional Additional Identifiers

- `run_id`: a Symphony-local UUID for one dispatched worker lifecycle.
- `turn_number`: Claude turn number within a run.
- `retry_attempt`: orchestrator retry attempt count.

`run_id` is useful for traces and structured logs, but it does not replace `session_id`.

### 4.3 Cardinality Rules

Allowed in logs and traces:

- `issue_id`
- `issue_identifier`
- `session_id`
- `run_id`

Allowed in metrics only when low cardinality:

- result/status enums
- tracker kind
- worker exit class
- Claude availability state

Do not label Prometheus metrics with `issue_identifier`, `session_id`, or `run_id`.

## 5. Target Architecture

| Signal | Source in Symphony | Backend | Notes |
| --- | --- | --- | --- |
| Traces | `Orchestrator`, `AgentRunner`, `Claude.Cli` | Tempo | Parent/child spans for dispatch, worker run, Claude turn |
| Logs | existing `Logger` output plus session log metadata | Loki | Structured export should be additive to local files |
| Metrics | `:telemetry` events and selected gauges/counters | Prometheus | Low-cardinality only |
| UI | existing terminal/HTTP surfaces plus Grafana | Grafana | Grafana is supplemental, not the only pane |

## 6. Elixir Instrumentation Plan

### 6.1 Dependencies

Add OTEL and Prometheus dependencies in `mix.exs`.

Illustrative dependency set:

```elixir
defp deps do
  [
    {:opentelemetry, "~> 1.3"},
    {:opentelemetry_api, "~> 1.2"},
    {:opentelemetry_exporter, "~> 1.6"},
    {:opentelemetry_process_propagator, "~> 0.2"},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_metrics_prometheus_core, "~> 1.2"}
  ]
end
```

Notes:

- `logger_json` is now foundational to the local logging baseline in this repository.
- OTEL/log-export work should layer on top of the existing `logger_json` + `SymphonyElixir.LogFile`
  setup, not replace it.
- If structured remote log shipping is added, it must coexist with `SymphonyElixir.LogFile`.

### 6.2 Boot-Time Setup

Add a new `SymphonyElixir.OtelSetup` child to the application supervisor.

Responsibilities:

- configure OTEL exporter endpoint/protocol from runtime env,
- configure OTEL runtime setup at app startup,
- attach telemetry handlers,
- start Prometheus metrics exporter endpoint if enabled.

This should be wired in `SymphonyElixir.Application` alongside the existing children, not instead of
them.

### 6.3 Runtime Configuration

Observability config is split between static app config and runtime env:

- static resource attributes such as `service.name=symphony-elixir` belong in `config/config.exs`
- runtime OTLP endpoints and Prometheus port wiring belong in env-driven setup

The runtime portion is described by settings such as:

- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_EXPORTER_OTLP_PROTOCOL`
- `SYMPHONY_OBSERVABILITY_PROMETHEUS_PORT`
- `SYMPHONY_OBSERVABILITY_ENABLED`

`OTEL_SERVICE_NAME` may also be used as an explicit override during manual validation.

## 7. Trace Design

### 7.1 Root Spans

Create traces from the actual execution boundaries in this repository.

Recommended span hierarchy:

1. `orchestrator.poll_cycle`
2. `orchestrator.dispatch_issue`
3. `agent_runner.run`
4. `claude.turn`
5. optional nested spans such as `workspace.create`, `git.setup`, `git.publish`, `tracker.refresh`

### 7.2 Orchestrator Instrumentation

Instrument `SymphonyElixir.Orchestrator` for:

- poll cycle start/end,
- candidate issue fetch,
- issue dispatch,
- retry scheduling,
- normal completion vs abnormal worker exit,
- Claude cooldown gating.

Important attributes:

- `issue_id`
- `issue_identifier`
- `retry_attempt`
- `dispatch_reason`
- `worker_exit_reason`
- `claude_availability_status`

### 7.3 Agent Runner Instrumentation

Instrument `SymphonyElixir.AgentRunner.run/3` and the turn loop, not imaginary `GenServer`
callbacks.

Important events:

- worker start,
- workspace setup,
- before/after hooks,
- turn N of M,
- continuation decision,
- worker failure.

Important attributes:

- `issue_id`
- `issue_identifier`
- `run_id`
- `turn_number`
- `max_turns`
- `workspace_path`

### 7.4 Claude CLI Instrumentation

Instrument `SymphonyElixir.Claude.Cli`, because it owns:

- Claude subprocess startup,
- `Port.open`,
- stream-json execution,
- app-server mode execution,
- final turn result and usage data,
- session log lifecycle.

Important span boundaries:

- `claude.start_cli`
- `claude.execute_turn`
- `claude.stream_json.consume`
- `claude.app_server.consume`
- `claude.finish_turn_log`

Important attributes:

- `issue_id`
- `issue_identifier`
- `session_id`
- `run_id`
- `turn_number`
- `mode`
- `result`
- `resume_session_id`

### 7.5 Context Propagation

Because issue work runs in supervised tasks, OTEL context must be propagated across task spawn
boundaries.

Required flow:

1. Capture the current context in `Orchestrator` before spawning the worker task.
2. Pass that context into `AgentRunner.run/3` via opts or an explicit wrapper.
3. Attach the context at the start of the worker task.
4. Start child spans inside `AgentRunner` and `Claude.Cli`.

Do not describe this as `AgentRunner.start_link/1` or `AgentRunner.init/1`; those functions do not
exist in the current codebase.

## 8. Logging Design

### 8.1 Principle

Remote structured logging must be additive to existing disk logging.

The following must remain intact:

- `log/symphony.jsonl`
- `log/linear-pull.jsonl`
- per-issue Claude session logs under `log/claude/...`

### 8.2 Structured Log Content

For lifecycle logs emitted through `Logger`, include metadata for:

- `issue_id`
- `issue_identifier`
- `session_id`
- `run_id`
- `trace_id`
- `span_id`

Message text should continue following current conventions:

- deterministic wording,
- `key=value` style for major fields,
- concise failure reasons.

### 8.3 Claude Output Handling

- preserve `SymphonyElixir.Claude.SessionLog` as the source of exact turn output,
- do not mirror full Claude stream bodies into `log/symphony.jsonl` by default,
- when adding remote shipping, prefer log references and session-log metadata over duplicating raw
  Claude bodies into another backend,
- include session log path or basename in structured metadata when useful,
- expose that metadata through the issue API and traces.

This keeps the lifecycle log focused on application events while preserving exact turn output in the
per-issue Claude artifacts.

### 8.4 Recommended Log Correlation

When a Claude turn finishes, log:

- `issue_id`
- `issue_identifier`
- `session_id`
- `run_id`
- `turn_number`
- `result`
- `claude_log_path`

This gives Grafana/Loki users a direct pointer to the canonical raw artifact.

## 9. Metrics Design

### 9.1 Required Metrics

Expose low-cardinality counters/gauges/histograms for:

- `symphony_poll_cycles_total`
- `symphony_poll_cycle_duration_ms`
- `symphony_issue_dispatch_total`
- `symphony_issue_retry_total`
- `symphony_agent_runs_started_total`
- `symphony_agent_runs_completed_total`
- `symphony_agent_runs_failed_total`
- `symphony_claude_turns_total`
- `symphony_claude_turn_duration_ms`
- `symphony_claude_usage_limit_events_total`
- `symphony_running_agents`
- `symphony_retry_queue_depth`
- `symphony_claude_cooldown_active`

### 9.2 Label Guidance

Safe label examples:

- `result=completed|failed|usage_limit_reached`
- `mode=stream_json|app_server`
- `exit_class=normal|error|timeout`

Unsafe label examples:

- `issue_identifier=...`
- `session_id=...`
- `run_id=...`

### 9.3 Anti-Looping Detection

The previous idea of:

```promql
increase(symphony_agent_turns_total[2m]) > 10
```

is too coarse by itself because Symphony legitimately performs continuation turns and may run
multiple workers concurrently.

Prefer alerts based on combinations such as:

- high turn volume plus no completed runs,
- repeated retries for the same worker exit class,
- long-running active workers without token growth,
- prolonged Claude cooldown state.

Example alert ideas:

```promql
increase(symphony_issue_retry_total[10m]) > 5
```

```promql
max_over_time(symphony_claude_cooldown_active[15m]) == 1
```

```promql
increase(symphony_claude_turns_total{result="failed"}[10m]) > 3
```

Per-issue loop diagnosis should come from logs/traces/API state, not high-cardinality Prometheus
labels.

## 10. Infrastructure

### 10.1 Stack

Run a self-hosted stack with:

- OTEL Collector
- Tempo
- Loki
- Prometheus
- Grafana

Illustrative `docker-compose.yml`:

```yaml
services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    command: ["--config=/etc/otel-collector-config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel-collector-config.yaml:ro
    ports:
      - "4317:4317"
      - "4318:4318"

  tempo:
    image: grafana/tempo:2.7.2
    command: ["-config.file=/etc/tempo.yaml"]
    ports:
      - "3200:3200"

  loki:
    image: grafana/loki:latest
    ports:
      - "3100:3100"

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    environment:
      - GF_AUTH_ANONYMOUS_ENABLED=true
    volumes:
      - ./grafana/datasources.yaml:/etc/grafana/provisioning/datasources/datasources.yaml:ro
    ports:
      - "3000:3000"
```

### 10.2 Log Shipping Options

Acceptable options:

1. ship structured application logs from file to Loki with Promtail or Alloy,
2. add a secondary structured logger handler for OTEL/Loki export while preserving disk logs,
3. ship only selected lifecycle logs remotely and keep full Claude output local.

Recommended initial approach:

- keep `SymphonyElixir.LogFile` as-is,
- ship `log/symphony.jsonl` and `log/linear-pull.jsonl` to Loki with an agent,
- keep Claude session logs local at first,
- add remote structured session-log metadata before considering full raw-output shipping.

## 11. Grafana Experience

### 11.1 Existing Surfaces Still Matter

Operators should continue using:

1. terminal dashboard for live local state,
2. HTTP dashboard/API for remote inspection,
3. session log files for exact Claude output.

Grafana is the cross-run, cross-host analytics layer.

### 11.2 Recommended Grafana Queries

Primary trace lookup:

- search traces by `issue_identifier`
- filter by `run_id` or `session_id`
- inspect `claude.turn` spans

Primary log lookup:

- query logs by `issue_identifier`
- narrow by `session_id` or `run_id`
- use `trace_id` to pivot into Tempo

Primary metrics panels:

- running agents
- retry queue depth
- failed Claude turns over time
- Claude cooldown active/inactive
- poll cycle latency

## 12. Implementation Phases

### Phase 1: Trace and Metric Foundation

- add OTEL dependencies,
- add `SymphonyElixir.OtelSetup`,
- instrument `Orchestrator`, `AgentRunner`, and `Claude.Cli`,
- expose basic Prometheus metrics,
- preserve all current logs and dashboards.

### Phase 2: Structured Log Correlation

- attach `trace_id` and `span_id` to lifecycle logs,
- add `run_id`,
- ensure session log path metadata is emitted on turn completion,
- ship application logs to Loki.

### Phase 3: Dashboards and Alerts

- provision Grafana data sources,
- add dashboards for runtime health,
- add alerts for retry storms, cooldown lock, and failed-turn spikes.

## 13. Deployment Checklist

1. [ ] Add `SymphonyElixir.OtelSetup` to the application supervisor.
2. [ ] Instrument `Orchestrator` poll, dispatch, retry, and worker-exit paths.
3. [ ] Instrument `AgentRunner.run/3` and the turn loop.
4. [ ] Instrument `Claude.Cli` subprocess start, turn execution, and session log finalization.
5. [ ] Implement OTEL context propagation across `Task.Supervisor` worker boundaries.
6. [ ] Add Prometheus metrics with low-cardinality labels only.
7. [ ] Preserve `SymphonyElixir.LogFile` and `SymphonyElixir.Claude.SessionLog`.
8. [ ] Ship local logs to Loki or add a secondary structured export path.
9. [ ] Provision Tempo, Loki, Prometheus, and Grafana.
10. [ ] Add Grafana dashboards and alerts for retries, failures, cooldowns, and latency.

## 14. Acceptance Criteria

The observability work is complete when an operator can:

1. start from an `issue_identifier`,
2. find the associated worker run in the HTTP API or Grafana,
3. pivot to the relevant `session_id` and trace,
4. see whether the issue was dispatched, retried, continued, or blocked by cooldown,
5. locate the exact persisted Claude session log for the turn in question,
6. confirm the same run without losing the current local logging/dashboard workflow.
