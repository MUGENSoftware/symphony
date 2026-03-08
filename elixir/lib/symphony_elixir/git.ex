defmodule SymphonyElixir.Git do
  @moduledoc """
  Handles mechanical git operations outside of Claude to reduce token usage.

  When `git.enabled` is true in the workflow config, this module takes over:
  - Branch creation and checkout (before Claude starts)
  - Fetching and merging the base branch (before each run)
  - Pushing commits to the remote (after Claude finishes)
  - Creating or updating pull requests (after Claude finishes)

  Claude is left with only the tasks that require intelligence:
  - Deciding when to commit
  - Writing commit messages
  - Conflict resolution (if merge fails, Claude handles it)
  """

  require Logger
  alias SymphonyElixir.Config

  @cmd_timeout_ms 60_000

  @doc """
  Prepares the workspace git state before Claude starts working.

  1. Fetches latest from origin
  2. Creates or checks out the feature branch
  3. Merges base branch into the feature branch
  """
  @type setup_result :: %{
          branch: String.t(),
          base_branch: String.t(),
          merge: :clean | {:conflicts, String.t()}
        }

  @spec setup_branch(Path.t(), String.t()) :: {:ok, setup_result()} | {:error, term()}
  def setup_branch(workspace, issue_identifier) do
    unless Config.git_enabled?() do
      throw(:git_not_enabled)
    end

    branch_name = branch_name_for_issue(issue_identifier)
    base_branch = Config.git_base_branch()

    with :ok <- fetch_origin(workspace, base_branch),
         :ok <- ensure_branch(workspace, branch_name, base_branch) do
      merge_status = merge_base_branch(workspace, base_branch)

      result = %{
        branch: branch_name,
        base_branch: base_branch,
        merge:
          case merge_status do
            :ok -> :clean
            {:error, {:git_merge_conflict, _status, output}} -> {:conflicts, output}
          end
      }

      Logger.info("Git branch setup complete workspace=#{workspace} branch=#{branch_name} merge=#{inspect(result.merge)}")
      {:ok, result}
    end
  end

  @doc """
  Pushes committed changes and creates/updates PR after Claude finishes.

  1. Checks if there are commits to push
  2. Pushes to origin
  3. Creates or updates the pull request
  """
  @spec publish(Path.t(), String.t(), map()) :: :ok | {:error, term()}
  def publish(workspace, issue_identifier, issue) do
    unless Config.git_enabled?() do
      throw(:git_not_enabled)
    end

    branch_name = branch_name_for_issue(issue_identifier)
    base_branch = Config.git_base_branch()

    with :ok <- maybe_push(workspace, branch_name),
         :ok <- maybe_create_or_update_pr(workspace, issue, base_branch) do
      Logger.info("Git publish complete workspace=#{workspace} branch=#{branch_name}")
      :ok
    end
  end

  @doc """
  Returns the branch name for a given issue identifier.
  """
  @spec branch_name_for_issue(String.t()) :: String.t()
  def branch_name_for_issue(issue_identifier) do
    prefix = Config.git_branch_prefix()
    safe_id = issue_identifier |> String.replace(~r/[^a-zA-Z0-9._-]/, "-") |> String.downcase()
    prefix <> safe_id
  end

  # -- Private: branch setup --

  defp fetch_origin(workspace, base_branch) do
    case run_git(workspace, ["fetch", "origin", base_branch]) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.warning("Git fetch failed workspace=#{workspace} status=#{status} output=#{inspect(truncate(output))}")
        {:error, {:git_fetch_failed, status, output}}
    end
  end

  defp ensure_branch(workspace, branch_name, base_branch) do
    case run_git(workspace, ["rev-parse", "--verify", branch_name]) do
      {_output, 0} ->
        # Branch exists locally, check it out
        checkout(workspace, branch_name)

      {_output, _status} ->
        # Branch doesn't exist locally, check if it exists on remote
        case run_git(workspace, ["rev-parse", "--verify", "origin/#{branch_name}"]) do
          {_output, 0} ->
            # Exists on remote, create local tracking branch
            case run_git(workspace, ["checkout", "-b", branch_name, "origin/#{branch_name}"]) do
              {_output, 0} -> :ok
              {output, status} -> {:error, {:git_checkout_failed, status, output}}
            end

          {_output, _status} ->
            # Doesn't exist anywhere, create from base branch
            case run_git(workspace, ["checkout", "-b", branch_name, "origin/#{base_branch}"]) do
              {_output, 0} -> :ok
              {output, status} -> {:error, {:git_branch_create_failed, status, output}}
            end
        end
    end
  end

  defp checkout(workspace, branch_name) do
    case run_git(workspace, ["checkout", branch_name]) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_checkout_failed, status, output}}
    end
  end

  defp merge_base_branch(workspace, base_branch) do
    case run_git(workspace, ["-c", "merge.conflictstyle=zdiff3", "merge", "origin/#{base_branch}", "--no-edit"]) do
      {_output, 0} ->
        :ok

      {output, status} ->
        # Merge conflict — abort and let Claude handle it during the run
        Logger.warning("Git merge had conflicts, aborting for Claude to resolve workspace=#{workspace}")
        run_git(workspace, ["merge", "--abort"])
        {:error, {:git_merge_conflict, status, output}}
    end
  end

  # -- Private: publish --

  defp maybe_push(workspace, branch_name) do
    unless Config.git_auto_push?() do
      Logger.info("Git auto-push disabled, skipping push workspace=#{workspace}")
      :ok
    else
      do_push(workspace, branch_name)
    end
  end

  defp do_push(workspace, branch_name) do
    # Check if there are commits ahead of origin
    case run_git(workspace, ["rev-list", "--count", "origin/#{branch_name}..HEAD"]) do
      {"0\n", 0} ->
        Logger.info("No new commits to push workspace=#{workspace}")
        :ok

      {_count, 0} ->
        push_to_origin(workspace, branch_name)

      {_output, _status} ->
        # Branch might not exist on remote yet, push anyway
        push_to_origin(workspace, branch_name)
    end
  end

  defp push_to_origin(workspace, branch_name) do
    case run_git(workspace, ["push", "-u", "origin", branch_name]) do
      {_output, 0} ->
        Logger.info("Pushed to origin workspace=#{workspace} branch=#{branch_name}")
        :ok

      {output, status} ->
        Logger.warning("Git push failed workspace=#{workspace} status=#{status} output=#{inspect(truncate(output))}")
        {:error, {:git_push_failed, status, output}}
    end
  end

  defp maybe_create_or_update_pr(workspace, issue, base_branch) do
    unless Config.git_auto_pr?() do
      Logger.info("Git auto-pr disabled, skipping PR workspace=#{workspace}")
      :ok
    else
      do_create_or_update_pr(workspace, issue, base_branch)
    end
  end

  defp do_create_or_update_pr(workspace, issue, base_branch) do
    title = Map.get(issue, :title, "Automated change")
    identifier = Map.get(issue, :identifier, "")
    description = Map.get(issue, :description, "")

    pr_title = "#{identifier}: #{title}"
    pr_body = "Resolves #{identifier}\n\n#{description}"

    case run_cmd(workspace, "gh", ["pr", "view", "--json", "state", "-q", ".state"]) do
      {state, 0} when state in ["OPEN\n", "DRAFT\n"] ->
        # PR exists and is open, update it
        case run_cmd(workspace, "gh", ["pr", "edit", "--title", pr_title, "--body", pr_body]) do
          {_output, 0} ->
            Logger.info("Updated existing PR workspace=#{workspace}")
            :ok

          {output, status} ->
            Logger.warning("PR update failed workspace=#{workspace} status=#{status}")
            {:error, {:pr_update_failed, status, output}}
        end

      _no_pr_or_closed ->
        # No PR or closed, create one
        case run_cmd(workspace, "gh", [
               "pr",
               "create",
               "--base",
               base_branch,
               "--title",
               pr_title,
               "--body",
               pr_body
             ]) do
          {output, 0} ->
            Logger.info("Created PR workspace=#{workspace} url=#{String.trim(output)}")
            :ok

          {output, status} ->
            Logger.warning("PR create failed workspace=#{workspace} status=#{status}")
            {:error, {:pr_create_failed, status, output}}
        end
    end
  end

  # -- Private: shell helpers --

  defp run_git(workspace, args) do
    run_cmd(workspace, "git", args)
  end

  defp run_cmd(workspace, cmd, args) do
    task =
      Task.async(fn ->
        System.cmd(cmd, args, cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, @cmd_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {"command timed out after #{@cmd_timeout_ms}ms", 1}
    end
  end

  defp truncate(output, max_bytes \\ 1_024) do
    binary_output = IO.iodata_to_binary(output)

    if byte_size(binary_output) <= max_bytes do
      binary_output
    else
      binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end
end
