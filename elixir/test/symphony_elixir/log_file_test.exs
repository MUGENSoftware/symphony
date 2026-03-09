defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.LogFile
  require Logger

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.jsonl")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.jsonl"
  end

  test "default_linear_pull_log_file/0 uses the current working directory" do
    assert LogFile.default_linear_pull_log_file() == Path.join(File.cwd!(), "log/linear-pull.jsonl")
  end

  test "default_linear_pull_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_linear_pull_log_file("/tmp/symphony-logs") ==
             "/tmp/symphony-logs/log/linear-pull.jsonl"
  end

  test "set_logs_root/1 updates main and linear pull log destinations" do
    previous_main_log = Application.get_env(:symphony_elixir, :log_file)
    previous_linear_log = Application.get_env(:symphony_elixir, :linear_pull_log_file)

    on_exit(fn ->
      restore_env(:log_file, previous_main_log)
      restore_env(:linear_pull_log_file, previous_linear_log)
    end)

    assert :ok = LogFile.set_logs_root("/tmp/symphony-logs")
    assert Application.get_env(:symphony_elixir, :log_file) == "/tmp/symphony-logs/log/symphony.jsonl"

    assert Application.get_env(:symphony_elixir, :linear_pull_log_file) ==
             "/tmp/symphony-logs/log/linear-pull.jsonl"
  end

  test "configure/0 writes JSON lines to a plain file and rotates without disk-log sidecars" do
    previous_main_log = Application.get_env(:symphony_elixir, :log_file)
    previous_max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes)
    previous_max_files = Application.get_env(:symphony_elixir, :log_file_max_files)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-json-log-#{System.unique_integer([:positive])}"
      )

    log_path = Path.join(test_root, "log/symphony.jsonl")

    on_exit(fn ->
      restore_env(:log_file, previous_main_log)
      restore_env(:log_file_max_bytes, previous_max_bytes)
      restore_env(:log_file_max_files, previous_max_files)
      LogFile.configure()
      File.rm_rf(test_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)
    Application.put_env(:symphony_elixir, :log_file_max_bytes, 200)
    Application.put_env(:symphony_elixir, :log_file_max_files, 2)

    assert :ok = LogFile.configure()

    Logger.metadata(issue_id: "issue-1", issue_identifier: "MT-1", session_id: "session-1")

    Enum.each(1..12, fn index ->
      Logger.info("json lifecycle message #{index} " <> String.duplicate("x", 40))
    end)

    Logger.flush()

    assert File.exists?(log_path)

    files =
      Path.wildcard(log_path <> "*")
      |> Enum.sort()

    assert Enum.any?(files, &(&1 == log_path))
    assert Enum.any?(files, &String.ends_with?(&1, ".0"))
    refute Enum.any?(files, &String.ends_with?(&1, ".idx"))
    refute Enum.any?(files, &String.ends_with?(&1, ".siz"))

    lines =
      files
      |> Enum.filter(fn path ->
        path == log_path or String.match?(path, ~r/\.jsonl\.\d+$/)
      end)
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n", trim: true)
      end)

    assert lines != []

    assert Enum.any?(lines, fn line ->
             case Jason.decode(line) do
               {:ok, %{"message" => message, "metadata" => %{"issue_identifier" => "MT-1"}}} ->
                 String.contains?(message, "json lifecycle message")

               _ ->
                 false
             end
           end)
  end

  test "configure/0 disables rotation when application config turns it off" do
    previous_main_log = Application.get_env(:symphony_elixir, :log_file)
    previous_max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes)
    previous_max_files = Application.get_env(:symphony_elixir, :log_file_max_files)
    previous_rotation_enabled = Application.get_env(:symphony_elixir, :log_file_rotation_enabled)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-json-log-no-rotation-#{System.unique_integer([:positive])}"
      )

    log_path = Path.join(test_root, "log/symphony.jsonl")

    on_exit(fn ->
      restore_env(:log_file, previous_main_log)
      restore_env(:log_file_max_bytes, previous_max_bytes)
      restore_env(:log_file_max_files, previous_max_files)
      restore_env(:log_file_rotation_enabled, previous_rotation_enabled)
      LogFile.configure()
      File.rm_rf(test_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)
    Application.put_env(:symphony_elixir, :log_file_max_bytes, 200)
    Application.put_env(:symphony_elixir, :log_file_max_files, 2)
    Application.put_env(:symphony_elixir, :log_file_rotation_enabled, false)

    assert :ok = LogFile.configure()
    assert {:ok, handler_config} = :logger.get_handler_config(:symphony_json_log)
    assert handler_config.config.max_no_bytes == :infinity
    assert handler_config.config.max_no_files == 0
  end

  test "configure/0 disables rotation when SYMPHONY_LOG_ROTATION=false" do
    previous_main_log = Application.get_env(:symphony_elixir, :log_file)
    previous_max_bytes = Application.get_env(:symphony_elixir, :log_file_max_bytes)
    previous_max_files = Application.get_env(:symphony_elixir, :log_file_max_files)
    previous_rotation_enabled = Application.get_env(:symphony_elixir, :log_file_rotation_enabled)
    previous_rotation_env = System.get_env("SYMPHONY_LOG_ROTATION")

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-json-log-env-no-rotation-#{System.unique_integer([:positive])}"
      )

    log_path = Path.join(test_root, "log/symphony.jsonl")

    on_exit(fn ->
      restore_env(:log_file, previous_main_log)
      restore_env(:log_file_max_bytes, previous_max_bytes)
      restore_env(:log_file_max_files, previous_max_files)
      restore_env(:log_file_rotation_enabled, previous_rotation_enabled)

      if is_binary(previous_rotation_env) do
        System.put_env("SYMPHONY_LOG_ROTATION", previous_rotation_env)
      else
        System.delete_env("SYMPHONY_LOG_ROTATION")
      end

      LogFile.configure()
      File.rm_rf(test_root)
    end)

    Application.put_env(:symphony_elixir, :log_file, log_path)
    Application.put_env(:symphony_elixir, :log_file_max_bytes, 200)
    Application.put_env(:symphony_elixir, :log_file_max_files, 2)
    Application.delete_env(:symphony_elixir, :log_file_rotation_enabled)
    System.put_env("SYMPHONY_LOG_ROTATION", "false")

    assert :ok = LogFile.configure()
    assert {:ok, handler_config} = :logger.get_handler_config(:symphony_json_log)
    assert handler_config.config.max_no_bytes == :infinity
    assert handler_config.config.max_no_files == 0
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
