defmodule SymphonyElixir.Claude.Tools.GitTool do
  @moduledoc """
  Dynamic tools for git operations that Claude can call mid-turn.

  When `git.enabled` is true, these tools let Claude interact with git
  through the orchestrator instead of shelling out via Bash tool calls,
  saving tokens on parsing raw git output.

  Tools:
  - `git_status` — returns branch, staged/unstaged files, ahead/behind count
  - `git_commit` — stages specified files (or all) and commits with a message
  """

  @behaviour SymphonyElixir.Claude.DynamicTool

  alias SymphonyElixir.Claude.DynamicTool
  alias SymphonyElixir.Config

  require Logger

  @cmd_timeout_ms 30_000

  @impl true
  def enabled?, do: Config.git_enabled?()

  @impl true
  def tool_specs do
    [
      %{
        "name" => "git_status",
        "description" =>
          "Get the current git status: branch name, staged/unstaged changes, and ahead/behind counts relative to origin. Use this instead of running `git status` or `git diff` yourself.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      },
      %{
        "name" => "git_commit",
        "description" =>
          "Stage files and create a git commit. Use this instead of running `git add` and `git commit` yourself.",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["message"],
          "properties" => %{
            "message" => %{
              "type" => "string",
              "description" => "The commit message."
            },
            "files" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Files to stage before committing. If omitted or empty, stages all changes (git add -A)."
            }
          }
        }
      }
    ]
  end

  @impl true
  def execute("git_status", _arguments, opts) do
    workspace = Keyword.fetch!(opts, :workspace)

    with {:ok, branch} <- current_branch(workspace),
         {:ok, status} <- porcelain_status(workspace),
         {:ok, ahead_behind} <- ahead_behind(workspace, branch) do
      DynamicTool.success_response(
        %{
          "branch" => branch,
          "staged" => status.staged,
          "unstaged" => status.unstaged,
          "untracked" => status.untracked,
          "ahead" => ahead_behind.ahead,
          "behind" => ahead_behind.behind
        },
        true
      )
    else
      {:error, reason} ->
        DynamicTool.error_response(%{
          "error" => %{"message" => "git_status failed", "reason" => inspect(reason)}
        })
    end
  end

  def execute("git_commit", arguments, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    message = arguments["message"] || arguments[:message]
    files = arguments["files"] || arguments[:files] || []

    cond do
      not is_binary(message) or String.trim(message) == "" ->
        DynamicTool.error_response(%{
          "error" => %{"message" => "`git_commit` requires a non-empty `message` string."}
        })

      true ->
        do_commit(workspace, String.trim(message), files)
    end
  end

  def execute(tool_name, _arguments, _opts) do
    DynamicTool.error_response(%{
      "error" => %{"message" => "GitTool does not handle tool: #{tool_name}"}
    })
  end

  # -- git_status helpers --

  defp current_branch(workspace) do
    case run_git(workspace, ["branch", "--show-current"]) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {output, status} -> {:error, {:git_branch, status, output}}
    end
  end

  defp porcelain_status(workspace) do
    case run_git(workspace, ["status", "--porcelain=v1"]) do
      {output, 0} ->
        lines = output |> String.split("\n", trim: true)

        staged =
          lines
          |> Enum.filter(&String.match?(&1, ~r/^[MADRC]/))
          |> Enum.map(&String.slice(&1, 3..-1//1))

        unstaged =
          lines
          |> Enum.filter(&String.match?(&1, ~r/^.[MADRC]/))
          |> Enum.map(&String.slice(&1, 3..-1//1))

        untracked =
          lines
          |> Enum.filter(&String.starts_with?(&1, "??"))
          |> Enum.map(&String.slice(&1, 3..-1//1))

        {:ok, %{staged: staged, unstaged: unstaged, untracked: untracked}}

      {output, status} ->
        {:error, {:git_status, status, output}}
    end
  end

  defp ahead_behind(workspace, branch) do
    case run_git(workspace, ["rev-list", "--left-right", "--count", "#{branch}...origin/#{branch}"]) do
      {output, 0} ->
        case String.split(String.trim(output), "\t") do
          [ahead, behind] ->
            {:ok, %{ahead: String.to_integer(ahead), behind: String.to_integer(behind)}}

          _other ->
            {:ok, %{ahead: 0, behind: 0}}
        end

      {_output, _status} ->
        # Remote tracking branch might not exist yet
        {:ok, %{ahead: 0, behind: 0}}
    end
  end

  # -- git_commit helpers --

  defp do_commit(workspace, message, files) do
    stage_result =
      if files == [] do
        run_git(workspace, ["add", "-A"])
      else
        run_git(workspace, ["add" | files])
      end

    case stage_result do
      {_output, 0} ->
        case run_git(workspace, ["commit", "-m", message]) do
          {output, 0} ->
            DynamicTool.success_response(
              %{"message" => "Commit created", "output" => String.trim(output)},
              true
            )

          {output, status} ->
            if output =~ "nothing to commit" do
              DynamicTool.success_response(
                %{"message" => "Nothing to commit, working tree clean"},
                true
              )
            else
              DynamicTool.error_response(%{
                "error" => %{
                  "message" => "git commit failed",
                  "status" => status,
                  "output" => String.trim(output)
                }
              })
            end
        end

      {output, status} ->
        DynamicTool.error_response(%{
          "error" => %{
            "message" => "git add failed",
            "status" => status,
            "output" => String.trim(output)
          }
        })
    end
  end

  # -- Shell helpers --

  defp run_git(workspace, args) do
    task =
      Task.async(fn ->
        System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, @cmd_timeout_ms) do
      {:ok, result} -> result
      nil ->
        Task.shutdown(task, :brutal_kill)
        {"command timed out after #{@cmd_timeout_ms}ms", 1}
    end
  end
end
