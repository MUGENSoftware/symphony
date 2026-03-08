defmodule SymphonyElixir.Claude.UsageLimit do
  @moduledoc """
  Parses Claude usage-cap results into a concrete reset deadline.
  """

  @message_regex ~r/^You've hit your limit\s*·\s*resets\s+(?<time>[^()]+?)\s+\((?<timezone>[^)]+)\)$/i
  @time_regex ~r/^(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<period>am|pm)$/i

  @type parsed_usage_limit :: %{
          reason: :usage_cap,
          message: String.t(),
          timezone: String.t(),
          reset_at: DateTime.t(),
          retry_after_ms: non_neg_integer()
        }

  @spec parse_result(map(), DateTime.t()) :: {:ok, parsed_usage_limit()} | :no_match | {:error, term()}
  def parse_result(payload, now \\ DateTime.utc_now())

  def parse_result(%{"type" => "result", "is_error" => true, "result" => message}, %DateTime{} = now)
      when is_binary(message) do
    parse_message(message, now)
  end

  def parse_result(_payload, _now), do: :no_match

  @spec parse_message(String.t(), DateTime.t()) ::
          {:ok, parsed_usage_limit()} | :no_match | {:error, term()}
  def parse_message(message, %DateTime{} = now) when is_binary(message) do
    case Regex.named_captures(@message_regex, String.trim(message)) do
      %{"time" => raw_time, "timezone" => raw_timezone} ->
        with {:ok, {hour, minute}} <- parse_time(raw_time),
             timezone <- String.trim(raw_timezone),
             {:ok, local_date} <- local_date_for_now(now, timezone),
             {:ok, reset_at} <- next_reset_at(now, local_date, timezone, hour, minute) do
          reset_at = DateTime.truncate(reset_at, :second)

          {:ok,
           %{
             reason: :usage_cap,
             message: message,
             timezone: timezone,
             reset_at: reset_at,
             retry_after_ms: max(DateTime.diff(reset_at, now, :millisecond), 0)
           }}
        else
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :no_match
    end
  end

  def parse_message(_message, _now), do: :no_match

  @spec parse_time(String.t()) :: {:ok, {0..23, 0..59}} | {:error, term()}
  def parse_time(time_text) when is_binary(time_text) do
    case Regex.named_captures(@time_regex, String.trim(time_text)) do
      %{"hour" => raw_hour, "minute" => raw_minute, "period" => raw_period} ->
        with {hour, ""} <- Integer.parse(raw_hour),
             true <- hour in 1..12,
             minute <- parse_minute(raw_minute),
             period <- String.downcase(raw_period) do
          {:ok, {normalize_hour(hour, period), minute}}
        else
          _ -> {:error, {:invalid_reset_time, time_text}}
        end

      _ ->
        {:error, {:invalid_reset_time, time_text}}
    end
  end

  defp parse_minute(""), do: 0

  defp parse_minute(raw_minute) when is_binary(raw_minute) do
    case Integer.parse(raw_minute) do
      {minute, ""} when minute in 0..59 -> minute
      _ -> :invalid
    end
  end

  defp normalize_hour(12, "am"), do: 0
  defp normalize_hour(hour, "am"), do: hour
  defp normalize_hour(12, "pm"), do: 12
  defp normalize_hour(hour, "pm"), do: hour + 12

  defp local_date_for_now(now, timezone) do
    epoch = DateTime.to_unix(now)

    case date_command(["-r", Integer.to_string(epoch), "+%Y-%m-%d"], timezone) do
      {:ok, output} ->
        Date.from_iso8601(String.trim(output))

      {:error, _reason} ->
        with {:ok, output} <-
               date_command(["-d", "@" <> Integer.to_string(epoch), "+%Y-%m-%d"], timezone) do
          Date.from_iso8601(String.trim(output))
        end
    end
  end

  defp next_reset_at(now, local_date, timezone, hour, minute) do
    with {:ok, candidate} <- build_utc_datetime(local_date, timezone, hour, minute) do
      if DateTime.compare(candidate, now) == :gt do
        {:ok, candidate}
      else
        local_date
        |> Date.add(1)
        |> build_utc_datetime(timezone, hour, minute)
      end
    end
  end

  defp build_utc_datetime(date, timezone, hour, minute) do
    input =
      [
        Date.to_iso8601(date),
        " ",
        hour |> Integer.to_string() |> String.pad_leading(2, "0"),
        ":",
        minute |> Integer.to_string() |> String.pad_leading(2, "0"),
        ":00"
      ]
      |> IO.iodata_to_binary()

    parse_args = ["-j", "-f", "%Y-%m-%d %H:%M:%S", input, "+%s"]

    case date_command(parse_args, timezone) do
      {:ok, output} ->
        unix_to_datetime(output)

      {:error, _reason} ->
        with {:ok, output} <- date_command(["-d", input, "+%s"], timezone) do
          unix_to_datetime(output)
        end
    end
  end

  defp unix_to_datetime(output) do
    case Integer.parse(String.trim(output)) do
      {unix, ""} -> DateTime.from_unix(unix)
      _ -> {:error, {:invalid_reset_unix, output}}
    end
  end

  defp date_command(args, timezone) when is_list(args) and is_binary(timezone) do
    case System.cmd("/bin/date", args, env: [{"TZ", timezone}], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:date_command_failed, status, String.trim(output)}}
    end
  end
end
