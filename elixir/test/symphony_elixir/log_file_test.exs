defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end

  test "default_linear_pull_log_file/0 uses the current working directory" do
    assert LogFile.default_linear_pull_log_file() == Path.join(File.cwd!(), "log/linear-pull.log")
  end

  test "default_linear_pull_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_linear_pull_log_file("/tmp/symphony-logs") ==
             "/tmp/symphony-logs/log/linear-pull.log"
  end

  test "set_logs_root/1 updates both the main and linear pull log destinations" do
    previous_main_log = Application.get_env(:symphony_elixir, :log_file)
    previous_linear_log = Application.get_env(:symphony_elixir, :linear_pull_log_file)

    on_exit(fn ->
      if is_nil(previous_main_log) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_main_log)
      end

      if is_nil(previous_linear_log) do
        Application.delete_env(:symphony_elixir, :linear_pull_log_file)
      else
        Application.put_env(:symphony_elixir, :linear_pull_log_file, previous_linear_log)
      end
    end)

    assert :ok = LogFile.set_logs_root("/tmp/symphony-logs")
    assert Application.get_env(:symphony_elixir, :log_file) == "/tmp/symphony-logs/log/symphony.log"

    assert Application.get_env(:symphony_elixir, :linear_pull_log_file) ==
             "/tmp/symphony-logs/log/linear-pull.log"
  end
end
