defmodule SymphonyElixir.SessionLogTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Claude.SessionLog

  test "finish_turn/2 persists JSONL records and updates latest.jsonl" do
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-session-log-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:symphony_elixir, :log_file, Path.join(test_root, "log/symphony.jsonl"))

    on_exit(fn ->
      if previous_log_file do
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      else
        Application.delete_env(:symphony_elixir, :log_file)
      end

      File.rm_rf(test_root)
    end)

    {:ok, log_ref} = SessionLog.begin_turn("MT-123")

    File.write!(
      log_ref.pending_path,
      [
        "warning: stderr noise\n",
        "not-json\n",
        ~s({"type":"result","session_id":"session-123","usage":{"input_tokens":1,"output_tokens":2}}),
        "\n"
      ]
    )

    assert {:ok, final_path} = SessionLog.finish_turn(log_ref, "session-123")
    assert String.ends_with?(final_path, ".jsonl")
    assert File.exists?(final_path)

    latest_path = Path.join(Path.dirname(final_path), "latest.jsonl")
    assert File.exists?(latest_path)

    records =
      final_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(records, &(&1["kind"] == "raw_line" and &1["text"] == "warning: stderr noise"))
    assert Enum.any?(records, &(&1["kind"] == "raw_line" and &1["text"] == "not-json"))

    assert Enum.any?(records, fn record ->
             record["kind"] == "claude_stream" and
               get_in(record, ["payload", "session_id"]) == "session-123" and
               record["session_id"] == "session-123"
           end)

    listed_logs = SessionLog.list_issue_logs("MT-123")
    assert Enum.any?(listed_logs, &String.ends_with?(&1.path, ".jsonl"))
    assert Enum.any?(listed_logs, &String.ends_with?(&1.path, "latest.jsonl"))
    assert Enum.any?(listed_logs, &(&1.session_id == "session-123"))

    assert Enum.any?(listed_logs, fn log ->
             String.contains?(log.tail, ~s("kind":"raw_line")) and
               String.contains?(log.tail, ~s("session_id":"session-123"))
           end)
  end
end
