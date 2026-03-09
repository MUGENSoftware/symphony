defmodule SymphonyElixir.Telemetry do
  @moduledoc """
  Telemetry metrics definitions and counter helpers for Symphony.

  Emits `:telemetry` events that can be consumed by Prometheus or
  other metric backends.

  ## Anti-looping alert expressions (PromQL)

  These expressions detect pathological retry/failure loops and should
  be configured in your alerting rules:

      # Too many retries in a 10-minute window
      increase(symphony_issue_retry_total[10m]) > 5

      # Claude stuck in cooldown for 15+ minutes
      max_over_time(symphony_claude_cooldown_active[15m]) == 1

      # Repeated Claude turn failures
      increase(symphony_claude_turns_total{result="failed"}[10m]) > 3

  Per-issue loop diagnosis must come from logs/traces/API state — not
  Prometheus labels.
  """

  @doc """
  Returns the list of `Telemetry.Metrics` definitions for Prometheus export.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Orchestrator poll cycle
      Telemetry.Metrics.counter("symphony.poll_cycles.total"),
      Telemetry.Metrics.distribution("symphony.poll_cycle_duration_ms.duration",
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000]]
      ),

      # Issue dispatch and retry
      Telemetry.Metrics.counter("symphony.issue_dispatch.total"),
      Telemetry.Metrics.counter("symphony.issue_retry.total"),

      # Agent runs
      Telemetry.Metrics.counter("symphony.agent_runs.started.total"),
      Telemetry.Metrics.counter("symphony.agent_runs.completed.total"),
      Telemetry.Metrics.counter("symphony.agent_runs.failed.total"),

      # Claude turns
      Telemetry.Metrics.counter("symphony.claude.turns.total",
        tag_values: &Map.take(&1, [:result, :mode])
      ),
      Telemetry.Metrics.distribution("symphony.claude.turn_duration_ms.duration",
        reporter_options: [buckets: [100, 500, 1_000, 5_000, 10_000, 30_000, 60_000, 120_000]]
      ),
      Telemetry.Metrics.counter("symphony.claude.usage_limit_events.total"),

      # Gauges
      Telemetry.Metrics.last_value("symphony.running_agents.value"),
      Telemetry.Metrics.last_value("symphony.retry_queue_depth.value"),
      Telemetry.Metrics.last_value("symphony.claude_cooldown_active.value")
    ]
  end

  # ── Orchestrator poll cycle ──────────────────────────────────────────

  @doc "Increment the poll cycles counter."
  @spec poll_cycle_completed(map()) :: :ok
  def poll_cycle_completed(metadata \\ %{}) do
    :telemetry.execute([:symphony, :poll_cycles], %{total: 1}, metadata)
  end

  @doc "Record poll cycle duration in milliseconds."
  @spec poll_cycle_duration(non_neg_integer(), map()) :: :ok
  def poll_cycle_duration(duration_ms, metadata \\ %{}) do
    :telemetry.execute([:symphony, :poll_cycle_duration_ms], %{duration: duration_ms}, metadata)
  end

  # ── Dispatch and retry ───────────────────────────────────────────────

  @doc "Increment the issue dispatch counter."
  @spec issue_dispatched(map()) :: :ok
  def issue_dispatched(metadata \\ %{}) do
    :telemetry.execute([:symphony, :issue_dispatch], %{total: 1}, metadata)
  end

  @doc "Increment the issue retry counter."
  @spec issue_retried(map()) :: :ok
  def issue_retried(metadata \\ %{}) do
    :telemetry.execute([:symphony, :issue_retry], %{total: 1}, metadata)
  end

  # ── Agent runs ───────────────────────────────────────────────────────

  @doc "Increment the agent runs started counter."
  @spec agent_run_started(map()) :: :ok
  def agent_run_started(metadata \\ %{}) do
    :telemetry.execute([:symphony, :agent_runs, :started], %{total: 1}, metadata)
  end

  @doc "Increment the agent runs completed counter."
  @spec agent_run_completed(map()) :: :ok
  def agent_run_completed(metadata \\ %{}) do
    :telemetry.execute([:symphony, :agent_runs, :completed], %{total: 1}, metadata)
  end

  @doc "Increment the agent runs failed counter."
  @spec agent_run_failed(map()) :: :ok
  def agent_run_failed(metadata \\ %{}) do
    :telemetry.execute([:symphony, :agent_runs, :failed], %{total: 1}, metadata)
  end

  # ── Claude turns ─────────────────────────────────────────────────────

  @doc "Increment the Claude turns counter with result and mode labels."
  @spec claude_turn_completed(map()) :: :ok
  def claude_turn_completed(metadata \\ %{}) do
    :telemetry.execute([:symphony, :claude, :turns], %{total: 1}, metadata)
  end

  @doc "Record Claude turn duration in milliseconds."
  @spec claude_turn_duration(non_neg_integer(), map()) :: :ok
  def claude_turn_duration(duration_ms, metadata \\ %{}) do
    :telemetry.execute([:symphony, :claude, :turn_duration_ms], %{duration: duration_ms}, metadata)
  end

  @doc "Increment the Claude usage limit events counter."
  @spec claude_usage_limit_event(map()) :: :ok
  def claude_usage_limit_event(metadata \\ %{}) do
    :telemetry.execute([:symphony, :claude, :usage_limit_events], %{total: 1}, metadata)
  end

  # ── Gauges ───────────────────────────────────────────────────────────

  @doc "Report the current number of running agents."
  @spec report_running_agents(non_neg_integer()) :: :ok
  def report_running_agents(count) when is_integer(count) do
    :telemetry.execute([:symphony, :running_agents], %{value: count}, %{})
  end

  @doc "Report the current retry queue depth."
  @spec report_retry_queue_depth(non_neg_integer()) :: :ok
  def report_retry_queue_depth(count) when is_integer(count) do
    :telemetry.execute([:symphony, :retry_queue_depth], %{value: count}, %{})
  end

  @doc "Report whether Claude cooldown is active (1 or 0)."
  @spec report_claude_cooldown_active(0 | 1) :: :ok
  def report_claude_cooldown_active(value) when value in [0, 1] do
    :telemetry.execute([:symphony, :claude_cooldown_active], %{value: value}, %{})
  end
end
