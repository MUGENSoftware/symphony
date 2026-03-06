defmodule SymphonyElixir.Claude.DynamicTool do
  @moduledoc """
  Executes supported Claude dynamic tools.
  """

  alias SymphonyElixir.Linear.Client

  @type tool_response :: %{
          required(String.t()) => term()
        }

  @linear_graphql_description """
  Execute a Linear GraphQL query using Symphony's configured Linear credentials.
  """

  @spec tool_specs() :: [map()]
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

  @spec execute(String.t(), term()) :: tool_response()
  def execute(tool_name, arguments), do: execute(tool_name, arguments, [])

  @spec execute(String.t(), term(), keyword()) :: tool_response()
  def execute("linear_graphql", arguments, opts) when is_list(opts) do
    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- run_linear_graphql(query, variables, opts) do
      success_response(response, not graphql_errors?(response))
    else
      {:error, {:tool_input, message}} ->
        error_response(%{"error" => %{"message" => message}})

      {:error, :missing_linear_api_token} ->
        error_response(%{
          "error" => %{
            "message" =>
              "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
          }
        })

      {:error, {:linear_api_status, status}} ->
        error_response(%{
          "error" => %{
            "message" => "Linear GraphQL request failed with HTTP #{status}.",
            "status" => status
          }
        })

      {:error, {:linear_api_request, reason}} ->
        error_response(%{
          "error" => %{
            "message" => "Linear GraphQL request failed before receiving a successful response.",
            "reason" => inspect(reason)
          }
        })

      {:error, reason} ->
        error_response(%{
          "error" => %{
            "message" => "Linear GraphQL tool execution failed.",
            "reason" => inspect(reason)
          }
        })
    end
  end

  def execute(tool_name, _arguments, _opts) do
    error_response(%{
      "error" => %{
        "message" => ~s(Unsupported dynamic tool: "#{tool_name}".),
        "supportedTools" => Enum.map(tool_specs(), & &1["name"])
      }
    })
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    query = String.trim(arguments)

    if query == "" do
      {:error, {:tool_input, "`linear_graphql` requires a non-empty `query` string."}}
    else
      {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
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

  defp normalize_linear_graphql_arguments(_arguments) do
    {:error,
     {:tool_input,
      "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."}}
  end

  defp run_linear_graphql(query, variables, opts) do
    client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    case client.(query, variables, []) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_client_response, other}}
    end
  end

  defp success_response(payload, success?) do
    %{
      "success" => success?,
      "contentItems" => [%{"type" => "inputText", "text" => format_payload(payload)}]
    }
  end

  defp error_response(payload) do
    %{
      "success" => false,
      "contentItems" => [%{"type" => "inputText", "text" => format_payload(payload)}]
    }
  end

  defp graphql_errors?(%{"errors" => errors}) when is_list(errors), do: errors != []
  defp graphql_errors?(%{errors: errors}) when is_list(errors), do: errors != []
  defp graphql_errors?(_payload), do: false

  defp format_payload(payload) do
    if is_map(payload) or is_list(payload) do
      case Jason.encode(payload) do
        {:ok, json} -> json
        {:error, _reason} -> inspect(payload)
      end
    else
      inspect(payload)
    end
  end
end
