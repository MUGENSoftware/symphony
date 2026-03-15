# Observability Guide

This guide explains how to run Symphony with the local observability stack under `./observability`
and how to verify that traces, metrics, and logs are flowing.

## What This Stack Contains

The local stack is split across the repo in two parts:

- Symphony itself runs on the host as the main Elixir application.
- The supporting telemetry services run in Docker from `./observability`.

Those Docker services are:

- Grafana
- Prometheus
- Loki
- Promtail
- Tempo
- OpenTelemetry Collector

Important distinction:

- the collector currently handles trace export from Symphony to Tempo
- Prometheus scrapes Symphony metrics directly from the host
- Promtail ships Symphony log files directly into Loki

So if one signal is missing, do not assume all three paths are broken.

## Signal Paths

| Signal | Source | Transport | Backend |
| --- | --- | --- | --- |
| Traces | OpenTelemetry spans from Symphony | OTLP HTTP/GRPC via collector | Tempo |
| Metrics | `TelemetryMetricsPrometheus` endpoint on Symphony | Prometheus scrape | Prometheus |
| Logs | `log/*.jsonl` written by Symphony | Promtail file tailing | Loki |

## Start The Stack

From the repository root:

```bash
docker compose -f observability/docker-compose.yml up -d
```

Open these endpoints after the containers are healthy:

- Grafana: `http://localhost:3000`
- Prometheus: `http://localhost:9090`
- Loki: `http://localhost:3100`
- Tempo: `http://localhost:3200`
- OTLP collector HTTP: `http://localhost:4318`

Notes:

- The local Tempo container is pinned to `grafana/tempo:2.7.2` because the checked-in local
  `tempo.yaml` is a single-binary local-storage config and newer `latest` images expect a different
  ingest path.
- The collector uses Loki's OTLP endpoint rather than the removed legacy `loki` exporter.

## Run Symphony With Observability Enabled

Run Symphony on the host, not inside the observability compose project:

```bash
LINEAR_API_KEY=lin_api_xxx \
SYMPHONY_OBSERVABILITY_ENABLED=true \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
SYMPHONY_OBSERVABILITY_PROMETHEUS_PORT=9568 \
OTEL_SERVICE_NAME=symphony-elixir \
mise exec -- ./bin/symphony --port 4000 ./WORKFLOW.md
```

What each variable does:

- `SYMPHONY_OBSERVABILITY_ENABLED=true` enables the OTEL setup worker.
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` points Symphony at the local collector.
- `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` matches the collector config in this repo.
- `SYMPHONY_OBSERVABILITY_PROMETHEUS_PORT=9568` exposes `/metrics` on the host for Prometheus.
- `OTEL_SERVICE_NAME=symphony-elixir` is an explicit service-name override. The app also sets the
  same name in config, but this env var is useful during manual validation.

## Smoke Test

Use this sequence to verify all three signal paths.

### 1. Force A Poll Cycle

Start Symphony, then in another terminal:

```bash
curl -s -X POST http://localhost:4000/api/v1/refresh
```

Even a plain poll cycle with no eligible issues should generate:

- log lines
- poll-cycle metrics
- `orchestrator.poll_cycle` traces

### 2. Check Metrics

```bash
curl -s http://localhost:9568/metrics | rg '^symphony_'
```

You should see metrics such as:

- `symphony_poll_cycles_total`
- `symphony_running_agents_value`
- `symphony_retry_queue_depth_value`

Prometheus should also be able to query them:

```bash
curl -s http://localhost:9090/api/v1/query \
  --data-urlencode 'query=symphony_poll_cycles_total'
```

### 3. Check Logs

Symphony writes JSON log files under the repo `log/` directory by default:

- `log/symphony.jsonl`
- `log/linear-pull.jsonl`
- `log/claude/<issue_identifier>/*.jsonl`

Tail the local files:

```bash
tail -n 20 log/symphony.jsonl
tail -n 20 log/linear-pull.jsonl
```

Then confirm Loki ingestion in Grafana Explore with:

```logql
{service="symphony-elixir"}
```

### 4. Check Traces

In Grafana Explore, switch to Tempo and search for:

```traceql
{ resource.service.name = "symphony-elixir" }
```

For a healthy poll-only flow you should see spans such as:

- `orchestrator.poll_cycle`

When a real issue is dispatched, you should also see:

- `orchestrator.dispatch_issue`
- `agent_runner.run`
- `claude.turn`
- `claude.execute_turn`

### 5. Check The App Dashboard

When you pass `--port 4000`, these routes should respond:

- `http://localhost:4000/`
- `http://localhost:4000/api/v1/state`
- `http://localhost:4000/api/v1/refresh`

## Grafana Usage

The checked-in Grafana provisioning already creates data sources for Loki, Tempo, and Prometheus.

Start with these views:

- Dashboards -> `Symphony Runtime Health`
- Explore -> Loki -> `{service="symphony-elixir"}`
- Explore -> Tempo -> `{ resource.service.name = "symphony-elixir" }`

The Loki data source also defines a derived field for `trace_id`, so log lines that include
`trace_id` can jump into Tempo directly.

## Common Gotchas

### `unknown_service:erl` In Tempo

This means the spans were emitted without the intended `service.name`.

Check these first:

- you rebuilt `./bin/symphony` after changing code or config
- you restarted the running Symphony process
- you are querying only the time range after the restart
- `OTEL_SERVICE_NAME=symphony-elixir` is set during manual validation

Important behavior:

- old traces already stored in Tempo do not disappear after the fix
- querying `unknown_service:erl` will continue to find those older traces

### Prometheus Shows No Symphony Metrics

Check these first:

- Symphony is running on the host
- `SYMPHONY_OBSERVABILITY_PROMETHEUS_PORT=9568` is set
- `curl http://localhost:9568/metrics` responds locally
- Prometheus targets show `host.docker.internal:9568` as healthy

The scrape target is defined in `observability/prometheus.yml`.

### Loki Shows No Symphony Logs

Check these first:

- Symphony is writing logs under the repo `log/` directory
- you did not override `--logs-root` to some other path without updating Promtail
- Promtail is healthy

The checked-in Promtail config reads:

- `/var/log/symphony/symphony.jsonl`
- `/var/log/symphony/linear-pull.jsonl`

Those paths are backed by the bind mount in `observability/docker-compose.yml`.

### Collector Starts But Grafana Still Looks Empty

Remember the split:

- traces go through the collector
- metrics do not
- logs do not

So it is possible for:

- Tempo traces to work while Prometheus is empty
- Prometheus metrics to work while Loki is empty
- Loki logs to work while Tempo is empty

Debug each signal path independently.

### Tempo Fails With A Kafka Topic Error

If you switch Tempo back to `latest`, the local config in this repo is no longer compatible with
that image family. Use the pinned version in `observability/docker-compose.yml` unless you also
replace `observability/tempo.yaml` with a newer topology.

## Files Worth Knowing

- `observability/docker-compose.yml`
- `observability/otel-collector-config.yaml`
- `observability/prometheus.yml`
- `observability/promtail.yaml`
- `observability/tempo.yaml`
- `lib/symphony_elixir/otel_setup.ex`
- `lib/symphony_elixir/telemetry.ex`
- `config/config.exs`

## Related Docs

- [Getting Started](./getting-started.md)
- [Operations Guide](./operations.md)
- [Troubleshooting](./troubleshooting.md)
- [Logging Best Practices](./logging.md)
- [Observability Specification](./specs/SPEC_OBSERVABILITY.md)
