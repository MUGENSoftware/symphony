defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    git_setup = Keyword.get(opts, :git_setup)

    if Config.git_enabled?() do
      rendered <> "\n\n" <> git_offload_context(issue, git_setup)
    else
      rendered
    end
  end

  defp git_offload_context(issue, git_setup) do
    branch_name =
      case git_setup do
        %{branch: branch} -> branch
        _ -> SymphonyElixir.Git.branch_name_for_issue(issue.identifier || "issue")
      end

    base_branch =
      case git_setup do
        %{base_branch: base} -> base
        _ -> Config.git_base_branch()
      end

    merge_info =
      case git_setup do
        %{merge: :clean} ->
          "- Base branch merge: clean (up to date with `origin/#{base_branch}`)"

        %{merge: {:conflicts, _output}} ->
          "- Base branch merge: **CONFLICTS DETECTED** — resolve these before starting your work"

        _ ->
          "- Base branch merge: status unknown"
      end

    tools_note =
      if Config.git_enabled?() do
        """

        **Available git tools (use these instead of Bash):**
        - `git_status` — check branch, staged/unstaged files, ahead/behind count
        - `git_commit` — stage files and create commits with a message
        """
      else
        ""
      end

    """
    ## Git Operations — Handled by Infrastructure

    The following git operations are managed automatically by the orchestrator.
    **Do NOT perform these yourself** — doing so wastes tokens and may conflict
    with the automated workflow:

    - Branch creation and checkout (you are on `#{branch_name}`)
    - `git fetch` / `git pull` / `git merge origin/#{base_branch}`
    - `git push` to origin (happens automatically after your work completes)
    - Pull request creation and updates (handled after push)
    #{merge_info}
    #{tools_note}
    **Your only responsibilities:**
    - Use the `git_commit` tool to commit your changes with clear messages
    - Resolve merge conflicts if they exist in the working tree

    Do not run the /push, /pull, or /land skills. Focus on the task itself.
    """
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
