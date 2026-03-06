defmodule SymphonyElixir.Claude.Cli do
  @moduledoc """
  Claude Code CLI subprocess client.

  Replaces the previous JSON-RPC client with direct invocations of the
  `claude` CLI using `--output-format stream-json`. Each turn launches a fresh
  subprocess; multi-turn conversations are resumed via `--resume <session_id>`.
  """

  require Logger
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
        %{session_id: prev_session_id, workspace: workspace} = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    case start_cli(workspace, prompt, prev_session_id) do
      {:ok, port} ->
        metadata = port_metadata(port)

        emit_message(
          on_message,
          :session_started,
          %{session_id: prev_session_id, workspace: workspace},
          metadata
        )

        Logger.info(
          "Claude CLI turn started for #{issue_context(issue)} workspace=#{workspace}" <>
            if(prev_session_id, do: " resume=#{prev_session_id}", else: "")
        )

        case receive_stream(port, on_message, metadata) do
          {:ok, result} ->
            session_id = Map.get(result, :session_id, prev_session_id)

            Logger.info(
              "Claude CLI turn completed for #{issue_context(issue)} session_id=#{session_id}"
            )

            {:ok,
             %{
               result: :turn_completed,
               session_id: session_id,
               session: %{session_id: session_id, workspace: workspace},
               usage: Map.get(result, :usage)
             }}

          {:error, reason} ->
            Logger.warning(
              "Claude CLI turn ended with error for #{issue_context(issue)}: #{inspect(reason)}"
            )

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
        {:error,
         {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  # ── CLI subprocess ─────────────────────────────────────────────────────

  defp start_cli(workspace, prompt, resume_session_id) do
    command = Config.claude_command() |> to_string() |> String.trim()

    with {:ok, executable_name, base_args} <- parse_command(command),
         executable when is_binary(executable) <- System.find_executable(executable_name) do
      args = build_cli_args(base_args, prompt, resume_session_id)

      expanded_workspace = Path.expand(workspace)

      Logger.debug(
        "Claude CLI starting: #{executable} #{Enum.join(redact_prompt_arg(args), " ")} (cwd=#{expanded_workspace})"
      )

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

      {:ok, port}
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

  defp build_cli_args(base_args, prompt, resume_session_id) do
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

  defp receive_stream(port, on_message, metadata) do
    turn_timeout = Config.claude_turn_timeout_ms()
    stall_timeout = Config.claude_stall_timeout_ms()
    effective_timeout = min(turn_timeout, stall_timeout)

    receive_loop(port, on_message, metadata, effective_timeout, turn_timeout, now_ms(), "")
  end

  defp receive_loop(port, on_message, metadata, stall_timeout, turn_timeout, start_ms, pending) do
    timeout = remaining_timeout(stall_timeout, turn_timeout, start_ms)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending <> to_string(chunk)
        Logger.debug("Claude CLI stream line: #{String.slice(complete_line, 0, 500)}")

        case handle_stream_line(complete_line, on_message, metadata) do
          {:continue, _updated_metadata} ->
            receive_loop(port, on_message, metadata, stall_timeout, turn_timeout, start_ms, "")

          {:done, result} ->
            drain_port(port)
            {:ok, result}

          {:error, reason} ->
            drain_port(port)
            {:error, reason}
        end

      {^port, {:data, {:noeol, chunk}}} ->
        Logger.debug("Claude CLI stream partial chunk (#{byte_size(chunk)} bytes, pending=#{byte_size(pending)} bytes)")
        receive_loop(
          port,
          on_message,
          metadata,
          stall_timeout,
          turn_timeout,
          start_ms,
          pending <> to_string(chunk)
        )

      {^port, {:exit_status, 0}} ->
        Logger.info("Claude CLI port exited normally (status=0)")
        # Normal exit without a result event — treat as success.
        {:ok, %{}}

      {^port, {:exit_status, status}} ->
        Logger.warning("Claude CLI port exited with status=#{status}")
        {:error, {:port_exit, status}}
    after
      timeout ->
        Logger.warning("Claude CLI stream timed out after #{timeout}ms (stall_timeout=#{stall_timeout}, turn_timeout=#{turn_timeout})")
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

  # ── Event handling ─────────────────────────────────────────────────────

  defp handle_stream_line(line, on_message, metadata) do
    case Jason.decode(line) do
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

  # ── Helpers ────────────────────────────────────────────────────────────

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

  defp log_non_json_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude CLI stream output: #{text}")
      else
        Logger.debug("Claude CLI stream output: #{text}")
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
