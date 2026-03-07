defmodule SymphonyElixir.Linear.PullLog do
  @moduledoc """
  Dedicated append-only log for Linear poll and refresh activity.
  """

  require Logger
  alias SymphonyElixir.LogFile

  @spec log(atom() | String.t(), map() | keyword()) :: :ok
  def log(event, fields \\ %{})

  def log(event, fields) when is_list(fields) do
    log(event, Map.new(fields))
  end

  def log(event, fields) when is_map(fields) do
    path =
      Application.get_env(
        :symphony_elixir,
        :linear_pull_log_file,
        LogFile.default_linear_pull_log_file()
      )

    expanded_path = Path.expand(path)
    :ok = File.mkdir_p(Path.dirname(expanded_path))

    case File.write(expanded_path, format_line(event, fields), [:append]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to write Linear pull log path=#{expanded_path} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp format_line(event, fields) do
    event_value =
      case event do
        value when is_atom(value) -> Atom.to_string(value)
        value -> to_string(value)
      end

    parts =
      [
        "timestamp=" <> DateTime.to_iso8601(DateTime.utc_now()),
        "event=" <> inspect(event_value)
      ] ++
        (fields
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
         |> Enum.map(fn {key, value} ->
           "#{key}=#{format_value(value)}"
         end))

    Enum.join(parts, " ") <> "\n"
  end

  defp format_value(value) when is_binary(value), do: inspect(value)
  defp format_value(value) when is_atom(value), do: inspect(value)
  defp format_value(value) when is_list(value), do: inspect(value, charlists: :as_lists)
  defp format_value(value) when is_map(value), do: inspect(value, charlists: :as_lists)
  defp format_value(value), do: inspect(value)
end
