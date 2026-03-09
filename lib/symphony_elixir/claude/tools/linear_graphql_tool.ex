defmodule SymphonyElixir.Claude.Tools.LinearGraphqlTool do
  @moduledoc """
  Dynamic tool for executing Linear GraphQL queries using Symphony's credentials.
  """

  @behaviour SymphonyElixir.Claude.DynamicTool

  alias SymphonyElixir.Claude.DynamicTool
  alias SymphonyElixir.Linear.Client

  @linear_graphql_description """
  Execute a Linear GraphQL query using Symphony's configured Linear credentials.
  """

  @impl true
  def enabled?, do: true

  @impl true
  def tool_specs do
    [
      %{
        "name" => "linear_graphql",
        "description" => @linear_graphql_description,
        "inputSchema" => %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "GraphQL document to execute."
            },
            "variables" => %{
              "type" => "object",
              "description" => "Optional GraphQL variables map."
            }
          }
        }
      }
    ]
  end

  @impl true
  def execute("linear_graphql", arguments, opts) when is_list(opts) do
    with {:ok, query, variables} <- normalize_arguments(arguments),
         {:ok, response} <- run_graphql(query, variables, opts) do
      DynamicTool.success_response(response, not graphql_errors?(response))
    else
      {:error, {:tool_input, message}} ->
        DynamicTool.error_response(%{"error" => %{"message" => message}})

      {:error, :missing_linear_api_token} ->
        DynamicTool.error_response(%{
          "error" => %{
            "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
          }
        })

      {:error, {:linear_api_status, status}} ->
        DynamicTool.error_response(%{
          "error" => %{
            "message" => "Linear GraphQL request failed with HTTP #{status}.",
            "status" => status
          }
        })

      {:error, {:linear_api_request, reason}} ->
        DynamicTool.error_response(%{
          "error" => %{
            "message" => "Linear GraphQL request failed before receiving a successful response.",
            "reason" => inspect(reason)
          }
        })

      {:error, reason} ->
        DynamicTool.error_response(%{
          "error" => %{
            "message" => "Linear GraphQL tool execution failed.",
            "reason" => inspect(reason)
          }
        })
    end
  end

  def execute(_tool_name, _arguments, _opts) do
    DynamicTool.error_response(%{
      "error" => %{"message" => "LinearGraphqlTool does not handle this tool."}
    })
  end

  defp normalize_arguments(arguments) when is_binary(arguments) do
    query = String.trim(arguments)

    if query == "" do
      {:error, {:tool_input, "`linear_graphql` requires a non-empty `query` string."}}
    else
      {:ok, query, %{}}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    query = arguments["query"] || arguments[:query]
    variables = arguments["variables"] || arguments[:variables] || %{}

    cond do
      not is_binary(query) or String.trim(query) == "" ->
        {:error, {:tool_input, "`linear_graphql` requires a non-empty `query` string."}}

      not is_map(variables) ->
        {:error, {:tool_input, "`linear_graphql.variables` must be a JSON object when provided."}}

      true ->
        {:ok, String.trim(query), variables}
    end
  end

  defp normalize_arguments(_arguments) do
    {:error, {:tool_input, "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."}}
  end

  defp run_graphql(query, variables, opts) do
    client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    case client.(query, variables, []) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_client_response, other}}
    end
  end

  defp graphql_errors?(%{"errors" => errors}) when is_list(errors), do: errors != []
  defp graphql_errors?(%{errors: errors}) when is_list(errors), do: errors != []
  defp graphql_errors?(_payload), do: false
end
