defmodule SymphonyElixir.Claude.Cli do
  @moduledoc """
  Claude Code CLI subprocess client.

  Replaces the previous JSON-RPC client with direct invocations of the
  `claude` CLI using `--output-format stream-json`. Each turn launches a fresh
  subprocess; multi-turn conversations are resumed via `--resume <session_id>`.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Claude.DynamicTool
  alias SymphonyElixir.Claude.SessionLog

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  # ── Types ──────────────────────────────────────────────────────────────

  @type session :: %{
          session_id: String.t() | nil,
          workspace: Path.t()
        }

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Run a single turn against the Claude CLI in `workspace`.

  This is the simple, one-shot entry point. It creates a transient session,
  executes the turn, and returns.
  """
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with :ok <- validate_workspace_cwd(workspace) do
      session = %{session_id: nil, workspace: Path.expand(workspace)}
      run_turn(session, prompt, issue, opts)
    end
  end

  @doc """
  Run a turn on an existing session.

  When `session.session_id` is non-nil the CLI is invoked with
  `--resume <session_id>` so that prior conversation context is preserved.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{session_id: prev_session_id, workspace: workspace} = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    starting_port = Map.get(session, :port)
    starting_mode = Map.get(session, :mode)
    thread_id = Map.get(session, :thread_id)

    start_result =
      if is_port(starting_port) and starting_mode == :app_server do
        {:ok, %{port: starting_port, mode: :app_server}}
      else
        start_cli(workspace, prompt, prev_session_id, issue)
      end

    case start_result do
      {:ok, %{mode: mode} = command} ->
        metadata = command_metadata(command)

        if mode == :stream_json do
          emit_message(
            on_message,
            :session_started,
            %{session_id: prev_session_id, workspace: workspace},
            metadata
          )
        end

        Logger.info(
          "Claude CLI turn started for #{issue_context(issue)} workspace=#{workspace}" <>
            if(prev_session_id, do: " resume=#{prev_session_id}", else: "")
        )

        result =
          case mode do
            :app_server ->
              execute_app_server_turn(
                command.port,
                workspace,
                prompt,
                thread_id || prev_session_id,
                on_message,
                metadata,
                opts
              )

            :stream_json ->
              execute_stream_json_turn(command, on_message, metadata, issue)
          end

        case result do
          {:ok, result} ->
            session_id = Map.get(result, :session_id, prev_session_id)
            next_thread_id = Map.get(result, :thread_id, thread_id)
            turn_result = Map.get(result, :result, :turn_completed)
            completion_log_message = completion_log_message(turn_result, issue, session_id)

            Logger.info(completion_log_message)

            session =
              case mode do
                :app_server ->
                  %{
                    session_id: session_id,
                    workspace: workspace,
                    mode: :app_server,
                    port: command.port,
                    thread_id: next_thread_id
                  }

                :stream_json ->
                  %{session_id: session_id, workspace: workspace}
              end

            {:ok,
             %{
               result: turn_result,
               session_id: session_id,
               session: session,
               usage: Map.get(result, :usage),
               resume_session_id: Map.get(result, :resume_session_id, session_id)
             }}

          {:error, reason} ->
            Logger.warning("Claude CLI turn ended with error for #{issue_context(issue)}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{session_id: prev_session_id, reason: reason},
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude CLI failed to start for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @doc """
  No-op. Each CLI invocation is independent; there is no long-running process
  to tear down.
  """
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
    :ok
  end

  def stop_session(_session), do: :ok

  # ── Workspace validation ───────────────────────────────────────────────

  @doc false
  @spec validate_workspace_cwd(Path.t()) :: :ok | {:error, term()}
  def validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())

    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  # ── CLI subprocess ─────────────────────────────────────────────────────

  defp start_cli(workspace, prompt, resume_session_id, issue) do
    command = Config.claude_command() |> to_string() |> String.trim()

    with {:ok, executable_name, base_args} <- parse_command(command),
         executable when is_binary(executable) <- System.find_executable(executable_name) do
      mode = command_mode(base_args)
      args = build_cli_args(base_args, prompt, resume_session_id, mode)

      expanded_workspace = Path.expand(workspace)

      Logger.debug("Claude CLI starting: #{executable} #{Enum.join(redact_prompt_arg(args), " ")} (cwd=#{expanded_workspace})")

      case mode do
        :app_server ->
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(executable)},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                args: Enum.map(args, &String.to_charlist/1),
                cd: String.to_charlist(expanded_workspace),
                line: @port_line_bytes
              ]
            )

          {:ok, %{port: port, mode: :app_server}}

        :stream_json ->
          with {:ok, log_ref} <- SessionLog.begin_turn(issue.identifier) do
            {:ok,
             %{
               executable: executable,
               args: args,
               workspace: expanded_workspace,
               mode: :stream_json,
               log_ref: log_ref
             }}
          end
      end
    else
      nil ->
        {:error, {:claude_cli_not_found, command}}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_command(""), do: {:error, :missing_claude_command}

  defp parse_command(command) when is_binary(command) do
    try do
      case OptionParser.split(command) do
        [executable_name | base_args] ->
          {:ok, executable_name, base_args}

        _ ->
          {:error, :missing_claude_command}
      end
    rescue
      _error ->
        {:error, {:invalid_claude_command, command}}
    end
  end

  defp build_cli_args(base_args, _prompt, _resume_session_id, :app_server) do
    base_args
  end

  defp build_cli_args(base_args, prompt, resume_session_id, :stream_json) do
    args = base_args
    args = maybe_append_flag(args, "--output-format", Config.claude_output_format())

    args = maybe_append_flag(args, "--model", Config.claude_model())
    args = maybe_append_flag(args, "--max-turns", to_string_or_nil(Config.claude_max_turns()))
    args = maybe_append_verbose_for_stream_json(args)

    args =
      if Config.claude_dangerously_skip_permissions?() do
        maybe_append_switch(args, "--dangerously-skip-permissions")
      else
        args
      end

    args = maybe_append_flag(args, "--permission-mode", Config.claude_permission_mode())
    args = maybe_append_flag(args, "--mcp-config", Config.claude_mcp_config())
    args = maybe_append_flag(args, "--append-system-prompt", Config.claude_append_system_prompt())

    args =
      if flag_present?(args, "--allowedTools") do
        args
      else
        case Config.claude_allowed_tools() do
          tools when is_list(tools) and tools != [] ->
            Enum.reduce(tools, args, fn tool, acc ->
              acc ++ ["--allowedTools", tool]
            end)

          _ ->
            args
        end
      end

    args =
      if is_binary(resume_session_id) and resume_session_id != "" do
        maybe_append_flag(args, "--resume", resume_session_id)
      else
        args
      end

    # Pass the prompt as a -p argument rather than via stdin.
    # Sending <<4>> (Ctrl-D) to a pipe doesn't signal EOF to the subprocess,
    # so Claude would hang waiting for more input if we used stdin.
    maybe_append_flag(args, "-p", prompt)
  end

  defp command_mode(base_args) when is_list(base_args) do
    if Enum.any?(base_args, &(&1 == "app-server")) do
      :app_server
    else
      :stream_json
    end
  end

  defp maybe_append_flag(args, _flag, nil), do: args
  defp maybe_append_flag(args, _flag, ""), do: args

  defp maybe_append_flag(args, flag, value) do
    if flag_present?(args, flag) do
      args
    else
      args ++ [flag, value]
    end
  end

  defp maybe_append_switch(args, flag) do
    if flag_present?(args, flag), do: args, else: args ++ [flag]
  end

  defp maybe_append_verbose_for_stream_json(args) do
    stream_json? =
      case flag_value(args, "--output-format") do
        nil -> Config.claude_output_format() == "stream-json"
        value -> value == "stream-json"
      end

    if stream_json? do
      maybe_append_switch(args, "--verbose")
    else
      args
    end
  end

  defp flag_present?(args, flag) when is_list(args) and is_binary(flag) do
    Enum.any?(args, fn arg -> arg == flag or String.starts_with?(arg, flag <> "=") end)
  end

  defp flag_value(args, flag) when is_list(args) and is_binary(flag) do
    case Enum.find_index(args, fn arg -> arg == flag or String.starts_with?(arg, flag <> "=") end) do
      nil ->
        nil

      index ->
        current = Enum.at(args, index)

        cond do
          String.starts_with?(current, flag <> "=") ->
            String.replace_prefix(current, flag <> "=", "")

          true ->
            Enum.at(args, index + 1)
        end
    end
  end

  defp redact_prompt_arg(args) when is_list(args) do
    case Enum.find_index(args, &(&1 == "-p")) do
      nil -> args
      index -> List.replace_at(args, index + 1, "<prompt>")
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(value) when is_binary(value), do: value

  # ── Stream parsing ─────────────────────────────────────────────────────

  defp execute_stream_json_turn(command, on_message, metadata, _issue) do
    timeout = min(Config.claude_turn_timeout_ms(), Config.claude_stall_timeout_ms())
    wrapper = stream_wrapper_path()
    log_path = command.log_ref.pending_path

    task =
      Task.async(fn ->
        System.cmd(
          "/bin/bash",
          [wrapper, log_path, command.executable | command.args],
          cd: command.workspace,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, status}} ->
        parsed_result = parse_stream_output(read_stream_log(command.log_ref.pending_path), on_message, metadata)
        finalize_stream_json_log(command.log_ref, parsed_result)

        case parsed_result do
          {:ok, result} ->
            {:ok, result}

          :continue when status == 0 ->
            Logger.info("Claude CLI port exited normally (status=0)")
            {:ok, %{}}

          :continue ->
            Logger.warning("Claude CLI port exited with status=#{status}")
            {:error, {:port_exit, status}}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        Logger.warning("Claude CLI stream timed out after #{timeout}ms (stall_timeout=#{Config.claude_stall_timeout_ms()}, turn_timeout=#{Config.claude_turn_timeout_ms()})")

        parse_stream_output(read_stream_log(command.log_ref.pending_path), on_message, metadata)
        finalize_stream_json_log(command.log_ref, :continue)
        {:error, :turn_timeout}
    end
  end

  defp execute_app_server_turn(
         port,
         workspace,
         prompt,
         previous_thread_id,
         on_message,
         metadata,
         opts
       ) do
    setup_requests =
      if is_binary(previous_thread_id) and previous_thread_id != "" do
        [
          {3, "turn/start",
           %{
             "cwd" => Path.expand(workspace),
             "approvalPolicy" => Config.claude_approval_policy(),
             "sandboxPolicy" => Config.claude_turn_sandbox_policy(workspace),
             "threadId" => previous_thread_id,
             "input" => turn_input_payload(prompt)
           }
           |> reject_nil_values()},
          {4, "turn/input", %{"input" => turn_input_payload(prompt)}}
        ]
      else
        [
          {1, "initialize", %{"capabilities" => %{"experimentalApi" => true}}},
          {2, "thread/start",
           %{
             "cwd" => Path.expand(workspace),
             "approvalPolicy" => Config.claude_approval_policy(),
             "sandbox" => Config.claude_thread_sandbox(),
             "dynamicTools" => DynamicTool.tool_specs()
           }
           |> reject_nil_values()},
          {3, "turn/start",
           %{
             "cwd" => Path.expand(workspace),
             "approvalPolicy" => Config.claude_approval_policy(),
             "sandboxPolicy" => Config.claude_turn_sandbox_policy(workspace),
             "input" => turn_input_payload(prompt)
           }
           |> reject_nil_values()},
          {4, "turn/input", %{"input" => turn_input_payload(prompt)}}
        ]
      end

    with :ok <- send_app_server_requests(port, setup_requests) do
      turn_timeout = Config.claude_turn_timeout_ms()
      stall_timeout = Config.claude_stall_timeout_ms()
      effective_timeout = min(turn_timeout, stall_timeout)

      receive_app_server_loop(
        port,
        on_message,
        metadata,
        opts,
        effective_timeout,
        turn_timeout,
        now_ms(),
        "",
        %{thread_id: previous_thread_id}
      )
    end
  end

  defp send_app_server_requests(_port, []), do: :ok

  defp send_app_server_requests(port, [{id, method, params} | rest]) do
    payload = %{"id" => id, "method" => method, "params" => params}

    case send_json_line(port, payload) do
      :ok -> send_app_server_requests(port, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_app_server_loop(
         port,
         on_message,
         metadata,
         opts,
         stall_timeout,
         turn_timeout,
         start_ms,
         pending,
         state
       ) do
    timeout = remaining_timeout(stall_timeout, turn_timeout, start_ms)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending <> to_string(chunk)
        Logger.debug("Claude app-server line: #{String.slice(line, 0, 500)}")

        case handle_app_server_line(line, port, on_message, metadata, opts, state) do
          {:continue, next_state} ->
            receive_app_server_loop(
              port,
              on_message,
              metadata,
              opts,
              stall_timeout,
              turn_timeout,
              start_ms,
              "",
              next_state
            )

          {:done, result} ->
            {:ok, result}

          {:error, reason} ->
            drain_port(port)
            {:error, reason}
        end

      {^port, {:data, {:noeol, chunk}}} ->
        receive_app_server_loop(
          port,
          on_message,
          metadata,
          opts,
          stall_timeout,
          turn_timeout,
          start_ms,
          pending <> to_string(chunk),
          state
        )

      {^port, {:exit_status, 0}} ->
        Logger.info("Claude app-server exited normally (status=0)")
        {:ok, %{session_id: Map.get(state, :thread_id)}}

      {^port, {:exit_status, status}} ->
        Logger.warning("Claude app-server exited with status=#{status}")
        {:error, {:port_exit, status}}
    after
      timeout ->
        Logger.warning("Claude app-server timed out after #{timeout}ms (stall_timeout=#{stall_timeout}, turn_timeout=#{turn_timeout})")

        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp remaining_timeout(stall_timeout, turn_timeout, start_ms) do
    elapsed = now_ms() - start_ms
    remaining_turn = max(turn_timeout - elapsed, 0)
    min(stall_timeout, remaining_turn)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp parse_stream_output(output, on_message, metadata) when is_binary(output) do
    output
    |> sanitize_stream_output()
    |> String.split("\n", trim: true)
    |> Enum.reduce_while(:continue, fn line, _acc ->
      case handle_stream_line(line, on_message, metadata) do
        {:continue, _updated_metadata} -> {:cont, :continue}
        {:done, result} -> {:halt, {:ok, result}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_stream_log(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  defp sanitize_stream_output(output) when is_binary(output) do
    output
    |> String.replace(~r/\e\][^\a]*(?:\a|\e\\)/u, "")
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/u, "")
    |> strip_non_printable_controls()
  end

  defp strip_non_printable_controls(output) when is_binary(output) do
    output
    |> String.to_charlist()
    |> Enum.filter(fn char ->
      char in [?\n, ?\r, ?\t] or char >= 32
    end)
    |> to_string()
  end

  # ── Event handling ─────────────────────────────────────────────────────

  defp handle_stream_line(line, on_message, metadata) do
    append_stream_log(line)

    case Jason.decode(line) do
      {:ok, %{"type" => "result", "subtype" => "error_max_turns"} = payload} ->
        session_id = get_in(payload, ["session_id"])
        usage = get_in(payload, ["usage"])
        stop_reason = get_in(payload, ["stop_reason"])
        num_turns = get_in(payload, ["num_turns"])

        message =
          max_turns_exhausted_message(session_id, stop_reason, num_turns)

        result_metadata = maybe_set_usage(metadata, payload)

        emit_message(
          on_message,
          :max_turns_exhausted,
          %{
            payload: payload,
            raw: line,
            message: message,
            session_id: session_id,
            stop_reason: stop_reason,
            num_turns: num_turns,
            resume_session_id: session_id
          },
          result_metadata
        )

        {:done,
         %{
           session_id: session_id,
           usage: usage,
           result: :max_turns_exhausted,
           resume_session_id: session_id
         }}

      {:ok, %{"type" => "result"} = payload} ->
        session_id = get_in(payload, ["session_id"])
        usage = get_in(payload, ["usage"])
        cost_usd = get_in(payload, ["cost_usd"])
        result_text = get_in(payload, ["result"])

        result_metadata = maybe_set_usage(metadata, payload)

        emit_message(
          on_message,
          :turn_completed,
          %{
            payload: payload,
            raw: line,
            result: result_text,
            session_id: session_id,
            cost_usd: cost_usd
          },
          result_metadata
        )

        {:done, %{session_id: session_id, usage: usage}}

      {:ok, %{"type" => "error"} = payload} ->
        error_message = Map.get(payload, "error", "unknown error")

        emit_message(
          on_message,
          :turn_failed,
          %{payload: payload, raw: line, error: error_message},
          metadata
        )

        {:error, {:claude_error, error_message}}

      {:ok, %{"type" => "init"} = payload} ->
        session_id = get_in(payload, ["session_id"])

        emit_message(
          on_message,
          :init,
          %{payload: payload, raw: line, session_id: session_id},
          metadata
        )

        {:continue, metadata}

      {:ok, %{"type" => "assistant"} = payload} ->
        emit_message(
          on_message,
          :assistant,
          %{payload: payload, raw: line},
          maybe_set_usage(metadata, payload)
        )

        {:continue, metadata}

      {:ok, %{"type" => "system"} = payload} ->
        emit_message(
          on_message,
          :system,
          %{payload: payload, raw: line},
          metadata
        )

        {:continue, metadata}

      {:ok, %{"type" => type} = payload} ->
        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: line, type: type},
          metadata
        )

        {:continue, metadata}

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{payload: payload, raw: line},
          metadata
        )

        {:continue, metadata}

      {:error, _reason} ->
        log_non_json_stream_line(line)

        emit_message(
          on_message,
          :malformed,
          %{payload: line, raw: line},
          metadata
        )

        {:continue, metadata}
    end
  end

  defp handle_app_server_line(line, port, on_message, metadata, opts, state) do
    case Jason.decode(line) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)

        {:done,
         %{
           session_id: build_app_server_session_id(state),
           thread_id: Map.get(state, :thread_id)
         }}

      {:ok, %{"method" => "turn/input_required"} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
        {:error, {:turn_input_required, payload}}

      {:ok, %{"id" => id, "method" => "item/commandExecution/requestApproval"} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)

        if auto_approval_enabled?() do
          :ok = send_json_line(port, %{"id" => id, "result" => %{"decision" => "acceptForSession"}})
          emit_message(on_message, :approval_auto_approved, %{payload: payload}, metadata)
          {:continue, state}
        else
          {:error, {:approval_required, payload}}
        end

      {:ok, %{"id" => id, "method" => "item/tool/requestUserInput", "params" => params} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
        answers = build_tool_input_answers(params)
        :ok = send_json_line(port, %{"id" => id, "result" => %{"answers" => answers}})

        answered_text =
          answers
          |> Map.values()
          |> List.first()
          |> Map.get("answers", [])
          |> List.first()

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, answer: answered_text},
          metadata
        )

        {:continue, state}

      {:ok, %{"id" => id, "method" => "item/tool/call", "params" => params} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)

        tool_name = params["tool"] || params["name"] || "unknown_tool"
        arguments = params["arguments"] || %{}
        tool_executor = Keyword.get(opts, :tool_executor, &DynamicTool.execute/2)
        result = safe_execute_tool(tool_executor, tool_name, arguments)
        :ok = send_json_line(port, %{"id" => id, "result" => result})

        event =
          cond do
            unsupported_tool?(tool_name) -> :unsupported_tool_call
            result["success"] == true -> :tool_call_completed
            true -> :tool_call_failed
          end

        emit_message(on_message, event, %{payload: payload, result: result}, metadata)
        {:continue, state}

      {:ok, %{"id" => 2, "result" => %{"thread" => %{"id" => thread_id}}} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
        {:continue, Map.put(state, :thread_id, thread_id)}

      {:ok, %{"id" => 3, "result" => %{"turn" => %{"id" => turn_id}}} = payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)

        next_state = Map.put(state, :turn_id, turn_id)

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: build_app_server_session_id(next_state)
          },
          metadata
        )

        {:continue, next_state}

      {:ok, payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
        {:continue, state}

      {:error, _reason} ->
        log_non_json_stream_line(line)
        emit_message(on_message, :malformed, %{payload: line, raw: line}, metadata)
        {:continue, state}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp send_json_line(port, payload) when is_port(port) and is_map(payload) do
    encoded = Jason.encode!(payload) <> "\n"

    case Port.command(port, encoded) do
      true -> :ok
      false -> {:error, :port_write_failed}
    end
  end

  defp reject_nil_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp auto_approval_enabled? do
    Config.claude_approval_policy() == "never"
  end

  defp build_app_server_session_id(state) when is_map(state) do
    thread_id = Map.get(state, :thread_id)
    turn_id = Map.get(state, :turn_id)

    cond do
      is_binary(thread_id) and is_binary(turn_id) -> thread_id <> "-" <> turn_id
      is_binary(thread_id) -> thread_id
      true -> nil
    end
  end

  defp build_tool_input_answers(%{"questions" => questions}) when is_list(questions) do
    Enum.reduce(questions, %{}, fn question, acc ->
      question_id = question["id"] || "answer"

      answer =
        if mcp_approval_question?(question) and auto_approval_enabled?() do
          "Approve this Session"
        else
          "This is a non-interactive session. Operator input is unavailable."
        end

      Map.put(acc, question_id, %{"answers" => [answer]})
    end)
  end

  defp build_tool_input_answers(_params), do: %{}

  defp turn_input_payload(prompt) when is_binary(prompt) do
    [%{"type" => "text", "text" => prompt}]
  end

  defp mcp_approval_question?(%{"id" => id}) when is_binary(id) do
    String.starts_with?(id, "mcp_tool_call_approval_")
  end

  defp mcp_approval_question?(_question), do: false

  defp safe_execute_tool(tool_executor, tool_name, arguments) when is_function(tool_executor, 2) do
    tool_executor.(tool_name, arguments)
  rescue
    error ->
      %{
        "success" => false,
        "contentItems" => [
          %{
            "type" => "inputText",
            "text" =>
              Jason.encode!(%{
                "error" => %{
                  "message" => "Dynamic tool execution raised an exception.",
                  "reason" => Exception.message(error)
                }
              })
          }
        ]
      }
  end

  defp unsupported_tool?(tool_name) do
    supported = Enum.map(DynamicTool.tool_specs(), & &1["name"])
    not Enum.member?(supported, tool_name)
  end

  defp command_metadata(%{mode: :app_server, port: port}), do: port_metadata(port)

  defp command_metadata(%{mode: :stream_json, log_ref: log_ref}) do
    %{claude_session_log_path: log_ref.pending_path}
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{claude_cli_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp completion_log_message(:max_turns_exhausted, issue, session_id) do
    "Claude CLI turn reached max turns for #{issue_context(issue)} session_id=#{session_id}; ready to resume"
  end

  defp completion_log_message(_turn_result, issue, session_id) do
    "Claude CLI turn completed for #{issue_context(issue)} session_id=#{session_id}"
  end

  defp max_turns_exhausted_message(session_id, stop_reason, num_turns) do
    turns =
      if is_integer(num_turns) do
        " after #{num_turns} turns"
      else
        ""
      end

    stop_reason_suffix =
      if is_binary(stop_reason) and stop_reason != "" do
        " (last stop reason: #{stop_reason})"
      else
        ""
      end

    session_suffix =
      if is_binary(session_id) and session_id != "" do
        " Resume with session #{session_id}."
      else
        ""
      end

    "Claude reached its max-turn limit#{turns}#{stop_reason_suffix}.#{session_suffix}"
  end

  defp log_non_json_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude Code turn stream output: #{text}")
      else
        Logger.debug("Claude Code turn stream output: #{text}")
      end
    end
  end

  defp drain_port(port) when is_port(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> drain_port(port)
    after
      5_000 -> stop_port(port)
    end
  end

  defp append_stream_log(line) do
    Logger.info("[STREAM_JSON] #{line}")
  end

  defp finalize_stream_json_log(log_ref, parsed_result) do
    session_id =
      case parsed_result do
        {:ok, %{session_id: session_id}} -> session_id
        _ -> nil
      end

    case SessionLog.finish_turn(log_ref, session_id) do
      {:ok, _path} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to finalize Claude session log: #{inspect(reason)}")
    end
  end

  defp stream_wrapper_path do
    Path.expand("../../../scripts/claude_stream_wrapper.sh", __DIR__)
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end
end
