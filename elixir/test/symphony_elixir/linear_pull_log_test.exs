defmodule SymphonyElixir.LinearPullLogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Tracker, Workflow}
  alias SymphonyElixir.Linear.Client

  setup do
    previous_log_path = Application.get_env(:symphony_elixir, :linear_pull_log_file)
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_graphql_request_fun)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-linear-pull-log-#{System.unique_integer([:positive])}"
      )

    log_path = Path.join(test_root, "log/linear-pull.jsonl")
    Application.put_env(:symphony_elixir, :linear_pull_log_file, log_path)

    on_exit(fn ->
      if is_nil(previous_log_path) do
        Application.delete_env(:symphony_elixir, :linear_pull_log_file)
      else
        Application.put_env(:symphony_elixir, :linear_pull_log_file, previous_log_path)
      end

      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :linear_graphql_request_fun)
      else
        Application.put_env(:symphony_elixir, :linear_graphql_request_fun, previous_request_fun)
      end

      File.rm_rf(test_root)
    end)

    {:ok, log_path: log_path}
  end

  test "candidate issue fetch writes start, page, and success entries", %{log_path: log_path} do
    install_request_results([
      {:ok,
       %{
         status: 200,
         body: issue_page_response([issue_node("issue-1", "MT-1")], false, nil)
       }}
    ])

    assert {:ok, [%{identifier: "MT-1"}]} = Tracker.fetch_candidate_issues()
    assert_receive {:linear_request, payload, _headers}
    assert get_in(payload, ["variables", :projectSlug]) == "project"

    entries = read_entries(log_path)
    assert Enum.any?(entries, &(&1["event"] == "fetch_start" and &1["operation"] == "candidate_issues"))
    assert Enum.any?(entries, &(&1["states"] == ["Todo", "In Progress"]))
    assert Enum.any?(entries, &(&1["event"] == "page_fetch_start" and &1["page"] == 1))
    assert Enum.any?(entries, &(&1["event"] == "page_fetch_result" and &1["issue_identifiers"] == ["MT-1"]))
    assert Enum.any?(entries, &(&1["event"] == "fetch_success" and &1["issue_count"] == 1))
  end

  test "fetch_issues_by_states logs paginated pages", %{log_path: log_path} do
    install_request_results([
      {:ok,
       %{
         status: 200,
         body: issue_page_response([issue_node("issue-1", "MT-1")], true, "cursor-1")
       }},
      {:ok,
       %{
         status: 200,
         body: issue_page_response([issue_node("issue-2", "MT-2")], false, nil)
       }}
    ])

    assert {:ok, [%{identifier: "MT-1"}, %{identifier: "MT-2"}]} =
             Client.fetch_issues_by_states(["Todo"])

    entries = read_entries(log_path)
    assert Enum.any?(entries, &(&1["event"] == "page_fetch_start" and &1["operation"] == "issues_by_states" and &1["page"] == 1))
    assert Enum.any?(entries, &(&1["has_next_page"] == true and &1["next_cursor"] == "cursor-1"))
    assert Enum.any?(entries, &(&1["event"] == "page_fetch_start" and &1["page"] == 2))
    assert Enum.any?(entries, &(&1["event"] == "page_fetch_result" and &1["issue_identifiers"] == ["MT-2"]))
    assert Enum.any?(entries, &(&1["event"] == "fetch_success" and &1["issue_identifiers"] == ["MT-1", "MT-2"]))
  end

  test "issue state refresh logs requested ids and returned identifiers", %{log_path: log_path} do
    install_request_results([
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [issue_node("issue-1", "MT-1")]
             }
           }
         }
       }}
    ])

    assert {:ok, [%{id: "issue-1", identifier: "MT-1"}]} =
             Client.fetch_issue_states_by_ids(["issue-1"])

    entries = read_entries(log_path)
    assert Enum.any?(entries, &(&1["event"] == "fetch_start" and &1["issue_ids"] == ["issue-1"]))
    assert Enum.any?(entries, &(&1["operation"] == "issue_states_by_ids"))
    assert Enum.any?(entries, &(&1["event"] == "fetch_success" and &1["issue_identifiers"] == ["MT-1"]))
  end

  test "candidate issue fetch logs transport failures and HTTP status", %{log_path: log_path} do
    install_request_results([
      {:ok,
       %{
         status: 503,
         body: %{"errors" => [%{"message" => "Service unavailable"}]}
       }}
    ])

    assert {:error, {:linear_api_status, 503}} = Tracker.fetch_candidate_issues()

    entries = read_entries(log_path)

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "fetch_failure" and
               entry["operation"] == "candidate_issues" and
               entry["reason"] == "linear_api_status" and
               entry["status"] == 503
           end)
  end

  test "state fetch logs graphql error summaries", %{log_path: log_path} do
    install_request_results([
      {:ok,
       %{
         status: 200,
         body: %{
           "errors" => [
             %{"message" => "Bad filter"},
             %{"message" => "Another failure"}
           ]
         }
       }}
    ])

    assert {:error, {:linear_graphql_errors, [%{"message" => "Bad filter"}, %{"message" => "Another failure"}]}} =
             Client.fetch_issues_by_states(["Todo"])

    entries = read_entries(log_path)

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "fetch_failure" and
               entry["operation"] == "issues_by_states" and
               entry["reason"] == "linear_graphql_errors" and
               entry["graphql_errors"] == ["Bad filter", "Another failure"]
           end)
  end

  test "viewer lookup is logged when assignee is configured as me", %{log_path: log_path} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "me")

    install_request_results([
      {:ok,
       %{
         status: 200,
         body: %{"data" => %{"viewer" => %{"id" => "usr-123"}}}
       }},
      {:ok,
       %{
         status: 200,
         body: issue_page_response([issue_node("issue-1", "MT-1", %{"id" => "usr-123"})], false, nil)
       }}
    ])

    assert {:ok, [%{identifier: "MT-1"}]} = Tracker.fetch_candidate_issues()

    entries = read_entries(log_path)

    assert Enum.any?(entries, &(&1["event"] == "viewer_lookup_start" and &1["configured_assignee"] == "me"))

    assert Enum.any?(entries, fn entry ->
             entry["event"] == "viewer_lookup_success" and
               entry["configured_assignee"] == "me" and
               entry["viewer_id"] == "usr-123"
           end)

    assert Enum.any?(entries, &(&1["assignee_mode"] == "viewer"))
  end

  defp read_entries(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp install_request_results(results) do
    Process.put(:linear_request_results, results)

    Application.put_env(:symphony_elixir, :linear_graphql_request_fun, fn payload, headers ->
      send(self(), {:linear_request, payload, headers})

      case Process.get(:linear_request_results, []) do
        [result | rest] ->
          Process.put(:linear_request_results, rest)
          result

        [] ->
          raise "no stubbed Linear request result available"
      end
    end)
  end

  defp issue_page_response(nodes, has_next_page, end_cursor) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => nodes,
          "pageInfo" => %{
            "hasNextPage" => has_next_page,
            "endCursor" => end_cursor
          }
        }
      }
    }
  end

  defp issue_node(id, identifier, assignee \\ %{"id" => "user-1"}) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => "Issue #{identifier}",
      "description" => "Description for #{identifier}",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "feature/#{String.downcase(identifier)}",
      "url" => "https://example.org/issues/#{identifier}",
      "assignee" => assignee,
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{"nodes" => []},
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }
  end
end
