defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures JSON log files for application lifecycle and related artifacts.
  """

  require Logger

  alias LoggerJSON.Formatters.Basic, as: JSONFormatter

  @handler_id :symphony_json_log
  @default_log_relative_path "log/symphony.jsonl"
  @default_linear_pull_log_relative_path "log/linear-pull.jsonl"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5
  @rotation_env_var "SYMPHONY_LOG_ROTATION"

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(File.cwd!())
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @spec default_linear_pull_log_file() :: Path.t()
  def default_linear_pull_log_file do
    default_linear_pull_log_file(File.cwd!())
  end

  @spec default_linear_pull_log_file(Path.t()) :: Path.t()
  def default_linear_pull_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_linear_pull_log_relative_path)
  end

  @spec set_logs_root(Path.t()) :: :ok
  def set_logs_root(logs_root) when is_binary(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, default_log_file(logs_root))
    Application.put_env(:symphony_elixir, :linear_pull_log_file, default_linear_pull_log_file(logs_root))
    :ok
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:symphony_elixir, :log_file, default_log_file())
    rotation_enabled = log_rotation_enabled?()

    max_bytes =
      if rotation_enabled do
        Application.get_env(:symphony_elixir, :log_file_max_bytes, @default_max_bytes)
      else
        :infinity
      end

    max_files =
      if rotation_enabled do
        Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)
      else
        0
      end

    setup_handler(log_file, max_bytes, max_files)
  end

  defp setup_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_handler(@handler_id)

    case :logger.add_handler(
           @handler_id,
           :logger_std_h,
           handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure JSON log handler: #{inspect(reason)}")
        :ok
    end
  end

  defp remove_handler(handler_id) do
    case :logger.remove_handler(handler_id) do
      :ok -> :ok
      {:error, {:not_found, ^handler_id}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_default_console_handler do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp log_rotation_enabled? do
    case Application.get_env(:symphony_elixir, :log_file_rotation_enabled) do
      nil -> env_rotation_enabled?(System.get_env(@rotation_env_var))
      value -> truthy_rotation_setting?(value)
    end
  end

  defp env_rotation_enabled?(nil), do: true
  defp env_rotation_enabled?(value), do: truthy_rotation_setting?(value)

  defp truthy_rotation_setting?(value) when is_boolean(value), do: value

  defp truthy_rotation_setting?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    normalized not in ["0", "false", "off", "no", "disabled"]
  end

  defp truthy_rotation_setting?(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> truthy_rotation_setting?()
  end

  defp truthy_rotation_setting?(value) when is_integer(value), do: value != 0
  defp truthy_rotation_setting?(_value), do: true

  defp handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: JSONFormatter.new(metadata: :all),
      config: %{
        type: :file,
        file: String.to_charlist(path),
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end
end
