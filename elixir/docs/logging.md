# Logging Best Practices

This guide defines logging conventions for Symphony so Claude Code can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Log Files

- `log/symphony.log`: main application lifecycle log.
- `log/linear-pull.log`: dedicated Linear read/poll log for candidate issue fetches, state refreshes,
  viewer lookup, pagination, and fetch failures.
- `--logs-root <path>` relocates both files under the same root.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Claude Code execution lifecycle events, include:

- `session_id`: combined Claude Code thread/turn identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `Claude.Cli`: log session start/completion/error with issue context and `session_id`.
- `Linear.Client`: write pull activity to `log/linear-pull.log` with `event=...` plus operation,
  states, issue ids/identifiers, pagination info, and concise failure reasons.

## Linear Pull Log

Use `log/linear-pull.log` first when you need to confirm whether Symphony is talking to Linear.

High-signal events:

- `event="fetch_start"`: a Linear read operation began.
- `event="page_fetch_start"` / `event="page_fetch_result"`: a paginated issues query started or
  returned a page.
- `event="fetch_success"`: the fetch completed and includes issue counts plus identifiers.
- `event="fetch_failure"`: the fetch failed and includes normalized error fields like `reason`,
  `status`, or `graphql_errors`.
- `event="viewer_lookup_start"` / `event="viewer_lookup_success"`: assignee resolution for
  `tracker.assignee: me`.

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Claude Code session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
