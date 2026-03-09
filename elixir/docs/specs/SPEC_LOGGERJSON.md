# Specification: JSON-Only Logging

## 1. Executive Summary

Symphony writes operator-facing logs as JSONL only.

The supported log artifacts are:

- `log/symphony.jsonl` for application lifecycle events,
- `log/linear-pull.jsonl` for dedicated Linear polling and refresh activity,
- `log/claude/<issue_identifier>/*.jsonl` for Claude session artifacts, including `latest.jsonl`.

There is no parallel text lifecycle log and no compatibility alias for the old `*.log` paths.

## 2. Goals

- Make every operator-facing log artifact machine-parseable.
- Keep the main lifecycle log tail-able as a real `*.jsonl` file.
- Preserve Claude raw subprocess visibility without falling back to plain text files.
- Keep `--logs-root` behavior unchanged.
- Keep the dedicated Linear pull log separate from the main lifecycle log.

## 3. Main Application Logger

### 3.1 File Path

The canonical lifecycle log path is:

- `log/symphony.jsonl`

`SymphonyElixir.LogFile.default_log_file/0` and `/1` must resolve to that path.

### 3.2 Backend

The main logger uses:

- `:logger_std_h`
- file output
- `LoggerJSON.Formatters.Basic`

The file must be a real tail-able path, not a wrapped disk-log artifact set with `.idx` and `.siz`
sidecars.

### 3.3 Rotation

Rotation remains enabled through the existing config knobs:

- `:log_file`
- `:log_file_max_bytes`
- `:log_file_max_files`

Rotated archives follow the standard file-rotation pattern from `logger_std_h`, such as:

- `symphony.jsonl`
- `symphony.jsonl.0`
- `symphony.jsonl.1`

## 4. Linear Pull Log

### 4.1 File Path

The canonical Linear pull log path is:

- `log/linear-pull.jsonl`

`SymphonyElixir.LogFile.default_linear_pull_log_file/0` and `/1` must resolve to that path.

### 4.2 Record Shape

Each line is one JSON object with:

- `time`
- `event`
- the existing non-nil fields flattened at top level

Example fields include:

- `operation`
- `states`
- `issue_ids`
- `issue_identifiers`
- `page`
- `status`
- `reason`
- `graphql_errors`

The dedicated Linear pull log remains separate from the main `Logger` output.

## 5. Claude Session Logs

### 5.1 File Paths

Claude session artifacts are stored under:

- `log/claude/<issue_identifier>/<timestamp>--<session>.jsonl`
- `log/claude/<issue_identifier>/latest.jsonl`

Transient capture files may exist during execution, but persisted operator-facing artifacts must be
JSONL only.

### 5.2 Record Shape

Each line is one JSON object. Two record kinds are supported:

1. Parsed Claude stream messages:

```json
{"time":"...","kind":"claude_stream","payload":{...},"session_id":"..."}
```

2. Raw unparseable lines:

```json
{"time":"...","kind":"raw_line","text":"warning: stderr noise"}
```

This preserves malformed or non-JSON subprocess output without storing plain text session files.

### 5.3 API Expectations

`SymphonyElixir.Claude.SessionLog.list_issue_logs/1` continues to return:

- `path`
- `session_id`
- `updated_at`
- `tail`

but the paths now point to `*.jsonl` files.

## 6. Logs Root Behavior

`--logs-root <path>` relocates:

- `symphony.jsonl`
- `linear-pull.jsonl`
- the `claude/` directory

in the same way the old text log layout was relocated.

## 7. Non-Goals

- Keeping `symphony.log` or `linear-pull.log` as compatibility aliases
- Duplicating Claude raw output into the main lifecycle log
- Folding the dedicated Linear pull log into the main lifecycle log
- Reintroducing a secondary text handler

## 8. Acceptance Criteria

The refactor is complete when:

1. Symphony writes `log/symphony.jsonl` as the only main lifecycle log.
2. Symphony writes `log/linear-pull.jsonl` as the only dedicated Linear pull log.
3. Claude session artifacts are persisted as `*.jsonl`, including `latest.jsonl`.
4. `--logs-root` relocates all of those outputs consistently.
5. The main lifecycle logger rotates plain files and does not create `.idx` or `.siz` sidecars.
6. Malformed Claude output is preserved inside JSON envelope records rather than plain text files.
