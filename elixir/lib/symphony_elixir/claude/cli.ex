defmodule SymphonyElixir.Claude.Cli do
  @moduledoc """
  Claude Code CLI subprocess client.

  Replaces the previous JSON-RPC client with direct invocations of the
  `claude` CLI using `--output-format stream-json`. Each turn launches a fresh
  subprocess; multi-turn conversations are resumed via `--resume <session_id>`.
  """

  require Logger
  alias SymphonyElixir.Claude.DynamicToolRegistry
  alias SymphonyElixir.Claude.McpConfig
  alias SymphonyElixir.Claude.SessionLog
  alias SymphonyElixir.Claude.UsageLimit
  alias SymphonyElixir.Config

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
    start_result = start_turn_command(starting_port, starting_mode, workspace, prompt, prev_session_id, issue)

    case start_result do
      {:ok, command} ->
        handle_started_turn(command, session, prompt, issue, opts, on_message)

      {:error, reason} ->
        Logger.error("Claude CLI failed to start for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  defp start_turn_command(starting_port, :app_server, _workspace, _prompt, _prev_session_id, _issue)
       when is_port(starting_port) do
    {:ok, %{port: starting_port, mode: :app_server}}
  end

  defp start_turn_command(_starting_port, _starting_mode, workspace, prompt, prev_session_id, issue) do
    start_cli(workspace, prompt, prev_session_id, issue)
  end

  defp handle_started_turn(command, session, prompt, issue, opts, on_message) do
    metadata = command_metadata(command)
    maybe_emit_stream_session_started(command, session, on_message, metadata)
    log_turn_start(issue, session)

    case execute_turn(command, session, prompt, issue, opts, on_message, metadata) do
      {:ok, result} ->
        {:ok, build_turn_response(command, session, result, issue)}

      {:error, reason} ->
        handle_turn_error(reason, issue, session, on_message, metadata)
    end
  end

  defp maybe_emit_stream_session_started(%{mode: :stream_json}, %{session_id: session_id, workspace: workspace}, on_message, metadata) do
    emit_message(
      on_message,
      :session_started,
      %{session_id: session_id, workspace: workspace},
      metadata
    )
  end

  defp maybe_emit_stream_session_started(_command, _session, _on_message, _metadata), do: :ok

  defp log_turn_start(issue, %{session_id: prev_session_id, workspace: workspace}) do
    Logger.info(
      "Claude CLI turn started for #{issue_context(issue)} workspace=#{workspace}" <>
        if(prev_session_id, do: " resume=#{prev_session_id}", else: "")
    )
  end

  defp execute_turn(%{mode: :app_server, port: port}, session, prompt, _issue, opts, on_message, metadata) do
    workspace = Map.fetch!(session, :workspace)
    thread_id = Map.get(session, :thread_id)
    prev_session_id = Map.get(session, :session_id)

    execute_app_server_turn(
      port,
      workspace,
      prompt,
      thread_id || prev_session_id,
      on_message,
      metadata,
      opts
    )
  end

  defp execute_turn(%{mode: :stream_json} = command, _session, _prompt, issue, _opts, on_message, metadata) do
    execute_stream_json_turn(command, on_message, metadata, issue)
  end

  defp build_turn_response(command, %{session_id: prev_session_id, workspace: workspace} = session, result, issue) do
    thread_id = Map.get(session, :thread_id)
    session_id = Map.get(result, :session_id, prev_session_id)
    next_thread_id = Map.get(result, :thread_id, thread_id)
    turn_result = Map.get(result, :result, :turn_completed)

    Logger.info(completion_log_message(turn_result, issue, session_id))

    %{
      result: turn_result,
      session_id: session_id,
      session: next_session(command, workspace, session_id, next_thread_id),
      usage: Map.get(result, :usage),
      resume_session_id: Map.get(result, :resume_session_id, session_id)
    }
  end

  defp next_session(%{mode: :app_server, port: port}, workspace, session_id, thread_id) do
    %{
      session_id: session_id,
      workspace: workspace,
      mode: :app_server,
      port: port,
      thread_id: thread_id
    }
  end

  defp next_session(_command, workspace, session_id, _thread_id) do
    %{session_id: session_id, workspace: workspace}
  end

  defp handle_turn_error(reason, issue, %{session_id: prev_session_id}, on_message, metadata) do
    Logger.warning("Claude CLI turn ended with error for #{issue_context(issue)}: #{inspect(reason)}")

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{session_id: prev_session_id, reason: reason},
      metadata
    )

    {:error, reason}
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
         {:ok, executable} <- resolve_executable(executable_name),
         {:ok, cli_command} <-
           prepare_cli_command(executable, base_args, prompt, resume_session_id, workspace, issue) do
      {:ok, cli_command}
    else
      {:error, :not_found} ->
        {:error, {:claude_cli_not_found, command}}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_command(""), do: {:error, :missing_claude_command}

  defp parse_command(command) when is_binary(command) do
    case split_command(command) do
      [executable_name | base_args] ->
        {:ok, executable_name, base_args}

      _ ->
        {:error, :missing_claude_command}
    end
  rescue
    _error ->
      {:error, {:invalid_claude_command, command}}
  end

  defp resolve_executable(executable_name) when is_binary(executable_name) do
    if String.contains?(executable_name, "/") do
      resolve_path_executable(executable_name)
    else
      resolve_bare_executable(executable_name)
    end
  end

  defp split_command(command), do: OptionParser.split(command)

  defp prepare_cli_command(executable, base_args, prompt, resume_session_id, workspace, issue) do
    mode = command_mode(base_args)

    with {:ok, mcp_details} <- McpConfig.ensure_ready(mode, log?: true) do
      args = build_cli_args(base_args, prompt, resume_session_id, mode, mcp_details)
      expanded_workspace = Path.expand(workspace)

      Logger.debug(
        "Claude CLI starting: #{executable} #{Enum.join(redact_prompt_arg(args), " ")} " <>
          "(cwd=#{expanded_workspace})"
      )

      build_mode_command(mode, executable, args, expanded_workspace, issue)
    end
  end

  defp build_mode_command(:app_server, executable, args, expanded_workspace, _issue) do
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
  end

  defp build_mode_command(:stream_json, executable, args, expanded_workspace, issue) do
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

  defp resolve_path_executable(executable_name) do
    expanded = Path.expand(executable_name)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
        {:ok, expanded}

      {:ok, _stat} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp resolve_bare_executable(executable_name) do
    case System.find_executable(executable_name) do
      executable when is_binary(executable) ->
        {:ok, executable}

      nil ->
        resolve_via_login_shell(executable_name)
    end
  end

  defp resolve_via_login_shell(executable_name) do
    case System.cmd("/bin/bash", ["-lc", "command -v -- \"$1\"", "bash", executable_name], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> case do
          "" -> {:error, :not_found}
          path -> resolve_path_executable(path)
        end

      {_output, _status} ->
        {:error, :not_found}
    end
  rescue
    _error ->
      {:error, :not_found}
  end

  defp build_cli_args(base_args, _prompt, _resume_session_id, :app_server, _mcp_details) do
    base_args
  end

  defp build_cli_args(base_args, prompt, resume_session_id, :stream_json, mcp_details) do
    base_args
    |> maybe_append_flag("--output-format", Config.claude_output_format())
    |> maybe_append_flag("--model", Config.claude_model())
    |> maybe_append_flag("--max-turns", to_string_or_nil(Config.claude_max_turns()))
    |> maybe_append_verbose_for_stream_json()
    |> maybe_append_dangerously_skip_permissions()
    |> maybe_append_flag("--permission-mode", Config.claude_permission_mode())
    |> maybe_append_flag("--mcp-config", mcp_config_path(mcp_details))
    |> maybe_append_flag("--append-system-prompt", Config.claude_append_system_prompt())
    |> maybe_append_allowed_tools()
    |> maybe_append_resume_session(resume_session_id)
    |> maybe_append_prompt(prompt)
  end

  defp mcp_config_path(%{path: path}) when is_binary(path), do: path
  defp mcp_config_path(_details), do: nil

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

  defp maybe_append_dangerously_skip_permissions(args) do
    if Config.claude_dangerously_skip_permissions?() do
      maybe_append_switch(args, "--dangerously-skip-permissions")
    else
      args
    end
  end

  defp maybe_append_allowed_tools(args) do
    if flag_present?(args, "--allowedTools") do
      args
    else
      append_allowed_tools(args, Config.claude_allowed_tools())
    end
  end

  defp append_allowed_tools(args, tools) when is_list(tools) and tools != [] do
    Enum.reduce(tools, args, fn tool, acc -> acc ++ ["--allowedTools", tool] end)
  end

  defp append_allowed_tools(args, _tools), do: args

  defp maybe_append_resume_session(args, resume_session_id) do
    if is_binary(resume_session_id) and resume_session_id != "" do
      maybe_append_flag(args, "--resume", resume_session_id)
    else
      args
    end
  end

  defp maybe_append_prompt(args, prompt) do
    # Pass the prompt as a -p argument rather than via stdin.
    # Sending <<4>> (Ctrl-D) to a pipe doesn't signal EOF to the subprocess,
    # so Claude would hang waiting for more input if we used stdin.
    maybe_append_flag(args, "-p", prompt)
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

        if String.starts_with?(current, flag <> "=") do
          String.replace_prefix(current, flag <> "=", "")
        else
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
             "dynamicTools" => DynamicToolRegistry.tool_specs()
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
      opts_with_workspace = Keyword.put(opts, :workspace, workspace)
      timeout_context = %{stall_timeout: effective_timeout, turn_timeout: turn_timeout, start_ms: now_ms()}

      receive_app_server_loop(
        port,
        on_message,
        metadata,
        opts_with_workspace,
        timeout_context,
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

  defp receive_app_server_loop(port, on_message, metadata, opts, timeout_context, pending, state) do
    timeout = remaining_timeout(timeout_context)

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
              timeout_context,
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
          timeout_context,
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
        Logger.warning(
          "Claude app-server timed out after #{timeout}ms " <>
            "(stall_timeout=#{timeout_context.stall_timeout}, turn_timeout=#{timeout_context.turn_timeout})"
        )

        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp remaining_timeout(%{stall_timeout: stall_timeout, turn_timeout: turn_timeout, start_ms: start_ms}) do
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
      {:ok, %{} = payload} ->
        handle_decoded_stream_payload(payload, line, on_message, metadata)

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

  defp handle_decoded_stream_payload(
         %{"type" => "result", "subtype" => "error_max_turns"} = payload,
         line,
         on_message,
         metadata
       ) do
    session_id = get_in(payload, ["session_id"])
    usage = get_in(payload, ["usage"])
    stop_reason = get_in(payload, ["stop_reason"])
    num_turns = get_in(payload, ["num_turns"])
    message = max_turns_exhausted_message(session_id, stop_reason, num_turns)
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
  end

  defp handle_decoded_stream_payload(%{"type" => "result"} = payload, line, on_message, metadata) do
    handle_result_payload(payload, line, on_message, metadata)
  end

  defp handle_decoded_stream_payload(%{"type" => "error"} = payload, line, on_message, metadata) do
    error_message = Map.get(payload, "error", "unknown error")

    emit_message(
      on_message,
      :turn_failed,
      %{payload: payload, raw: line, error: error_message},
      metadata
    )

    {:error, {:claude_error, error_message}}
  end

  defp handle_decoded_stream_payload(%{"type" => "init"} = payload, line, on_message, metadata) do
    session_id = get_in(payload, ["session_id"])

    emit_message(
      on_message,
      :init,
      %{payload: payload, raw: line, session_id: session_id},
      metadata
    )

    {:continue, metadata}
  end

  defp handle_decoded_stream_payload(%{"type" => "assistant"} = payload, line, on_message, metadata) do
    emit_message(
      on_message,
      :assistant,
      %{payload: payload, raw: line},
      maybe_set_usage(metadata, payload)
    )

    {:continue, metadata}
  end

  defp handle_decoded_stream_payload(%{"type" => "system"} = payload, line, on_message, metadata) do
    emit_message(
      on_message,
      :system,
      %{payload: payload, raw: line},
      metadata
    )

    {:continue, metadata}
  end

  defp handle_decoded_stream_payload(%{"type" => type} = payload, line, on_message, metadata) do
    emit_message(
      on_message,
      :notification,
      %{payload: payload, raw: line, type: type},
      metadata
    )

    {:continue, metadata}
  end

  defp handle_app_server_line(line, port, on_message, metadata, opts, state) do
    case Jason.decode(line) do
      {:ok, %{} = payload} ->
        handle_decoded_app_server_payload(payload, line, port, on_message, metadata, opts, state)

      {:error, _reason} ->
        log_non_json_stream_line(line)
        emit_message(on_message, :malformed, %{payload: line, raw: line}, metadata)
        {:continue, state}
    end
  end

  defp handle_decoded_app_server_payload(
         %{"method" => "turn/completed"} = payload,
         line,
         _port,
         on_message,
         metadata,
         _opts,
         state
       ) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)

    {:done,
     %{
       session_id: build_app_server_session_id(state),
       thread_id: Map.get(state, :thread_id)
     }}
  end

  defp handle_decoded_app_server_payload(
         %{"method" => "turn/input_required"} = payload,
         line,
         _port,
         on_message,
         metadata,
         _opts,
         _state
       ) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
    {:error, {:turn_input_required, payload}}
  end

  defp handle_decoded_app_server_payload(
         %{"id" => id, "method" => "item/commandExecution/requestApproval"} = payload,
         line,
         port,
         on_message,
         metadata,
         _opts,
         state
       ) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)

    if auto_approval_enabled?() do
      :ok = send_json_line(port, %{"id" => id, "result" => %{"decision" => "acceptForSession"}})
      emit_message(on_message, :approval_auto_approved, %{payload: payload}, metadata)
      {:continue, state}
    else
      {:error, {:approval_required, payload}}
    end
  end

  defp handle_decoded_app_server_payload(
         %{"id" => id, "method" => "item/tool/requestUserInput", "params" => params} = payload,
         line,
         port,
         on_message,
         metadata,
         _opts,
         state
       ) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
    answers = build_tool_input_answers(params)
    :ok = send_json_line(port, %{"id" => id, "result" => %{"answers" => answers}})

    emit_message(
      on_message,
      :tool_input_auto_answered,
      %{payload: payload, answer: first_answer_text(answers)},
      metadata
    )

    {:continue, state}
  end

  defp handle_decoded_app_server_payload(
         %{"id" => id, "method" => "item/tool/call", "params" => params} = payload,
         line,
         port,
         on_message,
         metadata,
         opts,
         state
       ) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
    tool_name = params["tool"] || params["name"] || "unknown_tool"
    arguments = params["arguments"] || %{}
    tool_executor = Keyword.get(opts, :tool_executor, &DynamicToolRegistry.execute/3)
    tool_opts = Keyword.take(opts, [:workspace])
    result = safe_execute_tool(tool_executor, tool_name, arguments, tool_opts)
    :ok = send_json_line(port, %{"id" => id, "result" => result})

    emit_message(
      on_message,
      tool_event(tool_name, result),
      %{payload: payload, result: result},
      metadata
    )

    {:continue, state}
  end

  defp handle_decoded_app_server_payload(
         %{"id" => 2, "result" => %{"thread" => %{"id" => thread_id}}} = payload,
         line,
         _port,
         on_message,
         metadata,
         _opts,
         state
       ) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
    {:continue, Map.put(state, :thread_id, thread_id)}
  end

  defp handle_decoded_app_server_payload(
         %{"id" => 3, "result" => %{"turn" => %{"id" => turn_id}}} = payload,
         line,
         _port,
         on_message,
         metadata,
         _opts,
         state
       ) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)

    next_state = Map.put(state, :turn_id, turn_id)
    emit_message(on_message, :session_started, %{session_id: build_app_server_session_id(next_state)}, metadata)
    {:continue, next_state}
  end

  defp handle_decoded_app_server_payload(payload, line, _port, on_message, metadata, _opts, state) do
    emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
    {:continue, state}
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

  defp first_answer_text(answers) when is_map(answers) do
    answers
    |> Map.values()
    |> List.first()
    |> case do
      %{"answers" => [answer | _rest]} -> answer
      _ -> nil
    end
  end

  defp tool_event(tool_name, result) do
    cond do
      unsupported_tool?(tool_name) -> :unsupported_tool_call
      result["success"] == true -> :tool_call_completed
      true -> :tool_call_failed
    end
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

  defp safe_execute_tool(tool_executor, tool_name, arguments, tool_opts)
       when is_function(tool_executor, 3) do
    tool_executor.(tool_name, arguments, tool_opts)
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

  # Support legacy arity-2 tool executors (used in tests)
  defp safe_execute_tool(tool_executor, tool_name, arguments, _tool_opts)
       when is_function(tool_executor, 2) do
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
    not Enum.member?(DynamicToolRegistry.supported_tool_names(), tool_name)
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

  defp completion_log_message(:usage_limit_reached, issue, session_id) do
    "Claude CLI usage limit reached for #{issue_context(issue)} session_id=#{session_id}; cooldown active"
  end

  defp completion_log_message(_turn_result, issue, session_id) do
    "Claude CLI turn completed for #{issue_context(issue)} session_id=#{session_id}"
  end

  defp handle_result_payload(payload, line, on_message, metadata) do
    case UsageLimit.parse_result(payload) do
      {:ok, usage_limit} ->
        session_id = get_in(payload, ["session_id"])
        usage = get_in(payload, ["usage"])
        cost_usd = get_in(payload, ["cost_usd"])
        result_metadata = maybe_set_usage(metadata, payload)

        emit_message(
          on_message,
          :usage_limit_reached,
          %{
            payload: payload,
            raw: line,
            result: usage_limit.message,
            message: usage_limit.message,
            session_id: session_id,
            cost_usd: cost_usd,
            reason: usage_limit.reason,
            reset_at: usage_limit.reset_at,
            retry_after_ms: usage_limit.retry_after_ms,
            timezone: usage_limit.timezone,
            resume_session_id: session_id
          },
          result_metadata
        )

        {:done,
         %{
           session_id: session_id,
           usage: usage,
           result: :usage_limit_reached,
           resume_session_id: session_id,
           reset_at: usage_limit.reset_at,
           retry_after_ms: usage_limit.retry_after_ms
         }}

      {:error, reason} ->
        Logger.warning("Failed to parse Claude usage-limit reset time: #{inspect(reason)}")
        complete_result_payload(payload, line, on_message, metadata)

      :no_match ->
        complete_result_payload(payload, line, on_message, metadata)
    end
  end

  defp complete_result_payload(payload, line, on_message, metadata) do
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
