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
      Telemetry.Metrics.counter("symphony.agent_runs.failed.total")
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
end
