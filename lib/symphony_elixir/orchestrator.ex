defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Claude Code-backed workers.
  """

  use GenServer
  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Telemetry, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_claude_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :claude_availability_timer_ref,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      claude_totals: nil,
      claude_rate_limits: nil,
      claude_availability: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      claude_totals: @empty_claude_totals,
      claude_rate_limits: nil,
      claude_availability: nil,
      claude_availability_timer_ref: nil
    }

    run_terminal_workspace_cleanup()
    :ok = schedule_tick(0)

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)
    state = %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    poll_start_ms = System.monotonic_time(:millisecond)
    state = maybe_dispatch(state)
    poll_duration_ms = System.monotonic_time(:millisecond) - poll_start_ms

    Telemetry.poll_cycle_completed()
    Telemetry.poll_cycle_duration(poll_duration_ms)
    emit_gauges(state)

    now_ms = System.monotonic_time(:millisecond)
    next_poll_due_at_ms = now_ms + state.poll_interval_ms
    :ok = schedule_tick(state.poll_interval_ms)

    state = %{state | poll_check_in_progress: false, next_poll_due_at_ms: next_poll_due_at_ms}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        Tracer.set_attribute(:issue_id, issue_id)
        Tracer.set_attribute(:issue_identifier, running_entry.identifier || "")
        Tracer.set_attribute(:worker_exit_reason, to_string(reason))

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> schedule_normal_exit_retry(issue_id, running_entry)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}"
              })
          end

        emit_orchestrator_gauges(state)
        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:claude_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_claude_update(running_entry, update)

        state =
          state
          |> apply_claude_token_delta(token_delta)
          |> apply_claude_rate_limits(update)
          |> apply_claude_availability(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:claude_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info(
        {:claude_availability_reset, blocked_until_ms},
        %{claude_availability: %{blocked_until_ms: blocked_until_ms}} = state
      ) do
    state =
      state
      |> clear_claude_availability()
      |> refresh_requested_poll()

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:claude_availability_reset, _blocked_until_ms}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with false <- claude_unavailable?(state),
         :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      true ->
        Tracer.set_attribute(:claude_availability_status, "cooldown")
        state

      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, :missing_claude_command} ->
        Logger.error("Claude command missing in WORKFLOW.md")
        state

      {:error, {:claude_mcp_config_not_found, path}} ->
        Logger.error("Claude MCP config override not found at #{path}")
        state

      {:error, {:claude_mcp_config_unreadable, path, reason}} ->
        Logger.error("Claude MCP config override unreadable at #{path}: #{inspect(reason)}")
        state

      {:error, {:invalid_claude_mcp_config_json, path, reason}} ->
        Logger.error("Claude MCP config override is invalid JSON at #{path}: #{inspect(reason)}")
        state

      {:error, {:claude_default_mcp_config_write_failed, path, reason}} ->
        Logger.error("Failed to write default Claude MCP config at #{path}: #{inspect(reason)}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          reconcile_running_issue_states(
            issues,
            state,
            active_state_set(),
            terminal_state_set()
          )

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set(), pr_merge_status_checker())
  end

  @doc false
  @spec should_dispatch_issue_for_test(
          Issue.t(),
          term(),
          (String.t() -> SymphonyElixir.Git.pr_merge_status())
        ) ::
          boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state, pr_merge_status_checker)
      when is_function(pr_merge_status_checker, 1) do
    should_dispatch_issue?(
      issue,
      state,
      active_state_set(),
      terminal_state_set(),
      pr_merge_status_checker
    )
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues, terminal_state_set())
  end

  @doc false
  @spec choose_issue_identifiers_for_dispatch_for_test([Issue.t()], term()) :: [String.t()]
  def choose_issue_identifiers_for_dispatch_for_test(issues, %State{} = state) when is_list(issues) do
    choose_issue_identifiers_for_dispatch(
      issues,
      state,
      active_state_set(),
      terminal_state_set(),
      pr_merge_status_checker()
    )
  end

  @doc false
  @spec choose_issue_identifiers_for_dispatch_for_test(
          [Issue.t()],
          term(),
          (String.t() -> SymphonyElixir.Git.pr_merge_status())
        ) :: [String.t()]
  def choose_issue_identifiers_for_dispatch_for_test(
        issues,
        %State{} = state,
        pr_merge_status_checker
      )
      when is_list(issues) and is_function(pr_merge_status_checker, 1) do
    choose_issue_identifiers_for_dispatch(
      issues,
      state,
      active_state_set(),
      terminal_state_set(),
      pr_merge_status_checker
    )
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.claude_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without claude activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_claude_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    busy_parent_keys = busy_parent_keys(issues, state)
    pr_merge_status_checker = pr_merge_status_checker()

    issues
    |> sort_issues_for_dispatch(terminal_states)
    |> Enum.reduce({state, busy_parent_keys}, fn issue, {state_acc, busy_parent_keys_acc} ->
      if should_dispatch_issue?(
           issue,
           state_acc,
           active_states,
           terminal_states,
           pr_merge_status_checker
         ) and
           !parent_busy?(issue, busy_parent_keys_acc) do
        updated_state = dispatch_issue(state_acc, issue)
        {updated_state, mark_parent_busy(issue, busy_parent_keys_acc)}
      else
        {state_acc, busy_parent_keys_acc}
      end
    end)
    |> elem(0)
  end

  defp choose_issue_identifiers_for_dispatch(
         issues,
         state,
         active_states,
         terminal_states,
         pr_merge_status_checker
       )
       when is_list(issues) and is_struct(state, State) do
    busy_parent_keys = busy_parent_keys(issues, state)

    issues
    |> sort_issues_for_dispatch(terminal_states)
    |> Enum.reduce({[], busy_parent_keys}, fn issue, {identifiers, busy_parent_keys_acc} ->
      if should_dispatch_issue?(
           issue,
           state,
           active_states,
           terminal_states,
           pr_merge_status_checker
         ) and
           !parent_busy?(issue, busy_parent_keys_acc) do
        {
          identifiers ++ [issue.identifier],
          mark_parent_busy(issue, busy_parent_keys_acc)
        }
      else
        {identifiers, busy_parent_keys_acc}
      end
    end)
    |> elem(0)
  end

  defp sort_issues_for_dispatch(issues, terminal_states)
       when is_list(issues) and is_struct(terminal_states, MapSet) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {
          priority_rank(issue.priority),
          child_issue_dispatch_rank(issue, terminal_states),
          issue_created_at_sort_key(issue),
          issue.identifier || issue.id || ""
        }

      _ ->
        {priority_rank(nil), 1, issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp child_issue_dispatch_rank(
         %Issue{parent: %{} = _parent, child_execution_mode: :serial},
         _terminal_states
       ),
       do: 0

  defp child_issue_dispatch_rank(%Issue{parent: %{} = _parent} = issue, terminal_states) do
    if todo_issue_blocked_by_non_terminal?(issue, terminal_states), do: 1, else: 0
  end

  defp child_issue_dispatch_rank(%Issue{}, _terminal_states), do: 0
  defp child_issue_dispatch_rank(_issue, _terminal_states), do: 1

  defp busy_parent_keys(issues, %State{running: running, claimed: claimed})
       when is_list(issues) and is_map(running) and is_struct(claimed, MapSet) do
    running
    |> Map.values()
    |> Enum.reduce(MapSet.new(), fn
      %{issue: %Issue{} = issue}, acc -> mark_parent_busy(issue, acc)
      _entry, acc -> acc
    end)
    |> add_claimed_parent_keys(issues, claimed)
  end

  defp busy_parent_keys(_issues, _state), do: MapSet.new()

  defp add_claimed_parent_keys(parent_keys, issues, claimed)
       when is_struct(parent_keys, MapSet) and is_list(issues) and is_struct(claimed, MapSet) do
    Enum.reduce(issues, parent_keys, fn
      %Issue{id: issue_id} = issue, acc when is_binary(issue_id) ->
        if MapSet.member?(claimed, issue_id), do: mark_parent_busy(issue, acc), else: acc

      _issue, acc ->
        acc
    end)
  end

  defp parent_busy?(%Issue{} = issue, busy_parent_keys) when is_struct(busy_parent_keys, MapSet) do
    case serial_parent_dispatch_key(issue) do
      nil -> false
      key -> MapSet.member?(busy_parent_keys, key)
    end
  end

  defp parent_busy?(_issue, _busy_parent_keys), do: false

  defp mark_parent_busy(%Issue{} = issue, busy_parent_keys) when is_struct(busy_parent_keys, MapSet) do
    case serial_parent_dispatch_key(issue) do
      nil -> busy_parent_keys
      key -> MapSet.put(busy_parent_keys, key)
    end
  end

  defp mark_parent_busy(_issue, busy_parent_keys), do: busy_parent_keys

  defp serial_parent_dispatch_key(%Issue{child_execution_mode: :serial, parent: %{id: parent_id}})
       when is_binary(parent_id),
       do: {:parent_id, parent_id}

  defp serial_parent_dispatch_key(%Issue{child_execution_mode: :serial, parent: %{identifier: parent_identifier}})
       when is_binary(parent_identifier),
       do: {:parent_identifier, parent_identifier}

  defp serial_parent_dispatch_key(_issue), do: nil

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states,
         pr_merge_status_checker
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      serial_predecessor_dispatchable?(issue, active_states, pr_merge_status_checker) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states, _pr_merge_status_checker),
    do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states) and
      !parent_issue_blocked_by_non_terminal_sub_issues?(issue, terminal_states) and
      !sub_issue_of_terminal_parent?(issue, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp parent_issue_blocked_by_non_terminal_sub_issues?(
         %Issue{sub_issues: sub_issues},
         terminal_states
       )
       when is_list(sub_issues) do
    Enum.any?(sub_issues, fn
      %{state: sub_issue_state} when is_binary(sub_issue_state) ->
        !terminal_issue_state?(sub_issue_state, terminal_states)

      %{} ->
        true

      _ ->
        true
    end)
  end

  defp parent_issue_blocked_by_non_terminal_sub_issues?(_issue, _terminal_states), do: false

  defp sub_issue_of_terminal_parent?(
         %Issue{parent: %{state: parent_state}},
         terminal_states
       )
       when is_binary(parent_state) do
    terminal_issue_state?(parent_state, terminal_states)
  end

  defp sub_issue_of_terminal_parent?(%Issue{parent: %{}}, _terminal_states), do: true
  defp sub_issue_of_terminal_parent?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp serial_predecessor_dispatchable?(
         %Issue{child_execution_mode: :serial, serial_predecessor: predecessor},
         active_states,
         pr_merge_status_checker
       )
       when is_map(predecessor) and is_struct(active_states, MapSet) and
              is_function(pr_merge_status_checker, 1) do
    predecessor_identifier = predecessor[:identifier]
    predecessor_state = predecessor[:state]

    cond do
      !is_binary(predecessor_identifier) or !is_binary(predecessor_state) ->
        false

      active_issue_state?(predecessor_state, active_states) ->
        false

      true ->
        predecessor_merge_allows_dispatch?(
          predecessor_identifier,
          pr_merge_status_checker.(predecessor_identifier)
        )
    end
  end

  defp serial_predecessor_dispatchable?(%Issue{}, _active_states, _pr_merge_status_checker), do: true
  defp serial_predecessor_dispatchable?(_issue, _active_states, _pr_merge_status_checker), do: false

  defp predecessor_merge_allows_dispatch?(_predecessor_identifier, :merged), do: true
  defp predecessor_merge_allows_dispatch?(_predecessor_identifier, :not_merged), do: false

  defp predecessor_merge_allows_dispatch?(predecessor_identifier, {:error, reason}) do
    Logger.warning("Skipping serial child dispatch; predecessor PR merge status lookup failed issue_identifier=#{predecessor_identifier} reason=#{inspect(reason)}")

    false
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp pr_merge_status_checker do
    Application.get_env(
      :symphony_elixir,
      :git_pr_merge_status_checker,
      &SymphonyElixir.Git.pull_request_merge_status/1
    )
  end

  defp terminal_state_set do
    Config.linear_terminal_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.linear_active_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil),
    do: dispatch_issue(state, issue, attempt, %{})

  defp dispatch_issue(%State{} = state, issue, attempt, metadata) when is_map(metadata) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, metadata)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, metadata) do
    dispatch_reason = Map.get(metadata, :dispatch_reason, "poll_cycle")
    recipient = self()
    resume_session_id = Map.get(metadata, :resume_session_id)

    state =
      Tracer.with_span :"orchestrator.dispatch_issue", %{
        attributes: %{
          issue_id: issue.id,
          issue_identifier: issue.identifier || "",
          retry_attempt: normalize_retry_attempt(attempt),
          dispatch_reason: dispatch_reason,
          claude_availability_status: cooldown_status_string(state)
        }
      } do
        otel_ctx = OpenTelemetry.Ctx.get_current()

        case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               AgentRunner.run(issue, recipient,
                 attempt: attempt,
                 resume_session_id: resume_session_id,
                 otel_ctx: otel_ctx
               )
             end) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            Telemetry.issue_dispatched()

            Logger.info(
              "Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}" <>
                if(is_binary(resume_session_id), do: " resume_session_id=#{resume_session_id}", else: "")
            )

            Telemetry.issue_dispatched(%{dispatch_reason: dispatch_reason})

            running =
              Map.put(state.running, issue.id, %{
                pid: pid,
                ref: ref,
                identifier: issue.identifier,
                issue: issue,
                session_id: resume_session_id,
                last_claude_message: nil,
                last_claude_timestamp: nil,
                last_claude_event: nil,
                claude_cli_pid: nil,
                claude_input_tokens: 0,
                claude_output_tokens: 0,
                claude_total_tokens: 0,
                claude_last_reported_input_tokens: 0,
                claude_last_reported_output_tokens: 0,
                claude_last_reported_total_tokens: 0,
                turn_count: 0,
                max_turns: Config.agent_max_turns(),
                retry_attempt: normalize_retry_attempt(attempt),
                started_at: DateTime.utc_now()
              })

            %{
              state
              | running: running,
                claimed: MapSet.put(state.claimed, issue.id),
                retry_attempts: Map.delete(state.retry_attempts, issue.id)
            }

          {:error, reason} ->
            Tracer.set_status(:error, inspect(reason))
            Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
            next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

            schedule_issue_retry(state, issue.id, next_attempt, %{
              identifier: issue.identifier,
              error: "failed to spawn agent: #{inspect(reason)}",
              resume_session_id: resume_session_id
            })
        end
      end

    state
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    put_retry_attempt(state, issue_id, next_attempt, metadata, previous_retry, due_at_ms, delay_ms)
  end

  defp schedule_issue_retry_at(%State{} = state, issue_id, attempt, metadata, due_at_ms)
       when is_binary(issue_id) and is_map(metadata) and is_integer(due_at_ms) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = max(due_at_ms - System.monotonic_time(:millisecond), 0)
    put_retry_attempt(state, issue_id, next_attempt, metadata, previous_retry, due_at_ms, delay_ms)
  end

  defp put_retry_attempt(state, issue_id, attempt, metadata, previous_retry, due_at_ms, delay_ms) do
    old_timer = Map.get(previous_retry, :timer_ref)
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id}, delay_ms)
    Telemetry.issue_retried()

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: attempt,
            timer_ref: timer_ref,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            resume_session_id: Map.get(metadata, :resume_session_id)
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          resume_session_id: Map.get(retry_entry, :resume_session_id)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.linear_terminal_states()) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
    Phoenix.PubSub.broadcast(SymphonyElixir.PubSub, "orchestrator:updates", :state_changed)
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    cond do
      claude_unavailable?(state) ->
        availability = Map.get(state, :claude_availability)

        {:noreply,
         schedule_issue_retry_at(
           state,
           issue.id,
           attempt,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: claude_availability_retry_message(availability)
           }),
           Map.get(availability, :blocked_until_ms)
         )}

      retry_candidate_issue?(issue, terminal_state_set()) and
          dispatch_slots_available?(issue, state) ->
        {:noreply, dispatch_issue(state, issue, attempt, Map.put(metadata, :dispatch_reason, "retry"))}

      true ->
        Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "no available orchestrator slots"
           })
         )}
    end
  end

  defp schedule_normal_exit_retry(state, issue_id, running_entry) do
    metadata = continuation_retry_metadata(running_entry)

    case cooldown_retry_due_at(state, running_entry) do
      {:ok, due_at_ms} ->
        schedule_issue_retry_at(state, issue_id, 1, metadata, due_at_ms)

      :error ->
        schedule_issue_retry(state, issue_id, 1, metadata)
    end
  end

  defp cooldown_retry_due_at(state, running_entry) do
    availability = Map.get(state, :claude_availability)

    cond do
      Map.get(running_entry, :last_claude_event) != :usage_limit_reached ->
        :error

      not claude_unavailable?(state) ->
        :error

      is_integer(Map.get(availability, :blocked_until_ms)) ->
        {:ok, availability.blocked_until_ms}

      true ->
        :error
    end
  end

  defp claude_availability_retry_message(availability) when is_map(availability) do
    base =
      if is_binary(Map.get(availability, :message)) do
        Map.get(availability, :message)
      else
        "Claude usage limit reached."
      end

    case Map.get(availability, :reset_at) do
      %DateTime{} = reset_at ->
        "#{base} Global cooldown active until #{DateTime.to_iso8601(reset_at)}."

      _ ->
        base
    end
  end

  defp claude_availability_retry_message(_availability) do
    "Claude usage limit reached. Global cooldown active."
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp continuation_retry_metadata(running_entry) do
    metadata = %{
      identifier: running_entry.identifier,
      delay_type: :continuation,
      resume_session_id: Map.get(running_entry, :session_id)
    }

    case Map.get(running_entry, :last_claude_event) do
      :max_turns_exhausted ->
        Map.put(
          metadata,
          :error,
          max_turns_retry_message(
            Map.get(running_entry, :session_id),
            Map.get(running_entry, :last_claude_message)
          )
        )

      :usage_limit_reached ->
        Map.put(
          metadata,
          :error,
          usage_limit_retry_message(Map.get(running_entry, :last_claude_message))
        )

      _ ->
        metadata
    end
  end

  defp max_turns_retry_message(session_id, %{message: message}) when is_binary(message) do
    if is_binary(session_id) and session_id != "" do
      "#{message} Auto-resume scheduled for session #{session_id}."
    else
      message
    end
  end

  defp max_turns_retry_message(session_id, _message) when is_binary(session_id) and session_id != "" do
    "Claude reached its max-turn limit. Auto-resume scheduled for session #{session_id}."
  end

  defp max_turns_retry_message(_session_id, _message) do
    "Claude reached its max-turn limit. Auto-resume scheduled."
  end

  defp usage_limit_retry_message(%{message: message}) when is_binary(message) do
    "#{message} Global cooldown scheduled."
  end

  defp usage_limit_retry_message(_message) do
    "Claude usage limit reached. Global cooldown scheduled."
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          session_id: metadata.session_id,
          claude_cli_pid: metadata.claude_cli_pid,
          claude_input_tokens: metadata.claude_input_tokens,
          claude_output_tokens: metadata.claude_output_tokens,
          claude_total_tokens: metadata.claude_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          max_turns: Map.get(metadata, :max_turns),
          started_at: metadata.started_at,
          last_claude_timestamp: metadata.last_claude_timestamp,
          last_claude_message: metadata.last_claude_message,
          last_claude_event: metadata.last_claude_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       claude_totals: state.claude_totals,
       rate_limits: Map.get(state, :claude_rate_limits),
       claude_availability: claude_availability_snapshot(Map.get(state, :claude_availability)),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?

    unless coalesced do
      :ok = schedule_tick(0)
    end

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_claude_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    claude_input_tokens = Map.get(running_entry, :claude_input_tokens, 0)
    claude_output_tokens = Map.get(running_entry, :claude_output_tokens, 0)
    claude_total_tokens = Map.get(running_entry, :claude_total_tokens, 0)
    claude_cli_pid = Map.get(running_entry, :claude_cli_pid)
    last_reported_input = Map.get(running_entry, :claude_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :claude_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :claude_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_claude_timestamp: timestamp,
        last_claude_message: summarize_claude_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_claude_event: event,
        claude_cli_pid: claude_cli_pid_for_update(claude_cli_pid, update),
        claude_input_tokens: claude_input_tokens + token_delta.input_tokens,
        claude_output_tokens: claude_output_tokens + token_delta.output_tokens,
        claude_total_tokens: claude_total_tokens + token_delta.total_tokens,
        claude_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        claude_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        claude_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp claude_cli_pid_for_update(_existing, %{claude_cli_pid: pid})
       when is_binary(pid),
       do: pid

  defp claude_cli_pid_for_update(_existing, %{claude_cli_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp claude_cli_pid_for_update(_existing, %{claude_cli_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp claude_cli_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_claude_update(update) do
    %{
      event: update[:event],
      message: update[:message] || update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :tick)
    :ok
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    claude_totals =
      apply_token_delta(
        state.claude_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | claude_totals: claude_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_claude_token_delta(
         %{claude_totals: claude_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | claude_totals: apply_token_delta(claude_totals, token_delta)}
  end

  defp apply_claude_token_delta(state, _token_delta), do: state

  defp apply_claude_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | claude_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_claude_rate_limits(state, _update), do: state

  defp apply_claude_availability(%State{} = state, %{event: :usage_limit_reached} = update) do
    case build_claude_availability(update) do
      {:ok, availability} ->
        current = Map.get(state, :claude_availability)

        if keep_existing_claude_availability?(current, availability) do
          state
        else
          state
          |> cancel_claude_availability_timer()
          |> schedule_claude_availability(availability)
        end

      :error ->
        state
    end
  end

  defp apply_claude_availability(state, _update), do: state

  defp build_claude_availability(update) do
    with %DateTime{} = reset_at <- Map.get(update, :reset_at),
         retry_after_ms when is_integer(retry_after_ms) and retry_after_ms >= 0 <-
           Map.get(update, :retry_after_ms) do
      {:ok,
       %{
         status: :cooldown,
         reason: :usage_cap,
         reset_at: reset_at,
         blocked_until_ms: System.monotonic_time(:millisecond) + retry_after_ms,
         message: Map.get(update, :message),
         source_session_id: Map.get(update, :session_id),
         detected_at: Map.get(update, :timestamp, DateTime.utc_now())
       }}
    else
      _ -> :error
    end
  end

  defp keep_existing_claude_availability?(current, replacement)
       when is_map(current) and is_map(replacement) do
    current_due_at = Map.get(current, :blocked_until_ms, 0)
    replacement_due_at = Map.get(replacement, :blocked_until_ms, 0)
    current_due_at >= replacement_due_at
  end

  defp keep_existing_claude_availability?(_current, _replacement), do: false

  defp schedule_claude_availability(%State{} = state, availability) do
    delay_ms = max(Map.get(availability, :blocked_until_ms) - System.monotonic_time(:millisecond), 0)

    timer_ref =
      Process.send_after(
        self(),
        {:claude_availability_reset, Map.get(availability, :blocked_until_ms)},
        delay_ms
      )

    %{
      state
      | claude_availability: availability,
        claude_availability_timer_ref: timer_ref
    }
  end

  defp cancel_claude_availability_timer(%State{} = state) do
    if is_reference(state.claude_availability_timer_ref) do
      Process.cancel_timer(state.claude_availability_timer_ref)
    end

    %{state | claude_availability_timer_ref: nil}
  end

  defp clear_claude_availability(%State{} = state) do
    state
    |> cancel_claude_availability_timer()
    |> Map.put(:claude_availability, nil)
  end

  defp emit_gauges(%State{} = state) do
    Telemetry.report_running_agents(map_size(state.running))
    Telemetry.report_retry_queue_depth(map_size(state.retry_attempts))
    Telemetry.report_claude_cooldown_active(if claude_unavailable?(state), do: 1, else: 0)
  end

  defp claude_unavailable?(%State{} = state) do
    case Map.get(state, :claude_availability) do
      %{blocked_until_ms: blocked_until_ms} when is_integer(blocked_until_ms) ->
        blocked_until_ms > System.monotonic_time(:millisecond)

      _ ->
        false
    end
  end

  defp claude_availability_snapshot(%{status: :cooldown} = availability) do
    %{
      status: "cooldown",
      reason: Atom.to_string(Map.get(availability, :reason, :usage_cap)),
      reset_at: iso8601(Map.get(availability, :reset_at)),
      message: Map.get(availability, :message),
      source_session_id: Map.get(availability, :source_session_id)
    }
  end

  defp claude_availability_snapshot(_availability), do: nil

  defp refresh_requested_poll(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)
    :ok = schedule_tick(0)

    %{
      state
      | next_poll_due_at_ms: now_ms,
        poll_check_in_progress: false
    }
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp apply_token_delta(claude_totals, token_delta) do
    input_tokens = Map.get(claude_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(claude_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(claude_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(claude_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :claude_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :claude_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :claude_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      Enum.find_value(payloads, &flat_token_usage_map/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp flat_token_usage_map(payload) when is_map(payload) do
    if integer_token_map?(payload), do: payload
  end

  defp flat_token_usage_map(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :cached_input_tokens,
      :cache_creation_input_tokens,
      :cache_read_input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :cachedInputTokens,
      :cacheCreationInputTokens,
      :cacheReadInputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "cached_input_tokens",
      "cache_creation_input_tokens",
      "cache_read_input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "cachedInputTokens",
      "cacheCreationInputTokens",
      "cacheReadInputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input) do
    total_token_components(usage).input
  end

  defp get_token_usage(usage, :output) do
    total_token_components(usage).output
  end

  defp get_token_usage(usage, :total) do
    total_token_components(usage).total
  end

  defp total_token_components(usage) when is_map(usage) do
    base_input =
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ]) || 0

    cached_input =
      sum_token_fields(usage, [
        "cached_input_tokens",
        :cached_input_tokens,
        "cache_creation_input_tokens",
        :cache_creation_input_tokens,
        "cache_read_input_tokens",
        :cache_read_input_tokens,
        "cachedInputTokens",
        :cachedInputTokens,
        "cacheCreationInputTokens",
        :cacheCreationInputTokens,
        "cacheReadInputTokens",
        :cacheReadInputTokens
      ])

    output =
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ]) || 0

    total =
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ]) || base_input + cached_input + output

    %{
      input: base_input + cached_input,
      output: output,
      total: total
    }
  end

  defp total_token_components(_usage), do: %{input: nil, output: nil, total: nil}

  defp sum_token_fields(usage, fields) when is_map(usage) and is_list(fields) do
    fields
    |> Enum.reduce(0, fn field, acc ->
      case map_integer_value(usage, field) do
        value when is_integer(value) -> acc + value
        _ -> acc
      end
    end)
  end

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp cooldown_status_string(%State{} = state) do
    if claude_unavailable?(state), do: "cooldown", else: "available"
  end

  defp emit_orchestrator_gauges(%State{} = state), do: emit_gauges(state)
end
