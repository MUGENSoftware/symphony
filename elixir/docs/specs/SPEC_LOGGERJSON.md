# Specification: Secondary LoggerJSON Handler

## 1. Executive Summary

Symphony should add a secondary JSON log handler without disrupting the current logging experience.

Today, the application relies on:

- a rotating local text log for general runtime activity,
- a dedicated Linear pull log,
- per-issue Claude session logs persisted on disk.

This specification adds a second structured log stream using `LoggerJSON`.

The immediate goal is local development visibility:

- write newline-delimited JSON logs to a local file,
- preserve the existing rotating text log,
- keep the existing Claude session logs unchanged.

The future goal is remote shipping:

- use the JSON log file or JSON handler output as the source for Loki ingestion.

## 2. Why This Change

The current text log is good for humans reading local failures quickly, but it is not ideal for:

- machine parsing,
- trace/log correlation,
- future Loki queries,
- structured filtering by issue, session, or run metadata.

Adding `LoggerJSON` as a secondary handler gives Symphony both:

- human-friendly text logs for local operators,
- structured JSON logs for local tooling now and Loki later.

## 3. Non-Goals

This specification does not:

- replace the current text log,
- replace per-issue Claude session logs,
- send logs to Loki yet,
- convert every existing log message body into deeply nested JSON payloads,
- require a full observability stack before local use is valuable.

## 4. Current State

### 4.1 Existing Logging Surfaces

- `log/symphony.log`: main rotating application log.
- `log/linear-pull.log`: dedicated Linear polling log.
- `log/claude/<issue_identifier>/*.log`: raw Claude turn output.

### 4.2 Current Logging Behavior

`SymphonyElixir.LogFile` configures a rotating disk handler for the main application log.

That behavior should remain in place.

## 5. Proposed Design

### 5.1 High-Level Design

Add a second logger handler that writes structured JSON logs to a separate rotating file, for
example:

- `log/symphony.jsonl`

The application will therefore produce two parallel log streams:

1. text lifecycle log for operators,
2. JSON lifecycle log for structured processing.

### 5.2 Why A Separate File

A separate JSON file is preferable to replacing the current text log because it:

- preserves the current operator workflow,
- makes rollout lower-risk,
- allows developers to inspect JSON locally with `tail` and `jq`,
- creates a clean handoff point for future Loki shipping agents.

### 5.3 Output Format

The JSON log file should use one JSON object per line.

This format is suitable for:

- `tail -f log/symphony.jsonl`,
- piping to `jq`,
- Promtail or Grafana Alloy file scraping later.

## 6. Handler Requirements

### 6.1 Primary Requirement

`LoggerJSON` must be configured as a secondary logger handler, not as the only default handler.

### 6.2 File and Rotation

The JSON handler must write directly to a rotating local file with bounded disk usage.

Recommended defaults:

- path: `log/symphony.jsonl`
- max size: 10 MB
- retained files: 5

These defaults should mirror the current text log behavior closely unless there is a reason to
separate them.

### 6.3 Failure Isolation

If the JSON handler fails to initialize:

- Symphony should still boot,
- the existing text log should still work,
- a warning should be emitted if possible.

The JSON handler must not become a single point of failure for the application.

## 7. Structured Fields

### 7.1 Required Metadata

The JSON stream should carry the same key correlation fields already used by the application:

- `issue_id`
- `issue_identifier`
- `session_id`

### 7.2 Additional Recommended Metadata

Add support for the following when present:

- `run_id`
- `trace_id`
- `span_id`
- `module`
- `function`
- `line`
- `pid`
- `level`
- `timestamp`

### 7.3 Message Body

Each record should include:

- the human log message,
- the structured metadata,
- a normalized timestamp,
- the severity level.

The existing log message strings should remain stable and readable.

## 8. File Layout

### 8.1 Main JSON File

Add a JSON log file under the same logs root as the existing logs:

- default: `log/symphony.jsonl`
- with `--logs-root <path>`: `<path>/log/symphony.jsonl` or equivalent path under that root

The exact path should follow the same logs-root relocation semantics as the current text logs.

### 8.2 Claude Session Logs

Do not merge raw Claude turn output into `symphony.jsonl`.

Raw Claude output should remain in `SymphonyElixir.Claude.SessionLog`.

