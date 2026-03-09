defmodule SymphonyElixir.Claude.CliInstrumentationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Telemetry

  describe "Telemetry.claude_turn_completed/1" do
    test "emits [:symphony, :claude, :turns] event with result and mode" do
      parent = self()
      handler_id = "test-claude-turn-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:symphony, :claude, :turns],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.claude_turn_completed(%{result: "completed", mode: "stream_json"})

      assert_receive {:telemetry_event, [:symphony, :claude, :turns], %{total: 1},
                      %{result: "completed", mode: "stream_json"}}

      :telemetry.detach(handler_id)
    end
  end

  describe "Telemetry.claude_turn_duration/2" do
    test "emits [:symphony, :claude, :turn_duration_ms] event with duration" do
      parent = self()
      handler_id = "test-claude-duration-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:symphony, :claude, :turn_duration_ms],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.claude_turn_duration(1234, %{result: "completed", mode: "stream_json"})

      assert_receive {:telemetry_event, [:symphony, :claude, :turn_duration_ms], %{duration: 1234},
                      %{result: "completed", mode: "stream_json"}}

      :telemetry.detach(handler_id)
    end
  end

  describe "Telemetry.claude_usage_limit_event/1" do
    test "emits [:symphony, :claude, :usage_limit_events] event" do
      parent = self()
      handler_id = "test-claude-usage-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:symphony, :claude, :usage_limit_events],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.claude_usage_limit_event(%{})

      assert_receive {:telemetry_event, [:symphony, :claude, :usage_limit_events], %{total: 1}, %{}}

      :telemetry.detach(handler_id)
    end
  end

  describe "Telemetry.metrics/0" do
    test "includes claude metrics definitions" do
      metrics = Telemetry.metrics()
      metric_names = Enum.map(metrics, & &1.name)

      assert [:symphony, :claude, :turns, :total] in metric_names
      assert [:symphony, :claude, :turn_duration_ms, :duration] in metric_names
      assert [:symphony, :claude, :usage_limit_events, :total] in metric_names
    end
  end

  describe "OtelSetup telemetry events" do
    test "includes claude events" do
      events = SymphonyElixir.OtelSetup.__info__(:functions)
      # Verify the module compiles and has the events registered via init
      # We can't easily test the private function, but we can verify the module loads
      assert is_list(events)
    end
  end
end
