defmodule SymphonyElixir.Claude.SessionLog do
  @moduledoc """
  Persists Claude session output per issue/session as JSONL and exposes metadata for the API.
  """

  alias SymphonyElixir.LogFile

  @tail_line_count 20

  @type turn_log :: %{
          issue_identifier: String.t(),
          issue_dir: Path.t(),
          pending_path: Path.t(),
          final_path: Path.t() | nil,
          started_at: String.t()
        }

  @spec begin_turn(String.t()) :: {:ok, turn_log()} | {:error, term()}
  def begin_turn(issue_identifier) when is_binary(issue_identifier) do
    started_at = timestamp_token()
    issue_dir = issue_directory(issue_identifier)
    pending_path = Path.join(issue_dir, "#{started_at}--pending.raw")

    with :ok <- File.mkdir_p(issue_dir),
         :ok <- File.write(pending_path, "", [:write]) do
      {:ok,
       %{
         issue_identifier: issue_identifier,
         issue_dir: issue_dir,
         pending_path: pending_path,
         final_path: nil,
         started_at: started_at
       }}
    end
  end

  @spec finish_turn(turn_log(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def finish_turn(%{issue_dir: issue_dir, pending_path: pending_path, started_at: started_at}, session_id) do
    final_name =
      case sanitize_token(session_id) do
        nil -> "#{started_at}.jsonl"
        sanitized -> "#{started_at}--#{sanitized}.jsonl"
      end

    final_path = Path.join(issue_dir, final_name)

    with :ok <- materialize_jsonl_log(pending_path, final_path),
         :ok <- promote_latest(final_path, issue_dir) do
      {:ok, final_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_issue_logs(String.t()) :: [map()]
  def list_issue_logs(issue_identifier) when is_binary(issue_identifier) do
    issue_identifier
    |> issue_directory()
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.map(&log_metadata/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @spec issue_directory(String.t()) :: Path.t()
  def issue_directory(issue_identifier) when is_binary(issue_identifier) do
    Path.join([logs_root(), "claude", sanitize_issue_identifier(issue_identifier)])
  end

  defp logs_root do
    Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    |> Path.expand()
    |> Path.dirname()
  end

  defp materialize_jsonl_log(source, destination) do
    with {:ok, contents} <- File.read(source),
         :ok <- write_jsonl_records(destination, contents) do
      File.rm(source)
    end
  end

  defp write_jsonl_records(destination, contents) do
    records = build_records(contents)
    encoded = Enum.map_join(records, "\n", &Jason.encode!/1) <> trailing_newline(records)
    File.write(destination, encoded)
  end

  defp promote_latest(final_path, issue_dir) do
    latest_path = Path.join(issue_dir, "latest.jsonl")
    File.rm_rf(latest_path)

    case File.ln_s(final_path, latest_path) do
      :ok -> :ok
      {:error, _reason} -> File.cp(final_path, latest_path)
    end
  end

  defp log_metadata(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, contents} <- File.read(path),
         {:ok, updated_at} <- DateTime.from_unix(stat.mtime) do
      %{
        path: path,
        session_id: session_id_from_log(path, contents),
        updated_at: DateTime.to_iso8601(updated_at),
        tail: tail_text(contents)
      }
    else
      _ -> nil
    end
  end

  defp tail_text(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.take(-@tail_line_count)
    |> Enum.join("\n")
  end

  defp session_id_from_log(path, contents) do
    session_id_from_filename(path) || session_id_from_contents(contents)
  end

  defp session_id_from_filename(path) do
    case Regex.run(~r/^\d{8}T\d{6}Z--(.+)\.jsonl$/, Path.basename(path), capture: :all_but_first) do
      [session_id] when session_id not in ["pending", "latest"] -> session_id
      _ -> nil
    end
  end

  defp session_id_from_contents(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"session_id" => session_id}} when is_binary(session_id) ->
          session_id

        {:ok, %{"payload" => %{"session_id" => session_id}}} when is_binary(session_id) ->
          session_id

        {:error, _reason} ->
          nil

        _ ->
          nil
      end
    end)
  end

  defp build_records(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.map(&build_record/1)
  end

  defp build_record(line) when is_binary(line) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        %{
          "time" => timestamp,
          "kind" => "claude_stream",
          "payload" => payload,
          "session_id" => session_id_from_payload(payload)
        }
        |> reject_nil_values()

      _ ->
        %{
          "time" => timestamp,
          "kind" => "raw_line",
          "text" => line
        }
    end
  end

  defp session_id_from_payload(%{"session_id" => session_id}) when is_binary(session_id), do: session_id
  defp session_id_from_payload(_payload), do: nil

  defp reject_nil_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp trailing_newline([]), do: ""
  defp trailing_newline(_records), do: "\n"

  defp sanitize_issue_identifier(issue_identifier) do
    sanitize_token(issue_identifier) || "unknown-issue"
  end

  defp sanitize_token(nil), do: nil

  defp sanitize_token(value) when is_binary(value) do
    sanitized = Regex.replace(~r/[^A-Za-z0-9._-]+/, value, "_")
    if sanitized == "", do: nil, else: sanitized
  end

  defp timestamp_token do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
