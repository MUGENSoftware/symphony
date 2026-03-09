defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with Claude Code CLI.
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  import Bitwise

  alias SymphonyElixir.Claude.Cli
  alias SymphonyElixir.{Config, Git, Linear.Issue, PromptBuilder, Telemetry, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    # Attach OTEL context propagated from the Orchestrator
    case Keyword.get(opts, :otel_ctx) do
      nil -> :ok
      ctx -> OpenTelemetry.Ctx.attach(ctx)
    end

    run_id = generate_run_id()

    Tracer.with_span :"agent_runner.run", %{
      attributes: %{
        issue_id: issue_id(issue),
        issue_identifier: issue_identifier(issue),
        run_id: run_id
      }
    } do
      Telemetry.agent_run_started(%{issue_id: issue_id(issue), run_id: run_id})
      Logger.info("Starting agent run for #{issue_context(issue)} run_id=#{run_id}")

      case do_run(issue, claude_update_recipient, Keyword.put(opts, :run_id, run_id)) do
        :ok ->
          Telemetry.agent_run_completed(%{issue_id: issue_id(issue), run_id: run_id})
          :ok

        {:error, reason} ->
          Telemetry.agent_run_failed(%{issue_id: issue_id(issue), run_id: run_id})
          Tracer.set_status(:error, inspect(reason))
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
      end
    end
  end

  defp do_run(issue, claude_update_recipient, opts) do
    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        Tracer.set_attribute(:workspace_path, workspace)

        try do
          with {:ok, git_setup} <- maybe_git_setup(workspace, issue, claude_update_recipient),
               :ok <- Workspace.run_before_run_hook(workspace, issue) do
            opts_with_git =
              if(git_setup, do: Keyword.put(opts, :git_setup, git_setup), else: opts)

            run_claude_turns(workspace, issue, claude_update_recipient, opts_with_git)
          end
        after
          maybe_git_publish(workspace, issue, claude_update_recipient)
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claude_message_handler(recipient, issue) do
    fn message ->
      send_claude_update(recipient, issue, message)
    end
  end

  defp send_claude_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:claude_worker_update, issue_id, message})
    :ok
  end

  defp send_claude_update(_recipient, _issue, _message), do: :ok

  defp run_claude_turns(workspace, issue, claude_update_recipient, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    resume_session_id = Keyword.get(opts, :resume_session_id)
    run_id = Keyword.get(opts, :run_id)

    Tracer.set_attribute(:max_turns, max_turns)

    session = %{session_id: resume_session_id, workspace: Path.expand(workspace)}

    run_context =
      build_run_context(
        workspace,
        issue,
        claude_update_recipient,
        opts,
        issue_state_fetcher,
        max_turns,
        run_id
      )

    do_run_claude_turns(session, run_context, 1)
  end

  defp do_run_claude_turns(session, run_context, turn_number) do
    %{issue: issue, opts: opts, max_turns: max_turns, run_id: run_id} = run_context
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    %{recipient: recipient} = run_context

    turn_result =
      Tracer.with_span :"claude.turn", %{
        attributes: %{
          issue_id: issue_id(issue),
          issue_identifier: issue_identifier(issue),
          run_id: run_id || "",
          turn_number: turn_number,
          max_turns: max_turns
        }
      } do
        case Cli.run_turn(
               session,
               prompt,
               issue,
               on_message: claude_message_handler(recipient, issue)
             ) do
          {:ok, result} ->
            Tracer.set_attribute(:result, to_string(result[:result] || "unknown"))
            {:ok, result}

          error ->
            Tracer.set_status(:error, inspect(error))
            error
        end
      end

    with {:ok, turn_result} <- turn_result do
      log_turn_completion(turn_result, issue, run_context.workspace, turn_number, max_turns)
      handle_turn_outcome(turn_result, session, run_context, turn_number)
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    PromptBuilder.build_prompt(issue, opts)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Claude turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp log_turn_completion(turn_result, issue, workspace, turn_number, max_turns) do
    Logger.info(
      "Completed agent run for #{issue_context(issue)} session_id=#{turn_result[:session_id]} " <>
        "workspace=#{workspace} turn=#{turn_number}/#{max_turns} result=#{turn_result[:result]}"
    )
  end

  defp handle_turn_outcome(%{result: :usage_limit_reached}, _session, _run_context, _turn_number) do
    :ok
  end

  defp handle_turn_outcome(turn_result, session, run_context, turn_number) do
    next_session = Map.get(turn_result, :session, session)
    %{issue: issue} = run_context

    case continue_with_issue?(issue, run_context.issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < run_context.max_turns ->
        Logger.info(
          "Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion " <>
            "turn=#{turn_number}/#{run_context.max_turns}"
        )

        do_run_claude_turns(
          next_session,
          %{run_context | issue: refreshed_issue},
          turn_number + 1
        )

      {:continue, refreshed_issue} ->
        Logger.info(
          "Reached agent.max_turns for #{issue_context(refreshed_issue)} " <>
            "with issue still active; returning control to orchestrator"
        )

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_run_context(workspace, issue, claude_update_recipient, opts, issue_state_fetcher, max_turns, run_id) do
    %{
      workspace: workspace,
      issue: issue,
      recipient: claude_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns,
      run_id: run_id
    }
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp maybe_git_setup(workspace, %Issue{identifier: identifier} = issue, recipient) do
    if Config.git_enabled?() do
      Logger.info("Running git branch setup for issue_identifier=#{identifier} workspace=#{workspace}")
      emit_git_event(recipient, issue, :git_setup_started, %{workspace: workspace})

      case Git.setup_branch(workspace, identifier) do
        {:ok, result} ->
          emit_git_event(recipient, issue, :git_setup_completed, %{
            branch: result.branch,
            merge: result.merge
          })

          {:ok, result}

        {:error, reason} = error ->
          Logger.error("Git setup failed issue_identifier=#{identifier} reason=#{inspect(reason)}")
          emit_git_event(recipient, issue, :git_setup_failed, %{reason: inspect(reason)})
          error
      end
    else
      {:ok, nil}
    end
  end

  defp maybe_git_publish(workspace, %Issue{identifier: identifier} = issue, recipient) do
    if Config.git_enabled?() do
      Logger.info("Running git publish for issue_identifier=#{identifier} workspace=#{workspace}")
      emit_git_event(recipient, issue, :git_push_started, %{workspace: workspace})

      case Git.publish(workspace, identifier, issue) do
        :ok ->
          emit_git_event(recipient, issue, :git_push_completed, %{})
          :ok

        {:error, reason} ->
          Logger.warning("Git publish failed issue_identifier=#{identifier} reason=#{inspect(reason)}")
          emit_git_event(recipient, issue, :git_push_failed, %{reason: inspect(reason)})
          :ok
      end
    else
      :ok
    end
  end

  defp emit_git_event(recipient, issue, event, details) do
    message = %{
      event: event,
      timestamp: DateTime.utc_now(),
      payload: details
    }

    send_claude_update(recipient, issue, message)
  end

  defp generate_run_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c &&& 0x0FFF, d ||| (0x8000 &&& 0xBFFF), e]
    )
    |> IO.iodata_to_binary()
  end

  defp issue_id(%Issue{id: id}) when is_binary(id), do: id
  defp issue_id(_), do: ""

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_), do: ""

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
