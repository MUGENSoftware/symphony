defmodule SymphonyElixir.Linear.PullLog do
  @moduledoc """
  Dedicated append-only JSON log for Linear poll and refresh activity.
  """

  require Logger
  alias SymphonyElixir.LogFile

  @spec log(atom() | String.t(), map() | keyword()) :: :ok
  def log(event, fields \\ %{})

  @spec log(atom() | String.t(), map() | keyword()) :: :ok
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
    payload =
      fields
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.reduce(
        %{
          time: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
          event: normalize_event(event)
        },
        fn {key, value}, acc ->
          Map.put(acc, key, normalize_value(value))
        end
      )

    Jason.encode_to_iodata!(payload)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp normalize_event(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_event(value), do: to_string(value)

  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_value(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{}, fn {key, nested_value} ->
        {to_string(key), normalize_value(nested_value)}
      end)
    else
      Enum.map(value, &normalize_value/1)
    end
  end

  defp normalize_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), normalize_value(nested_value)}
    end)
  end

  defp normalize_value(value), do: value
end
