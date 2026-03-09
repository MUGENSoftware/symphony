defmodule SymphonyElixir.Telemetry do
  @moduledoc """
  Telemetry metrics definitions and counter helpers for Symphony.

  Emits `:telemetry` events that can be consumed by Prometheus or
  other metric backends.
  """

  @doc """
  Returns the list of `Telemetry.Metrics` definitions for Prometheus export.
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Agent runner metrics
      Telemetry.Metrics.counter("symphony.agent_runs.started.total"),
      Telemetry.Metrics.counter("symphony.agent_runs.completed.total"),
      Telemetry.Metrics.counter("symphony.agent_runs.failed.total"),
      Telemetry.Metrics.counter("symphony.claude.turns.total",
        tag_values: &Map.take(&1, [:result, :mode])
      ),
      Telemetry.Metrics.distribution("symphony.claude.turn_duration_ms.duration"),
      Telemetry.Metrics.counter("symphony.claude.usage_limit_events.total"),

      # Orchestrator metrics
      Telemetry.Metrics.counter("symphony.orchestrator.poll_cycle.total"),
      Telemetry.Metrics.distribution("symphony.orchestrator.poll_cycle.duration_ms"),
      Telemetry.Metrics.counter("symphony.orchestrator.issue_dispatch.total"),
      Telemetry.Metrics.counter("symphony.orchestrator.issue_retry.total"),
      Telemetry.Metrics.last_value("symphony.orchestrator.running_agents.value"),
      Telemetry.Metrics.last_value("symphony.orchestrator.retry_queue_depth.value"),
      Telemetry.Metrics.last_value("symphony.orchestrator.claude_cooldown.value")
    ]
  end

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

  @doc "Emit poll cycle completion with duration."
  @spec poll_cycle_completed(number()) :: :ok
  def poll_cycle_completed(duration_ms) do
    :telemetry.execute(
      [:symphony, :orchestrator, :poll_cycle],
      %{total: 1, duration_ms: duration_ms},
      %{}
    )
  end

  @doc "Increment the issue dispatch counter."
  @spec issue_dispatched(map()) :: :ok
  def issue_dispatched(metadata \\ %{}) do
    :telemetry.execute([:symphony, :orchestrator, :issue_dispatch], %{total: 1}, metadata)
  end

  @doc "Increment the issue retry counter."
  @spec issue_retried(map()) :: :ok
  def issue_retried(metadata \\ %{}) do
    :telemetry.execute([:symphony, :orchestrator, :issue_retry], %{total: 1}, metadata)
  end

  @doc "Report current running agents gauge."
  @spec report_running_agents(non_neg_integer()) :: :ok
  def report_running_agents(count) do
    :telemetry.execute([:symphony, :orchestrator, :running_agents], %{value: count}, %{})
  end

  @doc "Report current retry queue depth gauge."
  @spec report_retry_queue_depth(non_neg_integer()) :: :ok
  def report_retry_queue_depth(count) do
    :telemetry.execute([:symphony, :orchestrator, :retry_queue_depth], %{value: count}, %{})
  end

  @doc "Report Claude cooldown active gauge (1 = active, 0 = inactive)."
  @spec report_claude_cooldown(0 | 1) :: :ok
  def report_claude_cooldown(active) do
    :telemetry.execute([:symphony, :orchestrator, :claude_cooldown], %{value: active}, %{})
  end
end
