defmodule SymphonyElixir.LogFile do
  @moduledoc """
  Configures OTP's built-in rotating disk log handler for application logs
  and a secondary structured JSON log handler using LoggerJSON.
  """

  require Logger

  alias LoggerJSON.Formatters.Basic, as: JSONFormatter

  @handler_id :symphony_disk_log
  @json_handler_id :symphony_json_log
  @default_log_relative_path "log/symphony.log"
  @default_json_log_relative_path "log/symphony.jsonl"
  @default_linear_pull_log_relative_path "log/linear-pull.log"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(File.cwd!())
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_relative_path)
  end

  @spec default_json_log_file() :: Path.t()
  def default_json_log_file do
    default_json_log_file(File.cwd!())
  end

  @spec default_json_log_file(Path.t()) :: Path.t()
  def default_json_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_json_log_relative_path)
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
    Application.put_env(:symphony_elixir, :json_log_file, default_json_log_file(logs_root))
    Application.put_env(:symphony_elixir, :linear_pull_log_file, default_linear_pull_log_file(logs_root))
    :ok
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:symphony_elixir, :log_file, default_log_file())
    max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes, @default_max_bytes)
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, @default_max_files)

    setup_disk_handler(log_file, max_bytes, max_files)
    configure_json_handler()
  end

  @spec configure_json_handler() :: :ok
  defp configure_json_handler do
    enabled = Application.get_env(:symphony_elixir, :json_log_enabled, true)

    if enabled do
      json_log_file =
        Application.get_env(:symphony_elixir, :json_log_file, default_json_log_file())

      max_bytes =
        Application.get_env(:symphony_elixir, :json_log_file_max_bytes, @default_max_bytes)

      max_files =
        Application.get_env(:symphony_elixir, :json_log_file_max_files, @default_max_files)

      setup_json_handler(json_log_file, max_bytes, max_files)
    else
      :ok
    end
  end

  defp setup_json_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_handler(@json_handler_id)

    case :logger.add_handler(
           @json_handler_id,
           :logger_disk_log_h,
           json_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure JSON log handler: #{inspect(reason)}")
        :ok
    end
  end

  defp setup_disk_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_handler(@handler_id)

    case :logger.add_handler(
           @handler_id,
           :logger_disk_log_h,
           disk_log_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure rotating log file handler: #{inspect(reason)}")
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

  defp disk_log_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: {:logger_formatter, %{single_line: true}},
      config: %{
        file: String.to_charlist(path),
        type: :wrap,
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end

  defp json_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: JSONFormatter.new(metadata: :all),
      config: %{
        file: String.to_charlist(path),
        type: :wrap,
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end
end
