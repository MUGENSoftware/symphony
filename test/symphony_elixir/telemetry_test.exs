defmodule SymphonyElixir.TelemetryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Telemetry

  describe "metrics/0" do
    test "returns all 13 required metric definitions" do
      metrics = Telemetry.metrics()
      assert length(metrics) == 13
    end

    test "includes all required counter metrics" do
      names = metric_names(Telemetry.metrics(), Elixir.Telemetry.Metrics.Counter)

      assert [:symphony, :poll_cycles, :total] in names
      assert [:symphony, :issue_dispatch, :total] in names
      assert [:symphony, :issue_retry, :total] in names
      assert [:symphony, :agent_runs, :started, :total] in names
      assert [:symphony, :agent_runs, :completed, :total] in names
      assert [:symphony, :agent_runs, :failed, :total] in names
      assert [:symphony, :claude, :turns, :total] in names
      assert [:symphony, :claude, :usage_limit_events, :total] in names
    end

    test "includes histogram/distribution metrics" do
      names = metric_names(Telemetry.metrics(), Elixir.Telemetry.Metrics.Distribution)

      assert [:symphony, :poll_cycle_duration_ms, :duration] in names
      assert [:symphony, :claude, :turn_duration_ms, :duration] in names
    end

    test "includes gauge (last_value) metrics" do
      names = metric_names(Telemetry.metrics(), Elixir.Telemetry.Metrics.LastValue)

      assert [:symphony, :running_agents, :value] in names
      assert [:symphony, :retry_queue_depth, :value] in names
      assert [:symphony, :claude_cooldown_active, :value] in names
    end
  end

  describe "counter helpers emit telemetry events" do
    test "poll_cycle_completed/0" do
      ref = attach("poll_cycles", [:symphony, :poll_cycles])
      Telemetry.poll_cycle_completed()
      assert_received {^ref, %{total: 1}, %{}}
    end

    test "poll_cycle_duration/1" do
      ref = attach("poll_cycle_dur", [:symphony, :poll_cycle_duration_ms])
      Telemetry.poll_cycle_duration(42)
      assert_received {^ref, %{duration: 42}, %{}}
    end

    test "issue_dispatched/0" do
      ref = attach("issue_dispatch", [:symphony, :issue_dispatch])
      Telemetry.issue_dispatched()
      assert_received {^ref, %{total: 1}, %{}}
    end

    test "issue_retried/0" do
      ref = attach("issue_retry", [:symphony, :issue_retry])
      Telemetry.issue_retried()
      assert_received {^ref, %{total: 1}, %{}}
    end

    test "agent_run_started/0" do
      ref = attach("runs_started", [:symphony, :agent_runs, :started])
      Telemetry.agent_run_started()
      assert_received {^ref, %{total: 1}, %{}}
    end

    test "agent_run_completed/0" do
      ref = attach("runs_completed", [:symphony, :agent_runs, :completed])
      Telemetry.agent_run_completed()
      assert_received {^ref, %{total: 1}, %{}}
    end

    test "agent_run_failed/0" do
      ref = attach("runs_failed", [:symphony, :agent_runs, :failed])
      Telemetry.agent_run_failed()
      assert_received {^ref, %{total: 1}, %{}}
    end

    test "claude_turn_completed/1 with labels" do
      ref = attach("claude_turns", [:symphony, :claude, :turns])
      Telemetry.claude_turn_completed(%{result: "completed", mode: "stream_json"})
      assert_received {^ref, %{total: 1}, %{result: "completed", mode: "stream_json"}}
    end

    test "claude_turn_duration/2" do
      ref = attach("claude_turn_dur", [:symphony, :claude, :turn_duration_ms])
      Telemetry.claude_turn_duration(150)
      assert_received {^ref, %{duration: 150}, %{}}
    end

    test "claude_usage_limit_event/0" do
      ref = attach("usage_limit", [:symphony, :claude, :usage_limit_events])
      Telemetry.claude_usage_limit_event()
      assert_received {^ref, %{total: 1}, %{}}
    end
  end

  describe "gauge helpers emit telemetry events" do
    test "report_running_agents/1" do
      ref = attach("running_agents", [:symphony, :running_agents])
      Telemetry.report_running_agents(3)
      assert_received {^ref, %{value: 3}, %{}}
    end

    test "report_retry_queue_depth/1" do
      ref = attach("retry_depth", [:symphony, :retry_queue_depth])
      Telemetry.report_retry_queue_depth(2)
      assert_received {^ref, %{value: 2}, %{}}
    end

    test "report_claude_cooldown_active/1" do
      ref = attach("cooldown_1", [:symphony, :claude_cooldown_active])
      Telemetry.report_claude_cooldown_active(1)
      assert_received {^ref, %{value: 1}, %{}}
    end

    test "report_claude_cooldown_active/1 with 0" do
      ref = attach("cooldown_0", [:symphony, :claude_cooldown_active])
      Telemetry.report_claude_cooldown_active(0)
      assert_received {^ref, %{value: 0}, %{}}
    end
  end

  defp attach(handler_id, event_name) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      handler_id <> inspect(ref),
      event_name,
      fn _event, measurements, metadata, _config ->
        send(parent, {ref, measurements, metadata})
      end,
      nil
    )

    ref
  end

  defp metric_names(metrics, struct_mod) do
    metrics
    |> Enum.filter(fn %{__struct__: s} -> s == struct_mod end)
    |> Enum.map(& &1.name)
  end
end
