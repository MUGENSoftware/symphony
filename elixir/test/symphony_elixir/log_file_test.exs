defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end

  test "default_json_log_file/0 uses the current working directory" do
    assert LogFile.default_json_log_file() == Path.join(File.cwd!(), "log/symphony.jsonl")
  end

  test "default_json_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_json_log_file("/tmp/symphony-logs") ==
             "/tmp/symphony-logs/log/symphony.jsonl"
  end

  test "default_linear_pull_log_file/0 uses the current working directory" do
    assert LogFile.default_linear_pull_log_file() == Path.join(File.cwd!(), "log/linear-pull.log")
  end

  test "default_linear_pull_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_linear_pull_log_file("/tmp/symphony-logs") ==
             "/tmp/symphony-logs/log/linear-pull.log"
  end

  test "set_logs_root/1 updates main, JSON, and linear pull log destinations" do
    previous_main_log = Application.get_env(:symphony_elixir, :log_file)
    previous_json_log = Application.get_env(:symphony_elixir, :json_log_file)
    previous_linear_log = Application.get_env(:symphony_elixir, :linear_pull_log_file)

    on_exit(fn ->
      restore_env(:log_file, previous_main_log)
      restore_env(:json_log_file, previous_json_log)
      restore_env(:linear_pull_log_file, previous_linear_log)
    end)

    assert :ok = LogFile.set_logs_root("/tmp/symphony-logs")
    assert Application.get_env(:symphony_elixir, :log_file) == "/tmp/symphony-logs/log/symphony.log"

    assert Application.get_env(:symphony_elixir, :json_log_file) ==
             "/tmp/symphony-logs/log/symphony.jsonl"

    assert Application.get_env(:symphony_elixir, :linear_pull_log_file) ==
             "/tmp/symphony-logs/log/linear-pull.log"
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