Instead, the JSON lifecycle log should include references such as:

- `issue_identifier`
- `session_id`
- `claude_log_path` when available

This keeps the structured log compact while preserving access to the canonical raw artifact.

## 9. Implementation Shape

### 9.1 Dependencies

Add `LoggerJSON` to `elixir/mix.exs`.

Illustrative dependency:

```elixir
{:logger_json, "~> 7.0"}
```

### 9.2 `SymphonyElixir.LogFile` Refactor

Refactor `SymphonyElixir.LogFile` so it configures:

1. the existing rotating text handler,
2. a new rotating JSON handler.

Recommended responsibilities:

- keep path resolution in one place,
- add `default_json_log_file/0` and `default_json_log_file/1`,
- teach `set_logs_root/1` to relocate the JSON log too,
- add a `configure_json_handler/0` path alongside the existing text handler setup,
- avoid removing the console/default handler in a way that breaks the new dual-handler setup.

### 9.3 Handler Choice

Implementation options are acceptable if they preserve the spec behavior:

1. configure an OTP logger handler whose formatter is `LoggerJSON`,
2. configure a dedicated file-backed handler for JSON output,
3. extend `SymphonyElixir.LogFile` with one text handler and one JSON handler.

The important point is not the exact OTP plumbing; it is that Symphony ends up with two persistent
local file outputs.

### 9.4 Configuration Flags

Add application env for:

- JSON log file path
- JSON log max bytes
- JSON log max files
- JSON handler enabled/disabled

Suggested names:

- `:json_log_file`
- `:json_log_file_max_bytes`
- `:json_log_file_max_files`
- `:json_log_enabled`

The JSON handler should default to enabled in development and normal runtime unless explicitly
disabled.

## 10. Developer Experience

### 10.1 Local Inspection

Developers should be able to inspect the JSON log locally with:

```bash
tail -f log/symphony.jsonl
```

and:

```bash
tail -f log/symphony.jsonl | jq
```

### 10.2 Expected Benefits

This should make it easier to:

- filter by `issue_identifier`,
- inspect logs for one `session_id`,
- validate future OTEL correlation fields,
- prepare Grafana/Loki parsing rules before remote shipping is enabled.

## 11. Future Loki Path

This spec is intentionally designed so future Loki shipping is simple.

### 11.1 Planned Future Flow

1. Symphony writes `log/symphony.jsonl`.
2. A local agent such as Promtail or Grafana Alloy tails that file.
3. The agent ships records to Loki.
4. Grafana queries use JSON fields for filtering and correlation.

### 11.2 Future Labels and Parsing

When shipping to Loki later:

- keep high-cardinality identifiers in the JSON body,
- avoid promoting `issue_identifier` or `session_id` to Loki labels unless carefully justified,
- prefer structured fields for filtering at query time.

## 12. Rollout Plan

### Phase 1: Local JSON Logging

- add dependency,
- add secondary JSON handler,
- add JSON log path resolution,
- confirm logs are written locally,
- keep the text log unchanged.

### Phase 2: Correlation Enrichment

- ensure `issue_id`, `issue_identifier`, and `session_id` are consistently attached,
- add `run_id` if adopted,
- add `trace_id` and `span_id` later with OTEL integration.

### Phase 3: Loki Shipping

- introduce Promtail or Alloy configuration,
- ship `symphony.jsonl` to Loki,
- add Grafana queries/dashboards around the structured fields.

## 13. Acceptance Criteria

This work is complete when:

1. Symphony still writes the existing text log.
2. Symphony also writes a structured local JSON log file.
3. `--logs-root` relocates both text and JSON logs consistently.
4. The JSON file rotates and has bounded disk usage.
5. Startup does not fail if the JSON handler cannot be attached.
6. The JSON log contains issue/session correlation metadata when those values are available.
7. Claude raw turn output remains in per-issue session logs, not duplicated wholesale into the JSON
   lifecycle log.

## 14. Open Questions

- Should `log/linear-pull.log` also gain a parallel JSON file in this phase, or should that wait for
  a later follow-up?
- Should the JSON handler be enabled in all environments by default, or only where file logging is
  already enabled?
- Should `claude_log_path` be logged only on turn completion, or also on turn start once the pending
  path exists?
