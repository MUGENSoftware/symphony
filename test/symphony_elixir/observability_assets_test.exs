defmodule SymphonyElixir.ObservabilityAssetsTest do
  use ExUnit.Case, async: true

  test "Prometheus alert rules use current metric names" do
    rules =
      "/Users/john/mugen/symphony-on-claude/observability/prometheus/rules.yml"
      |> File.read!()

    assert rules =~ "symphony_issue_retry_total"
    assert rules =~ "symphony_claude_cooldown_active_value"
    refute rules =~ "symphony_orchestrator_issue_retry_total"
    refute rules =~ "symphony_orchestrator_claude_cooldown_value"
  end

  test "Grafana dashboard uses current metric names" do
    dashboard =
      "/Users/john/mugen/symphony-on-claude/observability/grafana/dashboards/symphony-runtime-health.json"
      |> File.read!()

    assert dashboard =~ "symphony_running_agents_value"
    assert dashboard =~ "symphony_retry_queue_depth_value"
    assert dashboard =~ "symphony_claude_cooldown_active_value"
    assert dashboard =~ "symphony_issue_dispatch_total"
    assert dashboard =~ "symphony_poll_cycle_duration_ms_duration_bucket"
    refute dashboard =~ "symphony_orchestrator_"
  end
end
