defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.Linear.PullLog

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    project_slug = Config.linear_project_slug()
    active_states = Config.linear_active_states()
    configured_assignee = Config.linear_assignee()

    log_fetch_start("candidate_issues",
      project_slug: project_slug,
      states: active_states,
      configured_assignee: configured_assignee,
      assignee_mode: assignee_mode(configured_assignee)
    )

    result =
      cond do
        is_nil(Config.linear_api_token()) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          with {:ok, assignee_filter} <- routing_assignee_filter(),
               {:ok, issues} <-
                 do_fetch_by_states(
                   "candidate_issues",
                   project_slug,
                   active_states,
                   assignee_filter
                 ) do
            {:ok, issues}
          end
      end

    log_fetch_result(
      "candidate_issues",
      result,
      project_slug: project_slug,
      states: active_states,
      configured_assignee: configured_assignee
    )

    result
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      log_fetch_start("issues_by_states", states: normalized_states)
      log_fetch_result("issues_by_states", {:ok, []}, states: normalized_states)
      {:ok, []}
    else
      project_slug = Config.linear_project_slug()
      log_fetch_start("issues_by_states", project_slug: project_slug, states: normalized_states)

      result =
        cond do
          is_nil(Config.linear_api_token()) ->
            {:error, :missing_linear_api_token}

          is_nil(project_slug) ->
            {:error, :missing_linear_project_slug}

          true ->
            do_fetch_by_states("issues_by_states", project_slug, normalized_states, nil)
        end

      log_fetch_result(
        "issues_by_states",
        result,
        project_slug: project_slug,
        states: normalized_states
      )

      result
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)
    log_fetch_start("issue_states_by_ids", issue_ids: ids)

    result =
      case ids do
        [] ->
          {:ok, []}

        ids ->
          with {:ok, assignee_filter} <- routing_assignee_filter(),
               {:ok, issues} <- do_fetch_issue_states(ids, assignee_filter) do
            {:ok, issues}
          end
      end

    log_fetch_result("issue_states_by_ids", result, issue_ids: ids)
    result
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, graphql_request_fun())

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  defp do_fetch_by_states(operation, project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(operation, project_slug, state_names, assignee_filter, nil, [], 1)
  end

  defp do_fetch_by_states_page(
         operation,
         project_slug,
         state_names,
         assignee_filter,
         after_cursor,
         acc_issues,
         page_number
       ) do
    PullLog.log(:page_fetch_start,
      operation: operation,
      page: page_number,
      project_slug: project_slug,
      states: state_names,
      after_cursor: after_cursor,
      assignee_mode: assignee_mode(assignee_filter)
    )

    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)
      PullLog.log(:page_fetch_result,
        operation: operation,
        page: page_number,
        project_slug: project_slug,
        states: state_names,
        issue_count: length(issues),
        issue_identifiers: Enum.map(issues, & &1.identifier),
        has_next_page: page_info.has_next_page,
        next_cursor: page_info.end_cursor
      )

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(
            operation,
            project_slug,
            state_names,
            assignee_filter,
            next_cursor,
            updated_acc,
            page_number + 1
          )

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          log_fetch_failure(operation, reason,
            project_slug: project_slug,
            states: state_names,
            page: page_number
          )

          {:error, reason}
      end
    else
      {:error, reason} ->
        log_fetch_failure(operation, reason,
          project_slug: project_slug,
          states: state_names,
          page: page_number,
          after_cursor: after_cursor
        )

        {:error, reason}
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    case graphql(@query_by_ids, %{
           ids: ids,
           first: Enum.min([length(ids), @issue_page_size]),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        decode_linear_response(body, assignee_filter)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.linear_api_token() do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp graphql_request_fun do
    Application.get_env(:symphony_elixir, :linear_graphql_request_fun, &post_graphql_request/2)
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.linear_endpoint(),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.linear_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    PullLog.log(:viewer_lookup_start, configured_assignee: "me")

    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            log_fetch_failure("viewer_lookup", :missing_linear_viewer_identity,
              configured_assignee: "me"
            )

            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            PullLog.log(:viewer_lookup_success,
              configured_assignee: "me",
              viewer_id: viewer_id
            )

            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        log_fetch_failure("viewer_lookup", :missing_linear_viewer_identity,
          configured_assignee: "me"
        )

        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        log_fetch_failure("viewer_lookup", reason, configured_assignee: "me")
        {:error, reason}
    end
  end

  defp log_fetch_start(operation, fields) when is_binary(operation) do
    PullLog.log(:fetch_start, Map.put(Map.new(fields), :operation, operation))
  end

  defp log_fetch_result(operation, {:ok, issues}, fields)
       when is_binary(operation) and is_list(issues) do
    PullLog.log(
      :fetch_success,
      fields
      |> Map.new()
      |> Map.merge(%{
        operation: operation,
        issue_count: length(issues),
        issue_ids: Enum.map(issues, & &1.id),
        issue_identifiers: Enum.map(issues, & &1.identifier)
      })
    )
  end

  defp log_fetch_result(operation, {:error, reason}, fields) when is_binary(operation) do
    log_fetch_failure(operation, reason, fields)
  end

  defp log_fetch_failure(operation, reason, fields) when is_binary(operation) do
    PullLog.log(
      :fetch_failure,
      fields
      |> Map.new()
      |> Map.put(:operation, operation)
      |> Map.merge(failure_fields(reason))
    )
  end

  defp failure_fields({:linear_api_status, status}) do
    %{reason: :linear_api_status, status: status}
  end

  defp failure_fields({:linear_api_request, reason}) do
    %{reason: :linear_api_request, error: inspect(reason)}
  end

  defp failure_fields({:linear_graphql_errors, errors}) do
    %{reason: :linear_graphql_errors, graphql_errors: summarize_graphql_errors(errors)}
  end

  defp failure_fields(reason) do
    %{reason: inspect(reason)}
  end

  defp summarize_graphql_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{"message" => message} -> message
      error -> inspect(error)
    end)
  end

  defp summarize_graphql_errors(errors), do: inspect(errors)

  defp assignee_mode(nil), do: "unfiltered"
  defp assignee_mode("me"), do: "viewer"
  defp assignee_mode(value) when is_binary(value), do: "configured"

  defp assignee_mode(%{configured_assignee: "me"}), do: "viewer"
  defp assignee_mode(%{configured_assignee: _value}), do: "configured"
  defp assignee_mode(_value), do: "unfiltered"

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
