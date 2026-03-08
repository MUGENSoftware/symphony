defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias SymphonyElixir.Claude.McpConfig
  alias SymphonyElixir.Workflow

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_poll_interval_ms 30_000
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_claude_command "claude --output-format stream-json"
  @default_claude_turn_timeout_ms 3_600_000
  @default_claude_read_timeout_ms 5_000
  @default_claude_stall_timeout_ms 300_000
  @default_claude_output_format "stream-json"
  @default_claude_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_claude_thread_sandbox "workspace-write"
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_server_host "127.0.0.1"
  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ]
                               ]
                             ],
                             claude: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_claude_command],
                                 model: [type: {:or, [:string, nil]}, default: nil],
                                 output_format: [
                                   type: :string,
                                   default: @default_claude_output_format
                                 ],
                                 approval_policy: [
                                   type: :any,
                                   default: nil
                                 ],
                                 thread_sandbox: [
                                   type: {:or, [:string, nil]},
                                   default: nil
                                 ],
                                 turn_sandbox_policy: [
                                   type: :any,
                                   default: nil
                                 ],
                                 dangerously_skip_permissions: [type: :boolean, default: false],
                                 permission_mode: [type: {:or, [:string, nil]}, default: nil],
                                 allowed_tools: [
                                   type: {:or, [{:list, :string}, nil]},
                                   default: nil
                                 ],
                                 append_system_prompt: [type: {:or, [:string, nil]}, default: nil],
                                 mcp_config: [type: {:or, [:string, nil]}, default: nil],
                                 max_turns: [type: {:or, [:pos_integer, nil]}, default: nil],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_claude_read_timeout_ms
                                 ],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_claude_turn_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_claude_stall_timeout_ms
                                 ]
                               ]
                             ],
                             git: [
                               type: :map,
                               default: %{},
                               keys: [
                                 enabled: [type: :boolean, default: false],
                                 base_branch: [type: :string, default: "main"],
                                 branch_prefix: [type: :string, default: "claude/"],
                                 auto_push: [type: :boolean, default: true],
                                 auto_pr: [type: :boolean, default: true]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type claude_cli_settings :: %{
          command: String.t(),
          model: String.t() | nil,
          output_format: String.t(),
          approval_policy: map() | String.t() | nil,
          thread_sandbox: String.t() | nil,
          turn_sandbox_policy: map() | String.t() | nil,
          dangerously_skip_permissions: boolean(),
          permission_mode: String.t() | nil,
          allowed_tools: [String.t()] | nil,
          append_system_prompt: String.t() | nil,
          mcp_config: String.t() | nil,
          max_turns: pos_integer() | nil,
          read_timeout_ms: pos_integer(),
          turn_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    get_in(validated_workflow_options(), [:tracker, :endpoint])
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :api_key])
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    get_in(validated_workflow_options(), [:tracker, :project_slug])
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :assignee])
    |> resolve_env_value(System.get_env("LINEAR_ASSIGNEE"))
    |> normalize_secret_value()
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :interval_ms])
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec git_enabled?() :: boolean()
  def git_enabled? do
    get_in(validated_workflow_options(), [:git, :enabled])
  end

  @spec git_base_branch() :: String.t()
  def git_base_branch do
    get_in(validated_workflow_options(), [:git, :base_branch])
  end

  @spec git_branch_prefix() :: String.t()
  def git_branch_prefix do
    get_in(validated_workflow_options(), [:git, :branch_prefix])
  end

  @spec git_auto_push?() :: boolean()
  def git_auto_push? do
    get_in(validated_workflow_options(), [:git, :auto_push])
  end

  @spec git_auto_pr?() :: boolean()
  def git_auto_pr? do
    get_in(validated_workflow_options(), [:git, :auto_pr])
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec claude_command() :: String.t()
  def claude_command do
    get_in(validated_workflow_options(), [:claude, :command])
  end

  @spec claude_model() :: String.t() | nil
  def claude_model do
    get_in(validated_workflow_options(), [:claude, :model])
  end

  @spec claude_output_format() :: String.t()
  def claude_output_format do
    get_in(validated_workflow_options(), [:claude, :output_format])
  end

  @spec claude_approval_policy() :: map() | String.t()
  def claude_approval_policy do
    validated_workflow_options()
    |> get_in([:claude, :approval_policy])
    |> normalize_claude_approval_policy()
  end

  @spec claude_thread_sandbox() :: String.t()
  def claude_thread_sandbox do
    validated_workflow_options()
    |> get_in([:claude, :thread_sandbox])
    |> normalize_claude_thread_sandbox()
  end

  @spec claude_turn_sandbox_policy() :: map()
  def claude_turn_sandbox_policy do
    claude_turn_sandbox_policy(nil)
  end

  @spec claude_turn_sandbox_policy(String.t() | nil) :: map()
  def claude_turn_sandbox_policy(workspace) do
    validated_workflow_options()
    |> get_in([:claude, :turn_sandbox_policy])
    |> normalize_claude_turn_sandbox_policy(workspace)
  end

  @spec claude_dangerously_skip_permissions?() :: boolean()
  def claude_dangerously_skip_permissions? do
    get_in(validated_workflow_options(), [:claude, :dangerously_skip_permissions]) || false
  end

  @spec claude_permission_mode() :: String.t() | nil
  def claude_permission_mode do
    get_in(validated_workflow_options(), [:claude, :permission_mode])
  end

  @spec claude_allowed_tools() :: [String.t()] | nil
  def claude_allowed_tools do
    get_in(validated_workflow_options(), [:claude, :allowed_tools])
  end

  @spec claude_append_system_prompt() :: String.t() | nil
  def claude_append_system_prompt do
    get_in(validated_workflow_options(), [:claude, :append_system_prompt])
  end

  @spec claude_mcp_config() :: String.t() | nil
  def claude_mcp_config do
    get_in(validated_workflow_options(), [:claude, :mcp_config])
  end

  @spec claude_max_turns() :: pos_integer() | nil
  def claude_max_turns do
    get_in(validated_workflow_options(), [:claude, :max_turns])
  end

  @spec claude_read_timeout_ms() :: pos_integer()
  def claude_read_timeout_ms do
    get_in(validated_workflow_options(), [:claude, :read_timeout_ms])
  end

  @spec claude_turn_timeout_ms() :: pos_integer()
  def claude_turn_timeout_ms do
    get_in(validated_workflow_options(), [:claude, :turn_timeout_ms])
  end

  @spec claude_stall_timeout_ms() :: non_neg_integer()
  def claude_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:claude, :stall_timeout_ms])
    |> max(0)
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_kind(),
         :ok <- require_linear_token(),
         :ok <- require_linear_project(),
         :ok <- validate_claude_approval_policy(),
         :ok <- validate_claude_thread_sandbox(),
         :ok <- validate_claude_turn_sandbox_policy(),
         :ok <- require_claude_command(),
         :ok <- validate_claude_mcp_config() do
      :ok
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "linear" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_api_token()) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_project_slug()) do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_claude_command do
    if byte_size(String.trim(claude_command())) > 0 do
      :ok
    else
      {:error, :missing_claude_command}
    end
  end

  defp validate_claude_mcp_config do
    mode = claude_mode_for_validation(claude_command())

    case McpConfig.ensure_ready(mode) do
      {:ok, _details} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp claude_mode_for_validation(command) when is_binary(command) do
    try do
      case OptionParser.split(command) do
        args when is_list(args) ->
          if Enum.any?(args, &(&1 == "app-server")) do
            :app_server
          else
            :stream_json
          end

        _ ->
          :stream_json
      end
    rescue
      _error -> :stream_json
    end
  end

  defp validated_workflow_options do
    workflow_config()
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      claude: extract_claude_options(section_map(config, "claude")),
      git: extract_git_options(section_map(config, "git")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:project_slug, scalar_string_value(Map.get(section, "project_slug")))
    |> put_if_present(:assignee, scalar_string_value(Map.get(section, "assignee")))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
  end

  defp extract_claude_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:model, scalar_string_value(Map.get(section, "model")))
    |> put_if_present(:output_format, scalar_string_value(Map.get(section, "output_format")))
    |> put_if_present(:approval_policy, claude_approval_policy_value(Map.get(section, "approval_policy")))
    |> put_if_present(:thread_sandbox, scalar_string_value(Map.get(section, "thread_sandbox")))
    |> put_if_present(
      :turn_sandbox_policy,
      claude_turn_sandbox_policy_value(Map.get(section, "turn_sandbox_policy"))
    )
    |> put_if_present(:dangerously_skip_permissions, boolean_value(Map.get(section, "dangerously_skip_permissions")))
    |> put_if_present(:permission_mode, scalar_string_value(Map.get(section, "permission_mode")))
    |> put_if_present(:allowed_tools, csv_value(Map.get(section, "allowed_tools")))
    |> put_if_present(:append_system_prompt, binary_value(Map.get(section, "append_system_prompt")))
    |> put_if_present(:mcp_config, binary_value(Map.get(section, "mcp_config")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:read_timeout_ms, integer_value(Map.get(section, "read_timeout_ms")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_git_options(section) do
    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(:base_branch, scalar_string_value(Map.get(section, "base_branch")))
    |> put_if_present(:branch_prefix, scalar_string_value(Map.get(section, "branch_prefix")))
    |> put_if_present(:auto_push, boolean_value(Map.get(section, "auto_push")))
    |> put_if_present(:auto_pr, boolean_value(Map.get(section, "auto_pr")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp command_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp claude_approval_policy_value(value) when is_map(value), do: normalize_keys(value)
  defp claude_approval_policy_value(value) when is_binary(value), do: String.trim(value)
  defp claude_approval_policy_value(nil), do: :omit
  defp claude_approval_policy_value(_value), do: :omit

  defp claude_turn_sandbox_policy_value(value) when is_map(value), do: normalize_keys(value)
  defp claude_turn_sandbox_policy_value(value) when is_binary(value), do: String.trim(value)
  defp claude_turn_sandbox_policy_value(nil), do: :omit
  defp claude_turn_sandbox_policy_value(_value), do: :omit

  defp fetch_value(paths, default) do
    config = workflow_config()

    case resolve_config_value(config, paths) do
      :missing -> default
      value -> value
    end
  end

  defp validate_claude_approval_policy do
    case fetch_value([["claude", "approval_policy"]], :missing) do
      :missing -> :ok
      nil -> :ok
      "" -> {:error, {:invalid_claude_approval_policy, ""}}
      value when is_binary(value) -> :ok
      value when is_map(value) -> :ok
      value -> {:error, {:invalid_claude_approval_policy, value}}
    end
  end

  defp validate_claude_thread_sandbox do
    case fetch_value([["claude", "thread_sandbox"]], :missing) do
      :missing -> :ok
      nil -> :ok
      "" -> {:error, {:invalid_claude_thread_sandbox, ""}}
      value when is_binary(value) -> :ok
      value -> {:error, {:invalid_claude_thread_sandbox, value}}
    end
  end

  defp validate_claude_turn_sandbox_policy do
    case fetch_value([["claude", "turn_sandbox_policy"]], :missing) do
      :missing -> :ok
      nil -> :ok
      value when is_map(value) -> :ok
      value when is_binary(value) -> {:error, {:invalid_claude_turn_sandbox_policy, {:unsupported_value, value}}}
      value -> {:error, {:invalid_claude_turn_sandbox_policy, {:unsupported_value, value}}}
    end
  end

  defp normalize_claude_approval_policy(nil), do: @default_claude_approval_policy
  defp normalize_claude_approval_policy(""), do: @default_claude_approval_policy
  defp normalize_claude_approval_policy(value) when is_binary(value), do: String.trim(value)
  defp normalize_claude_approval_policy(value) when is_map(value), do: normalize_keys(value)
  defp normalize_claude_approval_policy(_value), do: @default_claude_approval_policy

  defp normalize_claude_thread_sandbox(nil), do: @default_claude_thread_sandbox
  defp normalize_claude_thread_sandbox(""), do: @default_claude_thread_sandbox
  defp normalize_claude_thread_sandbox(value) when is_binary(value), do: String.trim(value)
  defp normalize_claude_thread_sandbox(_value), do: @default_claude_thread_sandbox

  defp normalize_claude_turn_sandbox_policy(nil, workspace), do: default_turn_sandbox_policy(workspace)
  defp normalize_claude_turn_sandbox_policy("", workspace), do: default_turn_sandbox_policy(workspace)
  defp normalize_claude_turn_sandbox_policy(value, _workspace) when is_map(value), do: normalize_keys(value)
  defp normalize_claude_turn_sandbox_policy(_value, workspace), do: default_turn_sandbox_policy(workspace)

  defp default_turn_sandbox_policy(nil) do
    default_turn_sandbox_policy(workspace_root())
  end

  defp default_turn_sandbox_policy(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [expanded_workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
