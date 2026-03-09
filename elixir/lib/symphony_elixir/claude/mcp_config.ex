defmodule SymphonyElixir.Claude.McpConfig do
  @moduledoc """
  Resolves the effective MCP config path for Claude sessions.
  """

  require Logger
  alias SymphonyElixir.{Config, LogFile}

  @default_linear_mcp_url "https://mcp.linear.app/mcp"
  @generated_file_name "claude.mcp.json"

  @type mode :: :stream_json | :app_server
  @type source :: :generated_default | :user_override | :disabled
  @type details :: %{path: String.t() | nil, source: source(), server: String.t() | nil}

  @spec ensure_ready(mode(), keyword()) :: {:ok, details()} | {:error, term()}
  def ensure_ready(mode, opts \\ []) when mode in [:stream_json, :app_server] do
    log? = Keyword.get(opts, :log?, false)

    case effective_details(mode) do
      %{path: nil} = details ->
        {:ok, details}

      %{source: :user_override, path: path} = details ->
        case validate_user_override(path) do
          :ok ->
            maybe_log_config_ready(details, log?)
            {:ok, details}

          {:error, _reason} = error ->
            error
        end

      %{source: :generated_default, path: path} = details ->
        case write_generated_default_config(path) do
          :ok ->
            maybe_log_config_ready(details, log?)
            {:ok, details}

          {:error, _reason} = error ->
            error
        end
    end
  end

  @spec effective_details(mode()) :: details()
  def effective_details(mode) when mode in [:stream_json, :app_server] do
    user_override = Config.claude_mcp_config()

    cond do
      mode != :stream_json ->
        %{path: nil, source: :disabled, server: nil}

      is_binary(user_override) and String.trim(user_override) != "" ->
        %{path: Path.expand(user_override), source: :user_override, server: "user_override"}

      Config.tracker_kind() == "linear" ->
        %{
          path: generated_default_path(),
          source: :generated_default,
          server: @default_linear_mcp_url
        }

      true ->
        %{path: nil, source: :disabled, server: nil}
    end
  end

  @spec generated_default_path() :: String.t()
  def generated_default_path do
    log_file = Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    log_dir = Path.dirname(Path.expand(log_file))
    Path.join(log_dir, @generated_file_name)
  end

  @spec default_linear_mcp_url() :: String.t()
  def default_linear_mcp_url, do: @default_linear_mcp_url

  defp validate_user_override(path) do
    expanded = Path.expand(path)

    if File.regular?(expanded) do
      case File.read(expanded) do
        {:ok, contents} ->
          decode_user_override(contents, expanded)

        {:error, reason} ->
          {:error, {:claude_mcp_config_unreadable, expanded, reason}}
      end
    else
      {:error, {:claude_mcp_config_not_found, expanded}}
    end
  end

  defp decode_user_override(contents, expanded) do
    case Jason.decode(contents) do
      {:ok, _payload} -> :ok
      {:error, reason} -> {:error, {:invalid_claude_mcp_config_json, expanded, reason}}
    end
  end

  defp write_generated_default_config(path) do
    expanded = Path.expand(path)
    token = Config.linear_api_token()

    if is_binary(token) and String.trim(token) != "" do
      :ok = File.mkdir_p(Path.dirname(expanded))
      contents = Jason.encode!(generated_default_payload(token), pretty: true)

      case File.read(expanded) do
        {:ok, ^contents} ->
          :ok

        _ ->
          File.write(expanded, contents)
      end
      |> case do
        :ok -> :ok
        {:error, reason} -> {:error, {:claude_default_mcp_config_write_failed, expanded, reason}}
      end
    else
      {:error, :missing_linear_api_token}
    end
  end

  defp generated_default_payload(token) do
    %{
      "mcpServers" => %{
        "linear" => %{
          "type" => "http",
          "url" => @default_linear_mcp_url,
          "headers" => %{
            "Authorization" => "Bearer #{token}"
          }
        }
      }
    }
  end

  defp maybe_log_config_ready(_details, false), do: :ok

  defp maybe_log_config_ready(%{path: path, source: source, server: server}, true)
       when is_binary(path) do
    Logger.info(
      "Claude MCP config ready source=#{source} path=#{path}" <>
        if(is_binary(server), do: " server=#{server}", else: "")
    )
  end
end
