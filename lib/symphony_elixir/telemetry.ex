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
      Telemetry.Metrics.counter("symphony.agent_runs.started.total"),
      Telemetry.Metrics.counter("symphony.agent_runs.completed.total"),
      Telemetry.Metrics.counter("symphony.agent_runs.failed.total"),
      Telemetry.Metrics.counter("symphony.claude.turns.total",
        tag_values: &Map.take(&1, [:result, :mode])
      ),
      Telemetry.Metrics.distribution("symphony.claude.turn_duration_ms.duration"),
      Telemetry.Metrics.counter("symphony.claude.usage_limit_events.total")
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
end
