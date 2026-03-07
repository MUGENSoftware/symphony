defmodule SymphonyElixir.ClaudeMcpConfigTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Claude.Cli, as: AppServer
  alias SymphonyElixir.Claude.McpConfig
  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Linear.Issue

  setup do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end
    end)

    :ok
  end

  test "stream-json generates a default Linear MCP config and passes it to Claude" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-default-mcp-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-301")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-mcp.trace")
      log_file = Path.join(test_root, "log/symphony.log")
      previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CLAUDE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CLAUDE_TRACE")
        end
      end)

      Application.put_env(:symphony_elixir, :log_file, log_file)
      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-mcp.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf '%s\\n' '{"type":"result","session_id":"session-mcp-default","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "linear-token",
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-mcp-default",
        identifier: "MT-301",
        title: "Default MCP config",
        description: "Ensure generated MCP config is passed to Claude",
        state: "In Progress",
        url: "https://example.org/issues/MT-301",
        labels: ["backend"]
      }

      log =
        capture_log(fn ->
          assert {:ok, %{session_id: "session-mcp-default"}} =
                   AppServer.run(workspace, "hello", issue)
        end)

      generated_path = McpConfig.generated_default_path()
      assert File.exists?(generated_path)

      generated = File.read!(generated_path)
      assert generated =~ ~s("url": "https://mcp.linear.app/mcp")
      assert generated =~ ~s("Authorization": "Bearer linear-token")

      trace = File.read!(trace_file)
      assert String.contains?(trace, "--mcp-config #{generated_path}")
      assert log =~ "Claude MCP config ready source=generated_default"
      assert log =~ "server=https://mcp.linear.app/mcp"
    after
      File.rm_rf(test_root)
    end
  end

  test "stream-json honors user provided claude.mcp_config without rewriting it" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-override-mcp-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-302")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-override-mcp.trace")
      custom_mcp_config = Path.join(test_root, "custom.mcp.json")
      previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CLAUDE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CLAUDE_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)
      File.mkdir_p!(workspace)
      File.write!(custom_mcp_config, ~s({"mcpServers":{"linear":{"type":"http","url":"https://example.invalid/mcp"}}}))

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-override-mcp.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf '%s\\n' '{"type":"result","session_id":"session-mcp-override","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "linear-token",
        claude_command: claude_binary,
        claude_mcp_config: custom_mcp_config
      )

      issue = %Issue{
        id: "issue-mcp-override",
        identifier: "MT-302",
        title: "Override MCP config",
        description: "Use user provided MCP config",
        state: "In Progress",
        url: "https://example.org/issues/MT-302",
        labels: ["backend"]
      }

      original = File.read!(custom_mcp_config)

      log =
        capture_log(fn ->
          assert {:ok, %{session_id: "session-mcp-override"}} =
                   AppServer.run(workspace, "hello", issue)
        end)

      assert File.read!(custom_mcp_config) == original

      trace = File.read!(trace_file)
      assert String.contains?(trace, "--mcp-config #{custom_mcp_config}")
      assert log =~ "Claude MCP config ready source=user_override"
      assert log =~ "path=#{custom_mcp_config}"
    after
      File.rm_rf(test_root)
    end
  end

  test "validate! fails when claude.mcp_config override path is missing" do
    missing_path = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      claude_mcp_config: missing_path
    )

    assert {:error, {:claude_mcp_config_not_found, ^missing_path}} = Config.validate!()
  end

  test "validate! fails when claude.mcp_config override is invalid json" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-invalid-mcp-json-#{System.unique_integer([:positive])}"
      )

    try do
      invalid_path = Path.join(test_root, "invalid.mcp.json")
      File.mkdir_p!(test_root)
      File.write!(invalid_path, "{")

      write_workflow_file!(Workflow.workflow_file_path(),
        claude_mcp_config: invalid_path
      )

      assert {:error, {:invalid_claude_mcp_config_json, ^invalid_path, _reason}} = Config.validate!()
    after
      File.rm_rf(test_root)
    end
  end
end
