defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "app server auto-adds --verbose for stream-json and preserves command args" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stream-json-verbose-#{System.unique_integer([:positive])}"
      )

    try do
      previous_log_file = Application.get_env(:symphony_elixir, :log_file)
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-100")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CLAUDE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CLAUDE_TRACE")
        end

        if previous_log_file do
          Application.put_env(:symphony_elixir, :log_file, previous_log_file)
        else
          Application.delete_env(:symphony_elixir, :log_file)
        end
      end)

      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)
      Application.put_env(:symphony_elixir, :log_file, Path.join(test_root, "log/symphony.jsonl"))
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-args.trace}"
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf '%s\\n' '{"type":"result","session_id":"session-100","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} --model claude-sonnet-4"
      )

      issue = %Issue{
        id: "issue-cli-args",
        identifier: "MT-100",
        title: "Validate stream-json args",
        description: "Ensure --verbose is included",
        state: "In Progress",
        url: "https://example.org/issues/MT-100",
        labels: ["backend"]
      }

      log =
        capture_log(fn ->
          assert {:ok, %{session_id: "session-100"}} = AppServer.run(workspace, "hello", issue)
        end)

      trace = File.read!(trace_file)
      assert String.contains?(trace, "--model claude-sonnet-4")
      assert String.contains?(trace, "--output-format stream-json")
      assert String.contains?(trace, "--verbose")
      assert String.contains?(trace, "-p hello")
      assert log =~ ~s([STREAM_JSON] {"type":"result","session_id":"session-100")

      logs = SymphonyElixir.Claude.SessionLog.list_issue_logs("MT-100")
      assert Enum.any?(logs, &String.ends_with?(&1.path, "latest.jsonl"))
      assert Enum.any?(logs, &(&1.session_id == "session-100"))
    after
      File.rm_rf(test_root)
    end
  end

  test "stream-json wrapper persists raw log output even when no JSON event is parseable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stream-json-raw-log-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      previous_log_file = Application.get_env(:symphony_elixir, :log_file)
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-101")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      on_exit(fn ->
        if previous_log_file do
          Application.put_env(:symphony_elixir, :log_file, previous_log_file)
        else
          Application.delete_env(:symphony_elixir, :log_file)
        end
      end)

      Application.put_env(:symphony_elixir, :log_file, Path.join(test_root, "log/symphony.jsonl"))

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' 'booting stream-json session'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-stream-timeout",
        identifier: "MT-101",
        title: "Persist timeout stream log",
        description: "Ensure raw output is durable on timeout",
        state: "In Progress",
        url: "https://example.org/issues/MT-101",
        labels: ["backend"]
      }

      assert {:ok, %{}} = AppServer.run(workspace, "hello", issue)

      logs = SymphonyElixir.Claude.SessionLog.list_issue_logs("MT-101")
      assert logs != []
      assert Enum.any?(logs, &String.contains?(&1.tail, "booting stream-json session"))
    after
      File.rm_rf(test_root)
    end
  end

  test "stream-json wrapper persists stderr and malformed lines in the raw log file" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stream-json-raw-log-malformed-#{System.unique_integer([:positive])}"
      )

    try do
      previous_log_file = Application.get_env(:symphony_elixir, :log_file)
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-102")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      on_exit(fn ->
        if previous_log_file do
          Application.put_env(:symphony_elixir, :log_file, previous_log_file)
        else
          Application.delete_env(:symphony_elixir, :log_file)
        end
      end)

      Application.put_env(:symphony_elixir, :log_file, Path.join(test_root, "log/symphony.jsonl"))

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' 'warning: stderr noise' >&2
      printf '%s\\n' 'not-json'
      printf '%s\\n' '{"type":"result","session_id":"session-102","usage":{"input_tokens":1,"output_tokens":2}}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-stream-malformed",
        identifier: "MT-102",
        title: "Persist malformed output",
        description: "Ensure stderr and malformed lines are preserved",
        state: "In Progress",
        url: "https://example.org/issues/MT-102",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "session-102"}} = AppServer.run(workspace, "hello", issue)

      logs = SymphonyElixir.Claude.SessionLog.list_issue_logs("MT-102")

      assert Enum.any?(logs, fn log ->
               String.contains?(log.tail, "warning: stderr noise") and
                 String.contains?(log.tail, "not-json") and
                 String.contains?(log.tail, ~s("session_id":"session-102"))
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "stream-json surfaces max-turn exhaustion with resumable session context" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stream-json-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-103")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf '%s\\n' '{"type":"result","subtype":"error_max_turns","session_id":"session-103","stop_reason":"tool_use","num_turns":11,"usage":{"input_tokens":1,"output_tokens":2}}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-stream-max-turns",
        identifier: "MT-103",
        title: "Resume after max turns",
        description: "Ensure the runner exposes resumable max-turn metadata",
        state: "In Progress",
        url: "https://example.org/issues/MT-103",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:stream_json_message, message}) end

      assert {:ok, %{result: :max_turns_exhausted, session_id: "session-103", resume_session_id: "session-103"}} =
               AppServer.run(workspace, "hello", issue, on_message: on_message)

      assert_received {:stream_json_message,
                       %{
                         event: :max_turns_exhausted,
                         session_id: "session-103",
                         resume_session_id: "session-103",
                         message: message
                       }}

      assert message =~ "max-turn limit"
      assert message =~ "Resume with session session-103"
    after
      File.rm_rf(test_root)
    end
  end

  test "usage-limit parser resolves the next reset timestamp in the reported timezone" do
    now = ~U[2026-03-08 07:00:00Z]

    assert {:ok,
            %{
              reason: :usage_cap,
              timezone: "America/Sao_Paulo",
              reset_at: ~U[2026-03-08 09:00:00Z],
              retry_after_ms: 7_200_000
            }} =
             SymphonyElixir.Claude.UsageLimit.parse_message(
               "You've hit your limit · resets 6am (America/Sao_Paulo)",
               now
             )
  end

  test "stream-json surfaces usage-limit exhaustion with cooldown metadata" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stream-json-usage-limit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-104")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      cat <<'EOF'
      {"type":"result","subtype":"success","is_error":true,"duration_ms":893,"duration_api_ms":0,"num_turns":1,"result":"You've hit your limit · resets 6am (America/Sao_Paulo)","stop_reason":"stop_sequence","session_id":"session-104","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}
      EOF
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-stream-usage-limit",
        identifier: "MT-104",
        title: "Pause after usage limit",
        description: "Ensure the runner emits cooldown metadata",
        state: "In Progress",
        url: "https://example.org/issues/MT-104",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:stream_json_message, message}) end

      assert {:ok,
              %{
                result: :usage_limit_reached,
                session_id: "session-104",
                resume_session_id: "session-104"
              }} =
               AppServer.run(workspace, "hello", issue, on_message: on_message)

      assert_received {:stream_json_message,
                       %{
                         event: :usage_limit_reached,
                         session_id: "session-104",
                         resume_session_id: "session-104",
                         message: "You've hit your limit · resets 6am (America/Sao_Paulo)",
                         retry_after_ms: retry_after_ms,
                         reset_at: %DateTime{}
                       }}

      assert retry_after_ms >= 0
    after
      File.rm_rf(test_root)
    end
  end

  test "stream-json falls back to normal completion when a usage-limit reset time cannot be parsed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stream-json-usage-limit-fallback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-105")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      cat <<'EOF'
      {"type":"result","subtype":"success","is_error":true,"duration_ms":500,"result":"You've hit your limit · resets someday","session_id":"session-105","usage":{"input_tokens":0,"output_tokens":0}}
      EOF
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-stream-usage-limit-fallback",
        identifier: "MT-105",
        title: "Fallback after parse failure",
        description: "Ensure unparsed limit text does not activate cooldown",
        state: "In Progress",
        url: "https://example.org/issues/MT-105",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:stream_json_message, message}) end

      assert {:ok, %{session_id: "session-105"}} =
               AppServer.run(workspace, "hello", issue, on_message: on_message)

      assert_received {:stream_json_message,
                       %{
                         event: :turn_completed,
                         session_id: "session-105",
                         result: "You've hit your limit · resets someday"
                       }}

      refute_received {:stream_json_message, %{event: :usage_limit_reached}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-input.trace")
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

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy claude input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-auto-approve.trace")
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

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server",
        claude_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-tool-user-input-auto-approve.trace")
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

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server",
        claude_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server",
        claude_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :tool_input_auto_answered,
                         answer: "This is a non-interactive session. Operator input is unavailable."
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-tool-user-input-options.trace")
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

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-tool-user-input-options.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Use the default behavior.\",\"label\":\"Use default\"},{\"description\":\"Skip this step.\",\"label\":\"Skip\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts receive a generic non-interactive answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 112 and
                   get_in(payload, ["result", "answers", "options-719", "answers"]) == [
                     "This is a non-interactive session. Operator input is unavailable."
                   ]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-tool-call.trace")
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

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   get_in(payload, ["result", "contentItems", Access.at(0), "type"]) == "inputText" and
                   String.contains?(
                     get_in(payload, ["result", "contentItems", Access.at(0), "text"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-supported-tool-call.trace")
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

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "contentItems", Access.at(0), "text"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-tool-call-failed.trace")
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

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures claude side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      claude_binary = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure claude stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      log =
        capture_log(fn ->
          assert {:ok, _result} = AppServer.run(workspace, "Capture stderr log", issue)
        end)

      assert log =~ "Claude Code turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "stream-json resolves bare claude from the current PATH and preserves extra args" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stream-json-path-resolution-#{System.unique_integer([:positive])}"
      )

    try do
      previous_log_file = Application.get_env(:symphony_elixir, :log_file)
      previous_path = System.get_env("PATH")
      previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")
      bin_dir = Path.join(test_root, "bin")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-103")
      claude_binary = Path.join(bin_dir, "claude")
      trace_file = Path.join(test_root, "claude-path.trace")

      on_exit(fn ->
        restore_env("PATH", previous_path)

        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CLAUDE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CLAUDE_TRACE")
        end

        if previous_log_file do
          Application.put_env(:symphony_elixir, :log_file, previous_log_file)
        else
          Application.delete_env(:symphony_elixir, :log_file)
        end
      end)

      File.mkdir_p!(bin_dir)
      File.mkdir_p!(workspace)
      System.put_env("PATH", "#{bin_dir}:/usr/bin:/bin")
      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)
      Application.put_env(:symphony_elixir, :log_file, Path.join(test_root, "log/symphony.jsonl"))

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-path.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf '%s\\n' '{"type":"result","session_id":"session-path","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "claude --model claude-sonnet-4"
      )

      issue = %Issue{
        id: "issue-cli-path",
        identifier: "MT-103",
        title: "Resolve Claude from PATH",
        description: "Use bare claude from PATH",
        state: "In Progress",
        url: "https://example.org/issues/MT-103",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "session-path"}} = AppServer.run(workspace, "hello", issue)

      trace = File.read!(trace_file)
      assert String.contains?(trace, "--model claude-sonnet-4")
      assert String.contains?(trace, "--output-format stream-json")
      assert String.contains?(trace, "--verbose")
      assert String.contains?(trace, "-p hello")
    after
      File.rm_rf(test_root)
    end
  end

  test "stream-json resolves bare claude via login shell PATH fallback" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stream-json-login-shell-#{System.unique_integer([:positive])}"
      )

    try do
      previous_log_file = Application.get_env(:symphony_elixir, :log_file)
      previous_path = System.get_env("PATH")
      previous_home = System.get_env("HOME")
      previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")
      home_dir = Path.join(test_root, "home")
      login_bin = Path.join(test_root, "login-bin")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-104")
      claude_binary = Path.join(login_bin, "claude")
      trace_file = Path.join(test_root, "claude-login.trace")

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("HOME", previous_home)

        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CLAUDE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CLAUDE_TRACE")
        end

        if previous_log_file do
          Application.put_env(:symphony_elixir, :log_file, previous_log_file)
        else
          Application.delete_env(:symphony_elixir, :log_file)
        end
      end)

      File.mkdir_p!(home_dir)
      File.mkdir_p!(login_bin)
      File.mkdir_p!(workspace)
      File.write!(Path.join(home_dir, ".bash_profile"), "export PATH=\"#{login_bin}:$PATH\"\n")
      System.put_env("PATH", "/usr/bin:/bin")
      System.put_env("HOME", home_dir)
      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)
      Application.put_env(:symphony_elixir, :log_file, Path.join(test_root, "log/symphony.jsonl"))

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-login.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf '%s\\n' '{"type":"result","session_id":"session-login","usage":{"input_tokens":1,"output_tokens":1}}'
      exit 0
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "claude --model claude-opus-4"
      )

      issue = %Issue{
        id: "issue-cli-login",
        identifier: "MT-104",
        title: "Resolve Claude via login shell",
        description: "Use login shell fallback",
        state: "In Progress",
        url: "https://example.org/issues/MT-104",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "session-login"}} = AppServer.run(workspace, "hello", issue)

      trace = File.read!(trace_file)
      assert String.contains?(trace, "--model claude-opus-4")
      assert String.contains?(trace, "--output-format stream-json")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server resolves bare claude via login shell PATH fallback" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-login-shell-#{System.unique_integer([:positive])}"
      )

    try do
      previous_path = System.get_env("PATH")
      previous_home = System.get_env("HOME")
      previous_trace = System.get_env("SYMP_TEST_CLAUDE_TRACE")
      home_dir = Path.join(test_root, "home")
      login_bin = Path.join(test_root, "login-bin")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-105")
      claude_binary = Path.join(login_bin, "claude")
      trace_file = Path.join(test_root, "claude-app-server-login.trace")

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("HOME", previous_home)

        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CLAUDE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CLAUDE_TRACE")
        end
      end)

      File.mkdir_p!(home_dir)
      File.mkdir_p!(login_bin)
      File.mkdir_p!(workspace)
      File.write!(Path.join(home_dir, ".bash_profile"), "export PATH=\"#{login_bin}:$PATH\"\n")
      System.put_env("PATH", "/usr/bin:/bin")
      System.put_env("HOME", home_dir)
      System.put_env("SYMP_TEST_CLAUDE_TRACE", trace_file)

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude-app-server-login.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-105"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-105"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "claude app-server"
      )

      issue = %Issue{
        id: "issue-app-server-login",
        identifier: "MT-105",
        title: "Resolve app-server Claude via login shell",
        description: "Use login shell fallback in app-server mode",
        state: "In Progress",
        url: "https://example.org/issues/MT-105",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "thread-105-turn-105"}} = AppServer.run(workspace, "hello", issue)

      trace = File.read!(trace_file)
      assert String.contains?(trace, "ARGV:app-server")
    after
      File.rm_rf(test_root)
    end
  end

  test "run returns a startup error when bare claude cannot be resolved" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-not-found-#{System.unique_integer([:positive])}"
      )

    try do
      previous_path = System.get_env("PATH")
      previous_home = System.get_env("HOME")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-106")
      home_dir = Path.join(test_root, "home")

      on_exit(fn ->
        restore_env("PATH", previous_path)
        restore_env("HOME", previous_home)
      end)

      File.mkdir_p!(home_dir)
      File.mkdir_p!(workspace)
      System.put_env("PATH", "/usr/bin:/bin")
      System.put_env("HOME", home_dir)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "claude --model claude-sonnet-4"
      )

      issue = %Issue{
        id: "issue-cli-missing",
        identifier: "MT-106",
        title: "Report missing Claude binary",
        description: "No claude executable should be resolvable",
        state: "In Progress",
        url: "https://example.org/issues/MT-106",
        labels: ["backend"]
      }

      assert {:error, {:claude_cli_not_found, "claude --model claude-sonnet-4"}} =
               AppServer.run(workspace, "hello", issue)
    after
      File.rm_rf(test_root)
    end
  end
end
